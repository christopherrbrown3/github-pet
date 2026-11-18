import Foundation
import GitHubPetCore

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private struct DiskRecord: Decodable {
    let entries: [DismissedInboxItem]
}

private let namespace = "GitHubPet.inbox-dismissals.v1."

private func verifyPhysicalRecords(at plist: URL, accountKey: String, accountEntry: DismissedInboxItem,
                                   demoKey: String, demoEntry: DismissedInboxItem) throws {
    let bytes: Data
    do { bytes = try Data(contentsOf: plist) }
    catch { throw CheckFailure("physical plist is unreadable (error code \((error as NSError).code))") }
    guard let object = try? PropertyListSerialization.propertyList(from: bytes, format: nil) else {
        throw CheckFailure("physical plist is malformed (\(bytes.count) bytes)")
    }
    guard let dictionary = object as? [String: Any] else {
        throw CheckFailure("physical plist root is \(type(of: object)); expected a dictionary")
    }
    let versioned = dictionary.filter { $0.key.hasPrefix(namespace) }
    let dataCount = versioned.values.filter { $0 is Data }.count
    let shape = "\(dictionary.count) total keys, \(versioned.count) versioned keys, \(dataCount) versioned data values"
    guard versioned.count == 2 else { throw CheckFailure("physical plist has \(shape); expected two versioned keys") }
    for (label, key, expected) in [("account", accountKey, accountEntry), ("Demo", demoKey, demoEntry)] {
        guard let value = versioned[key] else { throw CheckFailure("missing \(label) key (\(shape))") }
        guard let data = value as? Data else { throw CheckFailure("\(label) value is \(type(of: value)) (\(shape))") }
        guard let record = try? JSONDecoder().decode(DiskRecord.self, from: data) else {
            throw CheckFailure("\(label) record could not be decoded (\(data.count) bytes, \(shape))")
        }
        guard record.entries == [expected] else {
            throw CheckFailure("\(label) record has \(record.entries.count) entries and differs from the expected fixture (\(shape))")
        }
    }
}

private func waitForDisk(at plist: URL, accountKey: String, accountEntry: DismissedInboxItem,
                         demoKey: String, demoEntry: DismissedInboxItem) throws {
    for attempt in 0..<21 {
        do {
            try verifyPhysicalRecords(at: plist, accountKey: accountKey, accountEntry: accountEntry,
                                      demoKey: demoKey, demoEntry: demoEntry)
            return
        } catch {
            if attempt == 20 { throw error }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
}

func run() throws {
    let environment = ProcessInfo.processInfo.environment
    let arguments = CommandLine.arguments
    let prefix = "dev.github-pet.dismissal-durability-ci."
    guard environment["GITHUB_ACTIONS"] == "true", environment["RUNNER_OS"] == "macOS",
          environment["RUNNER_ENVIRONMENT"] == "github-hosted", arguments.count == 3,
          ["write", "verify"].contains(arguments[1]), arguments[2].hasPrefix(prefix),
          UUID(uuidString: String(arguments[2].dropFirst(prefix.count))) != nil else {
        throw CheckFailure("expected write or verify and a fresh test suite on a disposable GitHub-hosted macOS runner")
    }
    let suite = arguments[2]
    guard let defaults = UserDefaults(suiteName: suite) else { throw CheckFailure("could not open test suite") }
    let store = InboxDismissalStore(defaults: defaults)
    let viewer = try ScopeAccount(viewerID: "U_durability_A")
    let account = ScopeIdentity.github(viewer)
    let otherAccount = try ScopeIdentity.github(ScopeAccount(viewerID: "U_durability_B"))
    let date = Date(timeIntervalSince1970: 1_763_208_000)
    let item = InboxItem(id: "reviewRequest:PR_durability", kind: .reviewRequest, repository: "demo/pet",
                         title: "Synthetic private title", url: URL(string: "https://github.com/demo/pet/pull/19"),
                         updatedAt: date)
    guard let entry = DismissedInboxItem(item: item, dismissedAt: date),
          let demoEntry = DismissedInboxItem(item: item, dismissedAt: date + 60) else {
        throw CheckFailure("could not construct dismissal fixtures")
    }
    if arguments[1] == "write" {
        guard defaults.persistentDomain(forName: suite)?.isEmpty != false else {
            throw CheckFailure("test suite must start empty")
        }
        try store.save([entry], for: account)
        try store.save([demoEntry], for: .demo)
        // Flush the test suite before this process exits so a second process can verify disk.
        guard defaults.synchronize() else { throw CheckFailure("test suite did not synchronize") }
        print("Writer process \(ProcessInfo.processInfo.processIdentifier) saved account and Demo dismissals.")
    } else {
        defer { defaults.removePersistentDomain(forName: suite) }
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences", isDirectory: true)
            .appendingPathComponent(suite + ".plist")
        // Pin the expected v1 physical keys independently of the live store reads below.
        let accountKey = namespace + EventBaseline.digest("\(viewer.host).\(viewer.viewerID)")
        let demoKey = namespace + EventBaseline.digest("demo")
        try waitForDisk(at: plist, accountKey: accountKey, accountEntry: entry, demoKey: demoKey, demoEntry: demoEntry)
        print("Reader process \(ProcessInfo.processInfo.processIdentifier) verified both keyed fixture records in the physical plist.")
        let savedAccount = try store.load(for: account)
        let savedDemo = try store.load(for: .demo)
        let savedOtherAccount = try store.load(for: otherAccount)
        guard savedAccount == [entry], savedDemo == [demoEntry], savedOtherAccount.isEmpty else {
            throw CheckFailure("a fresh reader did not recover both isolated dismissals")
        }
        print("Reader loaded both isolated dismissals through InboxDismissalStore and found the third account empty.")
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("dismissal durability: \(error)\n".utf8))
    exit(1)
}
