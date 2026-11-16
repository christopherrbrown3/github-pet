import Foundation
import Testing
@testable import GitHubPetCore

private let accountA = try! ScopeAccount(viewerID: "U_edit_A")
private let accountB = try! ScopeAccount(viewerID: "U_edit_B")
private let locator = GhLocator(environment: [GhLocator.overrideVariable: "/fixture/gh"], isExecutable: { _ in true })

/// Records argv and returns scripted replies; never launches a process.
private final class ScriptedRunner: CommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [CommandResult]
    private(set) var calls: [[String]] = []
    init(_ replies: [CommandResult]) { self.replies = replies }
    func run(executable: URL, arguments: [String], timeout: TimeInterval) throws -> CommandResult {
        lock.lock(); defer { lock.unlock() }
        calls.append(arguments)
        return replies.isEmpty ? CommandResult(exitCode: 1, stderr: Data("unscripted".utf8)) : replies.removeFirst()
    }
}

private final class FixedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    func now() -> ContinuousClock.Instant { lock.lock(); defer { lock.unlock() }; return instant }
    func advance(_ seconds: Int) { lock.lock(); instant = instant.advanced(by: .seconds(seconds)); lock.unlock() }
}

private func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }
private func ok(_ object: Any, exit: Int32 = 0) -> CommandResult { CommandResult(exitCode: exit, stdout: json(object)) }
private func viewer(_ account: ScopeAccount = accountA) -> [String: Any] { ["id": account.viewerID, "login": "fixture-user"] }
private func org(_ login: String) -> MonitoringTarget { try! MonitoringTarget(organization: login) }
private func repo(_ name: String) -> MonitoringTarget { try! MonitoringTarget(repository: name) }

@Suite struct ScopeDraftTests {
    @Test func corruptSavedSelectionOpensAsEmptySelectedNeverEverything() {
        let draft = ScopeDraft(scope: nil)
        #expect(draft.mode == .selected && draft.rows.isEmpty)
        #expect(draft.candidate == nil && draft.blockingMessage != nil)
    }

    @Test func addTrimsDedupesCaseInsensitivelyAndKeepsListsSeparate() throws {
        var draft = ScopeDraft(scope: .everything)
        draft.mode = .selected
        #expect(draft.add("  Demo-Org \n", kind: .organization) == nil)
        #expect(draft.rows.first?.text == "Demo-Org")
        #expect(draft.add("demo-org", kind: .organization) == .duplicate)
        #expect(draft.add("demo-org/pet", kind: .repository) == nil, "an organization and its repository are a union, not a duplicate")
        #expect(draft.add(" DEMO-ORG/Pet ", kind: .repository) == .duplicate)
        #expect(draft.rows(.organization).count == 1 && draft.rows(.repository).count == 1)
        let scope = try #require(draft.candidate)
        #expect(scope.targets == [org("demo-org"), repo("demo-org/pet")])
    }

