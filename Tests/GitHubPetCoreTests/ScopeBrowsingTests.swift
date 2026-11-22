import Foundation
import Testing
@testable import GitHubPetCore

/// #137 scope browser: plans keep every value in one `-f key=value` element, typed search
/// qualifiers never reach GitHub, and every failure parses to something other than "empty".
@Suite struct ScopeBrowsingTests {
    let account = try! ScopeAccount(viewerID: "U_demo")
    let organization = ScopeBrowseOwner(kind: .organization, login: "demo-org", repositoryCount: 240)
    let viewerOwner = ScopeBrowseOwner(kind: .viewer, login: "demo-user", repositoryCount: 12)
    let shared = ScopeBrowseOwner(kind: .shared, login: "", repositoryCount: 3)

    private func reply(_ envelope: [String: Any], exitCode: Int32 = 0, stderr: String = "") -> CommandResult {
        CommandResult(exitCode: exitCode, stdout: try! JSONSerialization.data(withJSONObject: envelope), stderr: Data(stderr.utf8))
    }
    private var viewer: [String: Any] { ["id": "U_demo", "login": "demo-user"] }
    private func node(_ name: String, archived: Bool = false) -> [String: Any] {
        ["nameWithOwner": name, "isPrivate": true, "isArchived": archived, "isFork": false, "pushedAt": "2026-11-01T10:00:00Z"]
    }
    private func page(_ nodes: [[String: Any]], more: Bool, total: Int, cursor: String = "c100") -> [String: Any] {
        ["totalCount": total, "nodes": nodes, "pageInfo": ["hasNextPage": more, "endCursor": cursor]]
    }

    // MARK: Plans and argv

    @Test func everyPlanIsWellFormedArgv() throws {
        HostileArgvTests.assertWellFormed(ScopeOwnersPlan(expectedAccount: account).arguments)
        for owner in [organization, viewerOwner, shared] {
            for sort in ScopeBrowseSort.allCases {
                HostileArgvTests.assertWellFormed(ScopeRepositoryPagePlan(owner: owner, cursor: nil, sort: sort, expectedAccount: account).arguments)
            }
        }
        let search = try #require(ScopeRepositorySearchPlan(owner: organization, typed: "lantern", expectedAccount: account))
        HostileArgvTests.assertWellFormed(search.arguments)
    }

    @Test func ownerAndCursorAreVariablesNeverQueryText() throws {
        for value in HostileArgvTests.hostile where !value.isEmpty {
            let plan = ScopeRepositoryPagePlan(owner: organization, cursor: value, sort: .pushed, expectedAccount: account)
            HostileArgvTests.assertWellFormed(plan.arguments, hostileValues: [value])
            #expect(plan.arguments.contains("cursor=\(value)") && plan.arguments.contains("owner=demo-org"))
            let query = try #require(plan.arguments.first { $0.hasPrefix("query=") })
            #expect(!query.contains("demo-org"))
        }
        let page = ScopeRepositoryPagePlan(owner: organization, cursor: nil, sort: .pushed, expectedAccount: account).arguments
        #expect(page.contains { $0.contains("first: 100") } && !page.contains { $0.contains("first: 101") })
    }

    @Test func searchIsOneVariableBuiltClientSideWithQualifiersStripped() throws {
        let fixedQuery = try #require(ScopeRepositorySearchPlan(owner: organization, typed: "lantern", expectedAccount: account))
            .arguments.first { $0.hasPrefix("query=") }
        #expect(fixedQuery?.contains("demo-org") == false && fixedQuery?.contains("lantern") == false)
        for typed in HostileArgvTests.hostile + ["user:evil lantern", "repo:x/y is:private lantern", "org:other lantern", "\"lantern\" OR NOT -api"] {
            guard let plan = ScopeRepositorySearchPlan(owner: organization, typed: typed, expectedAccount: account) else { continue }
            HostileArgvTests.assertWellFormed(plan.arguments, hostileValues: [typed])
            let searches = plan.arguments.filter { $0.hasPrefix("searchQuery=") }
            #expect(searches == ["searchQuery=\(plan.searchQuery)"], "exactly one -f searchQuery element")
            #expect(plan.searchQuery.hasPrefix("org:demo-org ") && plan.searchQuery.hasSuffix(" in:name fork:true"))
            // The only qualifiers are the three the app adds.
            #expect(plan.searchQuery.split(separator: " ").filter { $0.contains(":") } == ["org:demo-org", "in:name", "fork:true"])
            // The query text is fixed; only the variable changes with input.
            #expect(plan.arguments.first { $0.hasPrefix("query=") } == fixedQuery)
        }
        let typed = try #require(ScopeRepositorySearchPlan(owner: organization, typed: "user:evil repo:x/y org:z is:pr lantern", expectedAccount: account))
        #expect(typed.term == "lantern")
        let mine = try #require(ScopeRepositorySearchPlan(owner: viewerOwner, typed: "api", expectedAccount: account))
        #expect(mine.searchQuery == "user:demo-user api in:name fork:true")
        #expect(ScopeRepositorySearchPlan(owner: shared, typed: "api", expectedAccount: account) == nil, "shared has no owner qualifier")
        #expect(ScopeRepositorySearchPlan(owner: organization, typed: "is:pr org:x", expectedAccount: account) == nil)
    }

