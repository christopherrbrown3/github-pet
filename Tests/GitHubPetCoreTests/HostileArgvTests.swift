import Foundation
import Testing
@testable import GitHubPetCore

/// #7: owner, repository and query values reach gh as single literal argv elements. gh is run
/// without a shell, every value follows `-f` as one `key=value` element (a raw string, so `@file`
/// and `{json}` are never interpreted), and no value can become a flag.
@Suite(.timeLimit(.minutes(1))) struct HostileArgvTests {
    static let hostile = [
        "has space", "it's", "say \"hi\"", "-x", "--hostname=evil.example", "-f", "--input=/etc/passwd",
        "line1\nline2", "tab\there", "$(touch /tmp/pwned)", "`id`", "a;b", "a|b", "a&&b", "a>b", "*", "~",
        "@/etc/passwd", "{\"x\":1}", "--", "", " -leading", "ünï", "a\u{0}b",
    ]
    static let flags: Set<String> = ["--hostname", "-X", "-f"]

    /// The shape every plan must have: `api`, known flags only, each `-f` followed by `key=value`.
    static func assertWellFormed(_ arguments: [String], hostileValues: [String] = [], sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(arguments.first == "api", sourceLocation: sourceLocation)
        var index = 1
        while index < arguments.count {
            let element = arguments[index]
            if element.hasPrefix("-") {
                #expect(flags.contains(element), "unexpected flag \(element)", sourceLocation: sourceLocation)
                if element == "-f" {
                    index += 1
                    let pair = index < arguments.count ? arguments[index] : ""
                    let key = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
                    #expect(!key.isEmpty && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") },
                            "-f must be followed by key=value, got \(pair)", sourceLocation: sourceLocation)
                } else if element == "--hostname" || element == "-X" {
                    index += 1
                }
            }
            index += 1
        }
        for value in hostileValues where !value.isEmpty && !flags.contains(value) {
            // A hostile value may only appear inside a `key=value` element, never as its own element.
            #expect(!arguments.contains(value), "\(value.debugDescription) became its own argv element", sourceLocation: sourceLocation)
        }
    }

    @Test func hostileOwnersAndRepositoriesAreRejectedBeforeAnyPlanExists() {
        // "-x", "-f" and "--" are legal repository names (see the next test): they only travel as values.
        let legalName: (String) -> Bool = { $0.utf8.allSatisfy { $0 == 45 || $0 == 46 || $0 == 95 || ($0 | 32 >= 97 && $0 | 32 <= 122) || ($0 >= 48 && $0 <= 57) } }
        for value in Self.hostile {
            #expect(throws: (any Error).self) { try MonitoringTarget(organization: value) }
            if !legalName(value) { #expect(throws: (any Error).self) { try MonitoringTarget(repository: "octo/" + value) } }
            #expect(throws: (any Error).self) { try MonitoringTarget(repository: value + "/repo") }
            #expect(throws: (any Error).self) { try MonitoringTarget(repository: value) }
        }
        for value in ["octo/a b", "octo/a\nb", "octo/a;b", "octo/../x", "octo/a/b", "../x/y", "-x/y z"] {
            #expect(throws: (any Error).self) { try MonitoringTarget(repository: value) }
        }
    }

    /// Valid but option-like: a repository name may start with `-` or `.`.
    @Test func optionLikeButValidNamesStayInsideOneKeyValueElement() throws {
        let target = try MonitoringTarget(repository: "octo/--version")
        let scope = try MonitoringScope(selected: [target, try MonitoringTarget(organization: "acme-1")])
        let account = try ScopeAccount(viewerID: "MDQ6VXNlcjE=")
        let plans: [[String]] = [
            try ScopeQueryPlan(scope: scope, expectedAccount: account).arguments,
            ScopeAccessPlan(scope: scope, expectedAccount: account).arguments,
            ActionsQueryPlan(repositories: [target], expectedAccount: account).arguments,
        ]
        for arguments in plans {
            Self.assertWellFormed(arguments)
            #expect(!arguments.contains("--version"))
            #expect(arguments.contains("name0=--version") || arguments.contains("name1=--version"))
            // Values travel as variables, never in the query text.
            let query = try #require(arguments.first { $0.hasPrefix("query=") })
            #expect(!query.contains("--version") && !query.contains("octo"))
        }
        let rest = WaitingRunsPlan(repository: target).arguments
        Self.assertWellFormed(rest)
        #expect(rest[5] == "repos/octo/--version/actions/runs")
        #expect(!rest.contains("--version"))
    }

    @Test func searchQualifiersAreVariablesNotQueryText() throws {
        let scope = try MonitoringScope(selected: [try MonitoringTarget(repository: "octo/.hidden"),
                                                   try MonitoringTarget(organization: "acme")])
        let arguments = try ScopeQueryPlan(scope: scope, expectedAccount: ScopeAccount(viewerID: "u1")).arguments
        Self.assertWellFormed(arguments)
        #expect(arguments.contains { $0.hasSuffix("=is:pr is:open review-requested:@me repo:octo/.hidden") })
        let query = try #require(arguments.first { $0.hasPrefix("query=") })
        #expect(!query.contains("repo:octo") && !query.contains("org:acme"))
    }

    /// Cursors and node IDs come from GitHub's answers, not from the user, but must be literal too.
    @Test func hostileCursorsAndNodeIDsStayLiteralValues() {
        for value in Self.hostile where !value.isEmpty {
            let page = ScopeDiscoveryPagePlan(organizationCursor: .some(value), repositoryCursor: .some(value)).arguments
            Self.assertWellFormed(page, hostileValues: [value])
            #expect(page.contains("organizationCursor=\(value)") && page.contains("repositoryCursor=\(value)"))
            let run = WaitingRun(nodeID: value, repositoryIndex: 0, repository: "octo/repo", workflow: "CI",
                                 url: URL(string: "https://github.com/octo/repo/actions/runs/1")!, updatedAt: Date())
            let pending = PendingRequestsPlan(runs: [run], expectedAccount: nil).arguments
            Self.assertWellFormed(pending, hostileValues: [value])
            #expect(pending.contains("run0=\(value)"))
            let query = pending.first { $0.hasPrefix("query=") } ?? ""
            #expect(!query.contains(value) || value.count < 2, "node IDs are variables, not query text")
        }
    }

    /// A real child process: gh stand-in that writes each argv element NUL-terminated.
    @Test func realProcessReceivesEveryElementUnchanged() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hostile-argv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("argv.bin"), script = directory.appendingPathComponent("gh")
        try "#!/bin/sh\nfor a in \"$@\"; do printf '%s\\0' \"$a\"; done > '\(output.path)'\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let runner = ProcessCommandRunner()
        let values = Self.hostile.filter { !$0.contains("\u{0}") && !$0.isEmpty }
        for value in values {
            let arguments = ScopeDiscoveryPagePlan(organizationCursor: .some(value), repositoryCursor: nil).arguments
            let result = try runner.run(executable: script, arguments: arguments, budget: CommandBudget(timeout: 10))
            #expect(result.exitCode == 0)
            let received = try Data(contentsOf: output).split(separator: 0, omittingEmptySubsequences: false).dropLast()
                .map { String(decoding: $0, as: UTF8.self) }
            #expect(received == arguments, "argv changed in transit for \(value.debugDescription)")
        }
        #expect(!FileManager.default.fileExists(atPath: "/tmp/pwned"))
    }
}