    @Test func malformedAndInjectionInputIsRejectedBeforeItReachesTheDraft() {
        var draft = ScopeDraft(scope: nil)
        let organizations = ["", "   ", "demo org", "org:demo", "demo is:pr", "-demo", "demo-", "demo\"){viewer{id}}", "demo/pet",
                             "d\u{0435}mo", "demo\nrepo:other/x", String(repeating: "a", count: 40), "demo_org"]
        for input in organizations {
            #expect(draft.add(input, kind: .organization) != nil, "organization input must be rejected: \(input.debugDescription)")
        }
        let repositories = ["demo", "demo/", "/pet", "demo/pet/extra", "demo/pet repo:other/x", "demo/pet\"", "demo/..", "demo/.",
                            "demo/pe t", "de mo/pet", "demo/pet\n", "demo/pet\u{2028}is:issue", "demo/" + String(repeating: "p", count: 101)]
        for input in repositories {
            let problem = draft.add(input, kind: .repository)
            if input == "demo/pet\n" { #expect(problem == nil, "surrounding whitespace is trimmed"); continue }
            #expect(problem != nil, "repository input must be rejected: \(input.debugDescription)")
        }
        #expect(draft.rows.count == 1)
        #expect(draft.add("", kind: .organization) == .empty)
        #expect(draft.add("org:demo", kind: .organization) == .malformed)
    }

    @Test func combinedLimitIsTenAcrossBothLists() {
        var draft = ScopeDraft(scope: nil)
        for index in 0..<6 { #expect(draft.add("demo-\(index)", kind: .organization) == nil) }
        for index in 0..<4 { #expect(draft.add("demo-x/repo\(index)", kind: .repository) == nil) }
        #expect(draft.add("demo-extra", kind: .organization) == .overLimit)
        #expect(draft.add("demo-x/extra", kind: .repository) == .overLimit)
        #expect(draft.add("demo-0", kind: .organization) == .duplicate, "duplicates are reported before the limit")
        #expect(draft.candidate?.targets.count == 10)
        draft.remove(draft.rows[0].id)
        #expect(draft.add("demo-extra", kind: .organization) == nil)
    }

    @Test func editedRowsAreRevalidatedInline() throws {
        var draft = ScopeDraft(scope: try MonitoringScope(selected: [org("demo-a"), repo("demo-a/pet")]))
        let first = draft.rows[0].id, second = draft.rows[1].id
        draft.update(first, text: "demo a")
        #expect(draft.problems[first] == .malformed && draft.candidate == nil)
        draft.update(first, text: "")
        #expect(draft.problems[first] == .empty)
        draft.update(first, text: "DEMO-B")
        #expect(draft.problems.isEmpty)
        draft.add("demo-c", kind: .organization)
        let third = draft.rows[2].id
        draft.update(third, text: "Demo-B ")
        #expect(draft.problems[third] == .duplicate && draft.problems[first] == nil, "the later duplicate is flagged")
        draft.remove(second); draft.remove(third); draft.remove(first)
        #expect(draft.candidate == nil && draft.blockingMessage == "Add at least one organization or repository.")
        draft.mode = .everything
        #expect(draft.candidate == .everything && draft.blockingMessage == nil)
    }

    @Test func accessFindingsFollowTheirTargetAndEditingClearsThem() throws {
        var draft = ScopeDraft(scope: try MonitoringScope(selected: [org("demo-a"), org("demo-denied")]))
        draft.recordAccessProblems([org("demo-denied"): .unavailable])
        let denied = try #require(draft.rows.first { $0.text == "demo-denied" })
        #expect(draft.problems[denied.id] == .unavailable)
        #expect(draft.candidate != nil, "an access finding blocks nothing locally: Apply re-validates")
        draft.update(denied.id, text: "demo-b")
        #expect(draft.problems.isEmpty)
    }

    @Test func messagesNeverEchoInput() {
        for problem in [ScopeRowProblem.empty, .malformed, .duplicate, .overLimit, .unavailable, .renamed] {
            for kind in [MonitoringTarget.Kind.organization, .repository] {
                #expect(!problem.message(for: kind).contains("demo"))
            }
        }
    }
}

@Suite struct ScopeAccessValidationTests {
    private let scope = try! MonitoringScope(selected: [org("demo-org"), repo("demo-org/pet")])

    @Test func planCarriesTargetsOnlyAsVariablesForGithubDotCom() {
        let plan = ScopeAccessPlan(scope: scope, expectedAccount: accountA)
        #expect(Array(plan.arguments.prefix(4)) == ["api", "graphql", "--hostname", "github.com"])
        let query = plan.arguments[5]
        #expect(query.hasPrefix("query=query($owner0: String!, $owner1: String!, $name1: String!)"))
        #expect(query.contains("viewer { id login }") && !query.contains("demo") && !query.contains("search("))
        #expect(plan.arguments.contains("owner0=demo-org") && plan.arguments.contains("name1=pet"))
        #expect(!plan.arguments.contains { $0.hasPrefix("-F") || $0 == "--paginate" })
    }

    private func body(_ overrides: [String: Any] = [:]) -> [String: Any] {
        var data: [String: Any] = ["viewer": viewer(),
                                   "target0": ["__typename": "Organization", "id": "O_1", "login": "Demo-Org"],
                                   "target1": ["__typename": "Repository", "id": "R_1", "nameWithOwner": "demo-org/Pet"]]
        for (key, value) in overrides { data[key] = value }
        return data
    }
    private func parse(_ data: [String: Any], errors: Any? = nil) -> ScopeAccessOutcome {
        var envelope: [String: Any] = ["data": data]
        if let errors { envelope["errors"] = errors }
        return ScopeAccessParser.parse(json(envelope), plan: ScopeAccessPlan(scope: scope, expectedAccount: accountA))
    }

    @Test func verifiedOnlyWhenEveryTargetResolvesForTheExpectedViewer() {
        guard case .verified(let viewer) = parse(body()) else { Issue.record("expected verified"); return }
        #expect(viewer.account == accountA)
    }

    @Test func perTargetNotFoundOrForbiddenIsAnAnswerNotAFailure() {
        let outcome = parse(body(["target1": NSNull()]), errors: [["type": "NOT_FOUND", "path": ["target1"], "message": "x"]])
        #expect(outcome == .rejected(ScopeViewer(account: accountA, login: "fixture-user"), [repo("demo-org/pet"): .unavailable]))
        let forbidden = parse(body(["target0": NSNull()]), errors: [["type": "FORBIDDEN", "path": ["target0"]]])
        #expect(forbidden == .rejected(ScopeViewer(account: accountA, login: "fixture-user"), [org("demo-org"): .unavailable]))
    }

    @Test func renamedTargetIsReportedNotSilentlyAccepted() {
        let outcome = parse(body(["target1": ["__typename": "Repository", "id": "R_1", "nameWithOwner": "demo-org/new-pet"]]))
        #expect(outcome == .rejected(ScopeViewer(account: accountA, login: "fixture-user"), [repo("demo-org/pet"): .renamed]))
    }

    @Test func identityAndEnvelopeProblemsLeaveTheSelectionUnverified() {
        #expect(parse(body(["viewer": viewer(accountB)])) == .failed(.identityMismatch))
        #expect(parse(body(["viewer": NSNull()])) == .failed(.viewerUnavailable))
        #expect(parse(body(["viewer": ["id": "bad id", "login": "x"]])) == .failed(.viewerUnavailable))
        var missing = body(); missing.removeValue(forKey: "target1")
        #expect(parse(missing) == .failed(.malformedResponse), "a missing alias is not proof of absence")
        #expect(parse(body(["target0": ["__typename": "User", "id": "U_1", "login": "demo-org"]])) == .failed(.malformedResponse))
        #expect(parse(body(["target0": ["__typename": "Organization", "id": "bad id", "login": "demo-org"]])) == .failed(.malformedResponse))
        #expect(parse(body(), errors: [["message": "boom"]]) == .failed(.graphQLError))
        #expect(parse(body(), errors: [["type": "NOT_FOUND", "path": ["reviews0"]]]) == .failed(.graphQLError))
        #expect(parse(body(), errors: [["type": "NOT_FOUND", "path": ["target0"]]]) == .failed(.malformedResponse),
                "an error for a target that still returned metadata is contradictory")
        #expect(parse(body(), errors: []) == .failed(.graphQLError))
        #expect(parse(body(), errors: "malformed") == .failed(.graphQLError))
        #expect(parse(body(), errors: [["type": "RATE_LIMITED"]]) == .failed(.rateLimited))
        let plan = ScopeAccessPlan(scope: scope, expectedAccount: accountA)
        #expect(ScopeAccessParser.parse(Data("{".utf8), plan: plan) == .failed(.malformedResponse))
        #expect(ScopeAccessParser.parse(Data(count: CommandBudget.maximumBytes + 1), plan: plan) == .failed(.outputLimit))
    }

    @Test func ghClientClassifiesExitCodesWithoutTrustingAFailedProcess() {
        func validate(_ reply: CommandResult) -> ScopeAccessOutcome {
            ScopeGhAccess(locator: locator, runner: ScriptedRunner([reply]))
                .validate(scope: scope, expectedAccount: accountA, budget: CommandBudget(timeout: 20))
        }
        let notFound = ["data": body(["target1": NSNull()]), "errors": [["type": "NOT_FOUND", "path": ["target1"]]]] as [String: Any]
        if case .rejected = validate(ok(notFound, exit: 1)) {} else { Issue.record("gh exits 1 with a per-target NOT_FOUND answer") }
        #expect(validate(ok(["data": body()], exit: 1)) == .failed(.transport), "a failed process cannot verify")
        #expect(validate(CommandResult(exitCode: 4, stderr: Data("gh auth login".utf8))) == .failed(.signedOut))
        #expect(validate(CommandResult(exitCode: 1, stderr: Data("HTTP 401: Bad credentials".utf8))) == .failed(.signedOut))
        #expect(validate(CommandResult(exitCode: 1, stderr: Data("API rate limit exceeded".utf8))) == .failed(.rateLimited))
        #expect(validate(CommandResult(exitCode: 1, stderr: Data("dial tcp: lookup failed".utf8))) == .failed(.transport))
        var incomplete = ok(["data": body()]); incomplete.outputComplete = false
        #expect(validate(incomplete) == .failed(.incompleteOutput))
        let missing = ScopeGhAccess(locator: GhLocator(environment: ["PATH": "/nowhere"], isExecutable: { _ in false }), runner: ScriptedRunner([]))
        #expect(missing.validate(scope: scope, expectedAccount: accountA, budget: CommandBudget(timeout: 20)) == .failed(.ghMissing))
        #expect(validate(ok(["data": body()])) == .verified(ScopeViewer(account: accountA, login: "fixture-user")))
    }

    @Test func validationRespectsTheSharedBudget() {
        let clock = FixedClock()
        let expired = CommandBudget(timeout: 0, now: { clock.now() })
        let runner = ScriptedRunner([ok(["data": body()])])
        #expect(ScopeGhAccess(locator: locator, runner: runner).validate(scope: scope, expectedAccount: accountA, budget: expired) == .failed(.deadline))
        #expect(runner.calls.isEmpty, "no request starts after the deadline")
        let tiny = CommandBudget(timeout: 20, maximumBytes: 10, now: { clock.now() })
        #expect(ScopeGhAccess(locator: locator, runner: ScriptedRunner([ok(["data": body()])]))
            .validate(scope: scope, expectedAccount: accountA, budget: tiny) == .failed(.outputLimit))
    }
}

@Suite struct ScopeDiscoveryTests {
    private func page(organizations: [String]? = nil, organizationsMore: Bool = false, organizationCursor: Any? = "orgcursor",
                      repositories: [String]? = nil, repositoriesMore: Bool = false, repositoryCursor: Any? = "repocursor",
                      viewer account: ScopeAccount = accountA, login: String = "fixture-user",
                      errors: Any? = nil) -> CommandResult {
        var raw = viewer(account)
        raw["login"] = login
        if let organizations {
            raw["organizations"] = ["nodes": organizations.map { ["login": $0] },
                                    "pageInfo": ["hasNextPage": organizationsMore, "endCursor": organizationCursor ?? NSNull()]]
        }
        if let repositories {
            raw["repositories"] = ["nodes": repositories.map { ["nameWithOwner": $0] },
                                   "pageInfo": ["hasNextPage": repositoriesMore, "endCursor": repositoryCursor ?? NSNull()]]
        }
        var envelope: [String: Any] = ["data": ["viewer": raw]]
        if let errors { envelope["errors"] = errors }
        return ok(envelope)
    }
    private func names(_ prefix: String, _ range: Range<Int>) -> [String] { range.map { "\(prefix)\($0)" } }
    private func discover(_ replies: [CommandResult], budget: CommandBudget = CommandBudget(timeout: 20)) -> (ScopeDiscoveryResult, ScriptedRunner) {
        let runner = ScriptedRunner(replies)
        return (ScopeGhAccess(locator: locator, runner: runner).discover(expectedAccount: accountA, budget: budget), runner)
    }