    @Test func sanitizeKeepsNameFragmentsOnly() {
        #expect(ScopeSearchTerm.sanitize("lantern") == "lantern")
        #expect(ScopeSearchTerm.sanitize("  Lantern-API  docs.v2 ") == "Lantern-API docs.v2")
        #expect(ScopeSearchTerm.sanitize("-api") == "api", "leading '-' would negate")
        #expect(ScopeSearchTerm.sanitize("AND OR NOT") == nil)
        #expect(ScopeSearchTerm.sanitize("is:pr user:x") == nil)
        #expect(ScopeSearchTerm.sanitize("\"quoted\" (x) $(id)") == "quoted x id")
        #expect(ScopeSearchTerm.sanitize(String(repeating: "a", count: 200))?.count == ScopeSearchTerm.maximumLength)
    }

    // MARK: Parsing

    @Test func ownersListMarksSSODeniedOrganizationsInsteadOfDroppingThem() {
        let plan = ScopeOwnersPlan(expectedAccount: account)
        let organizations: [String: Any] = ["totalCount": 2, "pageInfo": ["hasNextPage": false], "nodes": [
            ["login": "demo-open", "repositories": ["totalCount": 38]],
            ["login": "demo-sso", "repositories": NSNull()],
        ]]
        let result = ScopeBrowseParser.owners(reply([
            "data": ["viewer": viewer.merging(["own": ["totalCount": 12], "shared": ["totalCount": 0], "organizations": organizations]) { $1 },
                     "rateLimit": ["remaining": 10, "resetAt": "2026-11-22T12:00:00Z"]],
            "errors": [["type": "FORBIDDEN", "path": ["viewer", "organizations", "nodes", 1, "repositories"], "message": "SAML enforcement"]],
        ]), plan: plan)
        #expect(result.failure == nil)
        #expect(result.owners.map(\.kind) == [.viewer, .shared, .organization, .organization])
        #expect(result.owners[2] == ScopeBrowseOwner(kind: .organization, login: "demo-open", repositoryCount: 38))
        #expect(result.owners[3].denied && result.owners[3].repositoryCount == nil)
        #expect(result.rateLimitReset != nil)
    }

    @Test func ownersFailuresAreClassified() {
        let plan = ScopeOwnersPlan(expectedAccount: account)
        #expect(ScopeBrowseParser.owners(CommandResult(exitCode: 4, stderr: Data("gh auth login".utf8)), plan: plan).failure == .signedOut)
        #expect(ScopeBrowseParser.owners(reply(["data": ["viewer": ["id": "U_other", "login": "x"]]]), plan: plan).failure == .identityMismatch)
        #expect(ScopeBrowseParser.owners(reply(["errors": [["type": "RATE_LIMITED", "message": "x"]]], exitCode: 1), plan: plan).failure == .rateLimited(resetAt: nil))
        #expect(ScopeBrowseParser.owners(CommandResult(exitCode: 1, stderr: Data("API rate limit exceeded".utf8)), plan: plan).failure == .rateLimited(resetAt: nil))
        #expect(ScopeBrowseParser.owners(CommandResult(exitCode: 1, stderr: Data("HTTP 403: Resource protected by organization SAML enforcement".utf8)), plan: plan).failure == .accessDenied)
        #expect(ScopeBrowseParser.owners(CommandResult(exitCode: 0, stdout: Data("not json".utf8)), plan: plan).failure == .malformedResponse)
        #expect(ScopeBrowseParser.owners(CommandResult(exitCode: 0, stdout: Data(), outputComplete: false), plan: plan).failure == .outputLimit)
    }

