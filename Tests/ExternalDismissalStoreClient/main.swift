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

private struct IdentityCheck {
    let label: String
    let identity: ScopeIdentity
    let key: String
    let entries: [DismissedInboxItem]

    init(label: String, identity: ScopeIdentity, suffix: String, entries: [DismissedInboxItem]) {
        self.label = label
        self.identity = identity
        key = namespace + EventBaseline.digest(suffix)
        self.entries = entries
    }
}

private func verifyPhysicalRecords(at plist: URL, expected: [IdentityCheck]) throws -> String {
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
    let results: [(shape: String, matches: Bool)] = expected.map { check in
        guard let value = versioned[check.key] else {
            return ("\(check.label)=missing", check.entries.isEmpty)
        }
        guard let data = value as? Data else {
            return ("\(check.label)=\(type(of: value))", false)
        }
        guard let record = try? JSONDecoder().decode(DiskRecord.self, from: data) else {
            return ("\(check.label)=malformed Data (\(data.count) bytes)", false)
        }
        let matches = !check.entries.isEmpty && record.entries == check.entries
        return ("\(check.label)=Data (\(record.entries.count) entries, \(matches ? "exact" : "mismatch"))", matches)
    }
    let shape = "\(versioned.count) versioned keys, \(dataCount) Data values; " + results.map(\.shape).joined(separator: ", ")
    guard versioned.count == expected.filter({ !$0.entries.isEmpty }).count, results.allSatisfy(\.matches) else {
        throw CheckFailure(shape)
    }
    return shape
}

private func checkDisk(at plist: URL, expected: [IdentityCheck]) -> Bool {
    for attempt in 0...20 {
        do {
            let shape = try verifyPhysicalRecords(at: plist, expected: expected)
            print("Reader physical plist PASS: \(shape)")
            return true
        } catch {
            if attempt == 20 { print("Reader physical plist FAIL: \(error)"); return false }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
    return false
}

private func checkStore(_ store: InboxDismissalStore, stage: String, expected: [IdentityCheck]) -> Bool {
    var allMatch = true
    for check in expected {
        do {
            let entries = try store.load(for: check.identity)
            let matches = entries == check.entries
            print("\(stage) \(check.label) \(matches ? "PASS" : "FAIL"): \(entries.count) entries (expected \(check.entries.count))")
            allMatch = allMatch && matches
        } catch {
            print("\(stage) \(check.label) FAIL: store load error (\(type(of: error)))")
            allMatch = false
        }
    }
    return allMatch
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
    let otherViewer = try ScopeAccount(viewerID: "U_durability_B")
    let otherAccount = ScopeIdentity.github(otherViewer)
    let date = Date(timeIntervalSince1970: 1_763_208_000)
    let item = InboxItem(id: "reviewRequest:PR_durability", kind: .reviewRequest, repository: "demo/pet",
                         title: "Synthetic private title", url: URL(string: "https://github.com/demo/pet/pull/19"),
                         updatedAt: date)
    guard let entry = DismissedInboxItem(item: item, dismissedAt: date),
          let demoEntry = DismissedInboxItem(item: item, dismissedAt: date + 60) else {
        throw CheckFailure("could not construct dismissal fixtures")
    }
    // Pin the expected v1 physical keys independently of the live store reads.
    let accountCheck = IdentityCheck(label: "account A", identity: account,
                                     suffix: "\(viewer.host).\(viewer.viewerID)", entries: [entry])
    let demoCheck = IdentityCheck(label: "Demo", identity: .demo, suffix: "demo", entries: [demoEntry])
    let otherCheck = IdentityCheck(label: "account B", identity: otherAccount,
                                   suffix: "\(otherViewer.host).\(otherViewer.viewerID)", entries: [])
    let expected = [accountCheck, demoCheck, otherCheck]
    let pid = ProcessInfo.processInfo.processIdentifier
    if arguments[1] == "write" {
        guard defaults.persistentDomain(forName: suite)?.isEmpty != false else {
            throw CheckFailure("test suite must start empty")
        }
        print("Writer process \(pid)")
        try store.save([entry], for: account)
        let noDemo = IdentityCheck(label: "Demo", identity: .demo, suffix: "demo", entries: [])
        let afterAccount = checkStore(store, stage: "Writer after account save", expected: [accountCheck, noDemo, otherCheck])
        try store.save([demoEntry], for: .demo)
        let afterDemo = checkStore(store, stage: "Writer after Demo save", expected: expected)
        // Flush the test suite before this process exits so a second process can verify disk.
        let synchronized = defaults.synchronize()
        print("Writer synchronize \(synchronized ? "PASS" : "FAIL")")
        let afterFlush = checkStore(store, stage: "Writer after synchronize", expected: expected)
        guard afterAccount, afterDemo, synchronized, afterFlush else {
            throw CheckFailure("one or more writer checks failed")
        }
    } else {
        defer { defaults.removePersistentDomain(forName: suite) }
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences", isDirectory: true)
            .appendingPathComponent(suite + ".plist")
        print("Reader process \(pid)")
        let physicalMatches = checkDisk(at: plist, expected: expected)
        let storeMatches = checkStore(store, stage: "Reader fresh store", expected: expected)
        guard physicalMatches, storeMatches else {
            throw CheckFailure("one or more reader checks failed")
        }
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("dismissal durability: \(error)\n".utf8))
    exit(1)
}