    @Test func firstPagePlanUsesNoCursorAndSafeArguments() {
        let plan = ScopeDiscoveryPagePlan(organizationCursor: .some(nil), repositoryCursor: .some(nil))
        #expect(Array(plan.arguments.prefix(4)) == ["api", "graphql", "--hostname", "github.com"])
        #expect(plan.arguments.count == 6, "no variables on the first page")
        let query = plan.arguments[5]
        #expect(query.hasPrefix("query=query {") && query.contains("organizations(first: 50)") && query.contains("repositories(first: 50,"))
        #expect(query.contains("ORGANIZATION_MEMBER") && !query.contains("$"))
        let next = ScopeDiscoveryPagePlan(organizationCursor: .some("abc=="), repositoryCursor: nil)
        #expect(next.arguments[5].contains("after: $organizationCursor") && !next.arguments[5].contains("repositories("))
        #expect(next.arguments.suffix(2) == ["-f", "organizationCursor=abc=="])
    }

    @Test func singlePageIsExhaustedNotComplete() {
        let (result, runner) = discover([page(organizations: ["Demo-A", "demo-a", "demo-b"], repositories: ["demo-a/pet"])])
        #expect(runner.calls.count == 1)
        #expect(result.organizations == ScopeDiscoveryCategory(suggestions: ["Demo-A", "demo-b"], completion: .exhausted, pages: 1))
        #expect(result.repositories.completion == .exhausted && result.failure == nil && result.viewer?.account == accountA)
    }