    @Test func pagesDistinguishCompleteMoreAndEmpty() {
        let plan = ScopeRepositoryPagePlan(owner: organization, cursor: nil, sort: .pushed, expectedAccount: account)
        func parse(_ connection: [String: Any], errors: [[String: Any]]? = nil) -> ScopeRepositoryPage {
            var envelope: [String: Any] = ["data": ["viewer": viewer, "organization": ["page": connection]]]
            if let errors { envelope["errors"] = errors }
            return ScopeBrowseParser.repositories(reply(envelope), plan: plan)
        }
        let complete = parse(page([node("demo-org/a"), node("demo-org/b", archived: true)], more: false, total: 2))
        #expect(complete.completion == .exhausted && complete.repositories.count == 2 && complete.failure == nil)
        #expect(complete.repositories[1].isArchived && complete.repositories[0].pushedAt != nil)
        let more = parse(page([node("demo-org/a")], more: true, total: 240))
        #expect(more.completion == .capped && more.nextCursor == "c100" && more.totalCount == 240)
        let empty = parse(page([], more: false, total: 0))
        #expect(empty.completion == .exhausted && empty.repositories.isEmpty, "only this is a truly empty answer")
        let partial = parse(page([node("demo-org/a")], more: true, total: 240), errors: [["message": "Something went wrong"]])
        #expect(partial.completion == .partial && partial.failure == .graphQLError)
        var bad = node("demo-org/b"); bad["isPrivate"] = 1
        #expect(parse(page([node("demo-org/a"), bad], more: false, total: 2)).completion == .partial, "JSON 1 is not a boolean")
        #expect(parse(page([node("other/x")], more: false, total: 1)).completion == .partial, "rows of another owner are refused")
        let badCursor = parse(page([node("demo-org/a")], more: true, total: 240, cursor: "bad cursor!"))
        #expect(badCursor.completion == .partial && badCursor.nextCursor == nil)
    }

    @Test func pageFailuresNeverLookEmpty() {
        let plan = ScopeRepositoryPagePlan(owner: organization, cursor: nil, sort: .pushed, expectedAccount: account)
        let denied = ScopeBrowseParser.repositories(reply([
            "data": ["viewer": viewer, "organization": NSNull()],
            "errors": [["type": "FORBIDDEN", "path": ["organization"], "message": "Resource protected by organization SAML enforcement."]],
        ], exitCode: 1, stderr: "HTTP 403"), plan: plan)
        #expect(denied.failure == .accessDenied && denied.completion != .exhausted)
        let mismatch = ScopeBrowseParser.repositories(reply(["data": ["viewer": ["id": "U_other", "login": "x"]]]), plan: plan)
        #expect(mismatch.failure == .identityMismatch && mismatch.repositories.isEmpty)
        for result in [CommandResult(exitCode: 4), CommandResult(exitCode: 1, stderr: Data("rate limit".utf8)),
                       CommandResult(exitCode: 1, stderr: Data("dial tcp: timeout".utf8))] {
            let parsed = ScopeBrowseParser.repositories(result, plan: plan)
            #expect(parsed.failure != nil && parsed.completion != .exhausted)
        }
    }

    @Test func managedUserRowsParseButCannotBecomeTargets() {
        let plan = ScopeRepositoryPagePlan(owner: viewerOwner, cursor: nil, sort: .pushed, expectedAccount: account)
        let parsed = ScopeBrowseParser.repositories(reply(["data": ["viewer": viewer.merging(["page": page([node("demo_corp/tools")], more: false, total: 1)]) { $1 }]]), plan: plan)
        #expect(parsed.completion == .exhausted && parsed.repositories.first?.target == nil)
    }

    @Test func searchResultsAreNeverACompleteListing() throws {
        let plan = try #require(ScopeRepositorySearchPlan(owner: organization, typed: "lantern", expectedAccount: account))
        let found = ScopeBrowseParser.search(reply(["data": ["viewer": viewer, "search": ["repositoryCount": 75, "nodes": [node("demo-org/lantern-api")]]]]), plan: plan)
        #expect(found.repositories.count == 1 && found.totalCount == 75 && found.completion == .capped)
        let none = ScopeBrowseParser.search(reply(["data": ["viewer": viewer, "search": ["repositoryCount": 0, "nodes": []]]]), plan: plan)
        #expect(none.repositories.isEmpty && none.failure == nil)
    }

    @Test func ghTransportReportsMissingCLI() {
        let access = ScopeGhAccess(locator: GhLocator(environment: [:], isExecutable: { _ in false }))
        #expect(access.owners(ScopeOwnersPlan(expectedAccount: account), budget: CommandBudget(timeout: 5)).failure == .ghMissing)
    }
}
