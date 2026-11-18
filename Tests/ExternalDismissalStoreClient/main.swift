import Foundation
import GitHubPetCore

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
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
    let account = try ScopeIdentity.github(ScopeAccount(viewerID: "U_durability_A"))
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
        let disk = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil)
        let diskRecords = (disk as? [String: Data])?.filter { $0.key.hasPrefix("GitHubPet.inbox-dismissals.v1.") }
        guard diskRecords?.count == 2, diskRecords == defaults.persistentDomain(forName: suite) as? [String: Data] else {
            throw CheckFailure("expected a matching pair of versioned dismissal records in the disk suite")
        }
        let savedAccount = try store.load(for: account)
        let savedDemo = try store.load(for: .demo)
        let savedOtherAccount = try store.load(for: otherAccount)
        guard savedAccount == [entry], savedDemo == [demoEntry], savedOtherAccount.isEmpty else {
            throw CheckFailure("a fresh reader did not recover both isolated dismissals")
        }
        print("Reader process \(ProcessInfo.processInfo.processIdentifier) verified the on-disk records and loaded both isolated dismissals.")
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("dismissal durability: \(error)\n".utf8))
    exit(1)
}