    @Test func manualCursorsStopAtThreePagesAndOnlyRequestOpenCategories() {
        let replies = [
            page(organizations: names("org-a", 0..<50), organizationsMore: true, organizationCursor: "c1",
                 repositories: names("demo/r", 0..<10)),
            page(organizations: names("org-b", 0..<50), organizationsMore: true, organizationCursor: "c2"),
            page(organizations: names("org-c", 0..<50), organizationsMore: true, organizationCursor: "c3"),
        ]
        let (result, runner) = discover(replies)
        #expect(runner.calls.count == 3, "never a fourth page")
        #expect(runner.calls[1].suffix(2) == ["-f", "organizationCursor=c1"] && runner.calls[2].suffix(2) == ["-f", "organizationCursor=c2"])
        #expect(!runner.calls[1][5].contains("repositories("), "an exhausted category is not refetched")
        #expect(result.organizations.completion == .capped && result.organizations.suggestions.count == 150 && result.organizations.pages == 3)
        #expect(result.repositories.completion == .exhausted && result.repositories.suggestions.count == 10)
    }

    @Test func laterPageErrorKeepsEarlierHintsAsPartial() {
        let (result, runner) = discover([
            page(organizations: names("org-a", 0..<50), organizationsMore: true, organizationCursor: "c1",
                 repositories: names("demo/r", 0..<50), repositoriesMore: true, repositoryCursor: "r1"),
            page(organizations: ["late-org"], organizationsMore: true, repositories: nil, errors: [["message": "fixture"]]),
        ])
        #expect(runner.calls.count == 2)
        #expect(result.organizations.completion == .partial && result.organizations.suggestions.count == 51)
        #expect(result.repositories.completion == .partial && result.repositories.suggestions.count == 50)
        #expect(result.failure == .graphQLError)
    }

    @Test func identityIsCheckedOnEveryPage() {
        let (mismatch, _) = discover([
            page(organizations: names("org-a", 0..<50), organizationsMore: true, organizationCursor: "c1", repositories: []),
            page(organizations: ["other-account-org"], viewer: accountB),
        ])
        #expect(mismatch == .failed(.identityMismatch), "a mid-run account change discards every hint")
        let (first, runner) = discover([page(organizations: ["x"], repositories: [], viewer: accountB)])
        #expect(first == .failed(.identityMismatch) && runner.calls.count == 1)
    }

    @Test func loginRenameBetweenPagesKeepsHintsButAnIDChangeStillFailsClosed() {
        let (renamed, runner) = discover([
            page(organizations: ["first-org"], organizationsMore: true, organizationCursor: "c1",
                 repositories: ["demo/first"], login: "old-login"),
            page(organizations: ["second-org"], login: "new-login"),
        ])
        #expect(runner.calls.count == 2)
        #expect(renamed.failure == nil, "a display-login rename of the same opaque ID is the same account")
        #expect(renamed.viewer == ScopeViewer(account: accountA, login: "new-login"))
        #expect(renamed.organizations == .init(suggestions: ["first-org", "second-org"], completion: .exhausted, pages: 2))
        #expect(renamed.repositories == .init(suggestions: ["demo/first"], completion: .exhausted, pages: 1))
        // Same display login, different opaque ID: still a different account.
        let (sameLogin, _) = discover([
            page(organizations: ["first-org"], organizationsMore: true, organizationCursor: "c1", repositories: [], login: "same-login"),
            page(organizations: ["other-org"], viewer: accountB, login: "same-login"),
        ])
        #expect(sameLogin == .failed(.identityMismatch))
    }

    /// JSON 0/1 bridge to NSNumber and would pass `as? Bool`; only a genuine JSON boolean may
    /// certify the end (or cap) of a category.
    @Test func hasNextPageMustBeAGenuineJSONBooleanForBothCategories() {
        func reply(_ more: Any?, cursor: String = "c1") -> CommandResult {
            var info: [String: Any] = ["endCursor": cursor]
            if let more { info["hasNextPage"] = more }
            var raw = viewer()
            raw["organizations"] = ["nodes": [["login": "org-\(cursor)"]], "pageInfo": info]
            raw["repositories"] = ["nodes": [["nameWithOwner": "demo/\(cursor)"]], "pageInfo": info]
            return ok(["data": ["viewer": raw]])
        }
        for bad in [0, 1] as [Any] {
            // First page: nothing is certified and no cursor is followed.
            let (first, runner) = discover([reply(bad)])
            #expect(runner.calls.count == 1, "numeric \(bad) never opens a later page")
            #expect(first.organizations.completion == .failed && first.repositories.completion == .failed)
            #expect(first.organizations.suggestions.isEmpty && first.repositories.suggestions.isEmpty)
            // Last page: earlier hints remain, but neither end nor cap is certified.
            let (last, lastRunner) = discover([reply(true, cursor: "c1"), reply(true, cursor: "c2"), reply(bad, cursor: "c3")])
            #expect(lastRunner.calls.count == 3)
            #expect(last.organizations == .init(suggestions: ["org-c1", "org-c2"], completion: .partial, pages: 2))
            #expect(last.repositories == .init(suggestions: ["demo/c1", "demo/c2"], completion: .partial, pages: 2))
        }
        for bad in ["false", "true", NSNull(), nil] as [Any?] {
            let (malformed, _) = discover([reply(bad)])
            #expect(malformed.organizations.completion == .failed && malformed.repositories.completion == .failed)
        }
        let (exhausted, _) = discover([reply(false)])
        #expect(exhausted.organizations.completion == .exhausted && exhausted.repositories.completion == .exhausted)
        let (capped, cappedRunner) = discover([reply(true, cursor: "c1"), reply(true, cursor: "c2"), reply(true, cursor: "c3")])
        #expect(cappedRunner.calls.count == 3)
        #expect(capped.organizations.completion == .capped && capped.repositories.completion == .capped)
        let (errored, _) = discover([CommandResult(exitCode: 0, stdout: json(["data": ["viewer": {
            var raw = viewer(); raw["organizations"] = ["nodes": [], "pageInfo": ["hasNextPage": false]]; return raw }()],
            "errors": [["message": "fixture"]]]))])
        #expect(errored.failure == .graphQLError && errored.organizations.completion == .partial)
    }

    @Test func malformedEntriesCursorsAndConnectionsAreVisiblyIncomplete() {
        let (badNode, _) = discover([page(organizations: ["good", "bad org", "org:x"], repositories: ["demo/pet", "no-slash"])])
        #expect(badNode.organizations == ScopeDiscoveryCategory(suggestions: ["good"], completion: .partial, pages: 1))
        #expect(badNode.repositories.completion == .partial && badNode.repositories.suggestions == ["demo/pet"])
        let (badCursor, runner) = discover([page(organizations: ["a"], organizationsMore: true, organizationCursor: "bad cursor!",
                                                 repositories: ["demo/pet"], repositoriesMore: true, repositoryCursor: NSNull())])
        #expect(runner.calls.count == 1)
        #expect(badCursor.organizations.completion == .partial && badCursor.repositories.completion == .partial)
        let (missing, _) = discover([page(organizations: nil, repositories: ["demo/pet"])])
        #expect(missing.organizations.completion == .failed && missing.repositories.completion == .exhausted)
        let (oversized, _) = discover([page(organizations: names("o", 0..<51), repositories: [])])
        #expect(oversized.organizations.completion == .failed, "more nodes than requested is malformed")
    }

    @Test func malformedConnectionOnACleanPageNamesAFailureReason() {
        let (first, _) = discover([page(organizations: nil, repositories: ["demo/pet"])])
        #expect(first.organizations.completion == .failed && first.repositories.completion == .exhausted)
        #expect(first.failure == .malformedResponse, "a failed category always carries a reason")
        let (later, runner) = discover([
            page(organizations: ["a"], organizationsMore: true, organizationCursor: "c1", repositories: ["demo/pet"]),
            ok(["data": ["viewer": viewer()]]),
        ])
        #expect(runner.calls.count == 2)
        #expect(later.organizations == .init(suggestions: ["a"], completion: .partial, pages: 1))
        #expect(later.failure == .malformedResponse && later.repositories.completion == .exhausted)
        let (clean, _) = discover([page(organizations: ["a"], repositories: ["demo/pet"])])
        #expect(clean.failure == nil, "control: well-formed pages report no failure")
        let (errored, _) = discover([page(organizations: nil, repositories: [], errors: [["message": "fixture"]])])
        #expect(errored.failure == .graphQLError, "an explicit page error keeps its own reason")
    }

    @Test func deniedSignedOutRateLimitedAndMissingGhAreFailuresNotEmptyLists() {
        let (denied, _) = discover([CommandResult(exitCode: 4, stderr: Data("run gh auth login".utf8))])
        #expect(denied.failure == .signedOut && denied.organizations.completion == .failed && denied.repositories.completion == .failed)
        let (limited, _) = discover([page(organizations: [], repositories: [], errors: [["type": "RATE_LIMITED"]])])
        #expect(limited.failure == .rateLimited && limited.organizations.completion == .partial)
        let (transport, _) = discover([CommandResult(exitCode: 1, stderr: Data("could not resolve host".utf8))])
        #expect(transport.failure == .transport && transport.organizations.suggestions.isEmpty)
        let (failedExit, _) = discover([CommandResult(exitCode: 1, stdout: page(organizations: ["a"], repositories: []).stdout)])
        #expect(failedExit.failure == .transport, "a failed gh exit never reports a clean exhausted list")
        #expect(failedExit.organizations.completion == .partial && failedExit.organizations.suggestions == ["a"])
        #expect(failedExit.repositories.completion == .partial, "even an empty category from a failed page is unverified")
        let missing = ScopeGhAccess(locator: GhLocator(environment: ["PATH": "/nowhere"], isExecutable: { _ in false }), runner: ScriptedRunner([]))
        #expect(missing.discover(expectedAccount: accountA, budget: CommandBudget(timeout: 20)) == .failed(.ghMissing))
    }

    @Test func parseableFailedExitCannotCertifyExhaustionOrCapForEitherCategory() {
        let first = page(organizations: ["first-org"], organizationsMore: true,
                         repositories: ["demo/first"], repositoriesMore: true)
        let second = page(organizations: ["second-org"], organizationsMore: true,
                          repositories: ["demo/second"], repositoriesMore: true)
        for more in [false, true] {
            let last = page(organizations: ["last-org"], organizationsMore: more,
                            repositories: ["demo/last"], repositoriesMore: more)
            let (result, runner) = discover([first, second, CommandResult(exitCode: 1, stdout: last.stdout)])
            #expect(runner.calls.count == 3 && result.failure == .transport)
            #expect(result.organizations == .init(suggestions: ["first-org", "second-org", "last-org"], completion: .partial, pages: 3))
            #expect(result.repositories == .init(suggestions: ["demo/first", "demo/second", "demo/last"], completion: .partial, pages: 3))
        }
        // A category exhausted on an earlier successful page keeps that proof. Only the
        // still-open category is affected by the later failed process.
        let (earlierComplete, _) = discover([
            page(organizations: ["a"], organizationsMore: true, repositories: ["demo/pet"]),
            CommandResult(exitCode: 1, stdout: page(organizations: ["b"]).stdout),
        ])
        #expect(earlierComplete.organizations.completion == .partial && earlierComplete.organizations.suggestions == ["a", "b"])
        #expect(earlierComplete.repositories.completion == .exhausted)
    }

    @Test func cancelledBudgetStopsBeforeTheNextPageAndCertifiesNothing() {
        let budget = CommandBudget(timeout: 20)
        let runner = ScriptedRunner([
            page(organizations: ["first-org"], organizationsMore: true, repositories: ["demo/first"], repositoriesMore: true),
            page(organizations: ["second-org"], repositories: ["demo/second"]),
        ])
        let result = ScopeDiscovery.run(expectedAccount: accountA, budget: budget) { plan in
            let reply = try runner.run(executable: URL(fileURLWithPath: "/fixture/gh"), arguments: plan.arguments, timeout: 1)
            budget.cancel() // as ScopeEditor's cancellation handler does while a page is in flight
            return reply
        }
        #expect(runner.calls.count == 1, "no later page after cancellation")
        #expect(result.failure == .cancelled)
        #expect(result.organizations.completion == .failed && result.repositories.completion == .failed,
                "the in-flight page lands after cancellation and is not trusted")
        #expect(result.organizations.suggestions.isEmpty && result.repositories.suggestions.isEmpty)
        let precancelled = CommandBudget(timeout: 20)
        precancelled.cancel()
        let (none, idle) = discover([page(organizations: ["x"], repositories: [])], budget: precancelled)
        #expect(idle.calls.isEmpty && none.failure == .cancelled && none.organizations.completion == .failed)
    }

    @Test func sharedDeadlineAndByteBudgetSpanAllPages() {
        let clock = FixedClock()
        let budget = CommandBudget(timeout: 20, now: { clock.now() })
        let runner = ScriptedRunner([])
        let result = ScopeDiscovery.run(expectedAccount: accountA, budget: budget) { plan in
            let reply = try runner.run(executable: URL(fileURLWithPath: "/fixture/gh"), arguments: plan.arguments, timeout: 1)
            clock.advance(21) // the first page consumes the whole injected budget
            _ = reply
            return page(organizations: names("o", 0..<50), organizationsMore: true, organizationCursor: "c1", repositories: [])
        }
        #expect(runner.calls.count == 1 && result.failure == .deadline)
        #expect(result.organizations.completion == .failed, "a page that lands after the deadline is not trusted")
        let tiny = CommandBudget(timeout: 20, maximumBytes: 64, now: { clock.now() })
        let (overflow, _) = discover([page(organizations: names("o", 0..<50), repositories: [])], budget: tiny)
        #expect(overflow.failure == .outputLimit && overflow.organizations.suggestions.isEmpty)
    }
}
