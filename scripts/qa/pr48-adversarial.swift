import Foundation
import GitHubPetCore

private final class QueueRunner: CommandRunner, @unchecked Sendable {
    var replies: [CommandResult]
    var calls: [[String]] = []
    init(_ replies: [CommandResult]) { self.replies = replies }
    func run(executable: URL, arguments: [String], timeout: TimeInterval) throws -> CommandResult {
        calls.append(arguments)
        return replies.removeFirst()
    }
}
private final class Receipt: @unchecked Sendable {
    let lock = NSLock()
    var pid: Int32 = 0
    var remaining: Double = 0
    var alive = false
    func record(_ pid: Int32, _ remaining: Double) {
        lock.lock(); defer { lock.unlock() }
        self.pid = pid; self.remaining = remaining; alive = kill(pid, 0) == 0
    }
}
@main struct AdversarialQA {
    static func main() async throws {
        var checks = 0, failures = 0
        func check(_ name: String, _ value: @autoclosure () -> Bool) {
            checks += 1
            if value() { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
        }
        func complete(_ outcome: FetchOutcome) -> Bool {
            if case .snapshot(_, let value) = outcome { return value }; return false
        }
        let a = try ScopeAccount(viewerID: "U_QA_A"), b = try ScopeAccount(viewerID: "U_QA_B")
        let scope = try MonitoringScope(selected: [MonitoringTarget(organization: "example"), MonitoringTarget(repository: "example/pet")])
        let plan = try ScopeQueryPlan(scope: scope, expectedAccount: a)
        func page(_ rows: [[String: Any]] = []) -> [String: Any] {
            ["issueCount": rows.count, "nodes": rows, "pageInfo": ["hasNextPage": false]]
        }
        func row(_ id: String, issue: Bool = false) -> [String: Any] {
            ["__typename": issue ? "Issue" : "PullRequest", "id": id, "number": 7, "title": "QA fixture", "url": "https://github.com/example/pet/\(issue ? "issues" : "pull")/7", "updatedAt": "2026-11-14T00:00:00Z", "repository": ["nameWithOwner": "example/pet"]]
        }
        func body(_ plan: ScopeQueryPlan, viewer: String = "U_QA_A") -> [String: Any] {
            var data: [String: Any] = ["viewer": ["id": viewer, "login": "fixture-user"]]
            for (i, target) in plan.scope.targets.enumerated() {
                data["target\(i)"] = target.kind == .organization
                    ? ["__typename": "Organization", "id": "O_QA", "login": target.owner]
                    : ["__typename": "Repository", "id": "R_QA", "nameWithOwner": "\(target.owner)/\(target.name!)"]
            }
            for search in plan.searches { data[search.alias] = page() }
            return data
        }
        func envelope(_ data: [String: Any], errors: [[String: Any]]? = nil) throws -> Data {
            var value: [String: Any] = ["data": data]
            if let errors { value["errors"] = errors }
            return try JSONSerialization.data(withJSONObject: value)
        }
        let query = plan.arguments.first { $0.hasPrefix("query=") }!
        check("one operation viewer plus metadata plus four source aliases", query.contains("viewer { id login }") && query.contains("target0:") && query.contains("target1:") && plan.searches.count == 4 && plan.searches.allSatisfy { query.contains($0.alias + ":") })
        check("target values separate from query syntax", !query.contains("example") && plan.arguments.contains("reviews0=is:pr is:open review-requested:@me org:example") && plan.arguments.contains("reviews1=is:pr is:open review-requested:@me repo:example/pet"))
        var mixed = body(plan)
        mixed["reviews0"] = page([row("PR_QA")]); mixed["reviews1"] = page([row("PR_QA")])
        mixed["assigned0"] = page([row("ISSUE_QA", issue: true)]); mixed["assigned1"] = page([row("ISSUE_QA", issue: true)])
        let union = ScopedResponseParser.parse(try envelope(mixed), plan: plan)
        check("mixed overlap union preserves stable kind IDs", union.complete && Set(union.items.map(\.id)) == ["reviewRequest:PR_QA", "assignedIssue:ISSUE_QA"])
        let mismatch = ScopedResponseParser.parse(try envelope(body(plan, viewer: b.viewerID)), plan: plan)
        check("expected account mismatch discards all targets and rows", mismatch.issues == [.identityMismatch] && mismatch.items.isEmpty && mismatch.successfulSources == 0)
        for mode in ["metadata", "missing", "badcount", "badrow", "cap", "errors"] {
            var changed = mixed
            switch mode {
            case "metadata": changed["target0"] = NSNull()
            case "missing": changed.removeValue(forKey: "assigned1")
            case "badcount": changed["reviews0"] = ["issueCount": true, "nodes": [], "pageInfo": ["hasNextPage": false]]
            case "badrow": changed["reviews0"] = page([["id": "bad"]])
            case "cap": changed["reviews0"] = ["issueCount": 31, "nodes": [], "pageInfo": ["hasNextPage": true]]
            default: break
            }
            let parsed = ScopedResponseParser.parse(try envelope(changed, errors: mode == "errors" ? [["type": "RATE_LIMITED"]] : nil), plan: plan)
            check("strict partial \(mode) never complete", !parsed.complete && !parsed.issues.isEmpty)
        }
        var none = body(plan); none["target0"] = NSNull(); none["target1"] = NSNull()
        let unavailable = ScopedResponseParser.parse(try envelope(none), plan: plan)
        check("no verified targets is failure, not empty", unavailable.successfulSources == 0 && !complete(unavailable.outcome))
        let defaults = UserDefaults(suiteName: "qa.scope.\(UUID().uuidString)")!
        let suite = defaults.volatileDomainNames // no standard domain is written
        _ = suite
        let store = ScopeSelectionStore(defaults: defaults)
        try store.save(scope, for: .github(a))
        let key = defaults.dictionaryRepresentation().keys.first { $0.contains("monitoring-scope") && $0.contains(a.viewerID) }!
        defaults.set(Data("invalid JSON".utf8), forKey: key)
        check("corrupt record fails closed and another account remains isolated", store.load(for: .github(a)) == .corruptConfiguration && store.load(for: .github(b)) == .scope(.everything) && store.load(for: .demo) == .scope(.everything))
        defaults.removeObject(forKey: key)

        // Public API is compiled with NORMAL import, no @testable or copied implementation.
        let budget = CommandBudget(timeout: 100, maximumBytes: 9)
        check("public deadline clamps to20seconds", budget.remaining > 0 && budget.remaining <= 20)
        check("public atomic reservation and latch", budget.reserve(6) && budget.reserve(3) && !budget.reserve(1) && budget.consumedBytes == 9)
        do { try budget.check(); check("public overflow typed", false) } catch { check("public overflow typed", error as? CommandError == .outputLimitExceeded) }
        let locator = GhLocator(environment: [GhLocator.overrideVariable: "/fixture/gh"], isExecutable: { _ in true })
        let switched = QueueRunner([CommandResult(exitCode: 0), CommandResult(exitCode: 0, stdout: try envelope(body(plan, viewer: b.viewerID))), CommandResult(exitCode: 0), CommandResult(exitCode: 0, stdout: try envelope(mixed))])
        let scoped = ScopedGhClient(locator: locator, runner: switched)
        check("scoped switched poll discarded", scoped.fetch(scope: scope, expectedAccount: a).issues == [.identityMismatch])
        check("scoped return to A refetches independently", scoped.fetch(scope: scope, expectedAccount: a).complete && switched.calls.filter { $0.first == "api" }.count == 2)
        var legacy = body(try ScopeQueryPlan()); legacy["reviews"] = page(); legacy["assigned"] = page()
        let payload = try envelope(legacy)
        let oldRunner = QueueRunner([CommandResult(exitCode: 0), CommandResult(exitCode: 0, stdout: payload)])
        let old = GhClient(locator: locator, runner: oldRunner).fetchWithAccount()
        check("legacy Everything remains request-bound to response login", old.account == "fixture-user" && complete(old.outcome) && oldRunner.calls.filter { $0.first == "api" }.count == 1 && oldRunner.calls.last!.joined().contains("viewer { login }"))
        for legacyClient in [true, false] {
            let partialRunner = QueueRunner([CommandResult(exitCode: 0), CommandResult(exitCode: 0, stdout: payload, outputComplete: false)])
            check("\(legacyClient ? "legacy" : "scoped") incomplete valid JSON prefix rejected", legacyClient ? !complete(GhClient(locator: locator, runner: partialRunner).fetch()) : ScopedGhClient(locator: locator, runner: partialRunner).fetch().issues == [.incompleteOutput])
        }

        let root = URL(fileURLWithPath: CommandLine.arguments[1]), python = CommandLine.arguments[2]
        let base64 = payload.base64EncodedString()
        for legacyClient in [true, false] {
            for mode in ["positive", "aggregate", "chatty", "descendant", "deadline", "failed_valid"] {
                let file = root.appendingPathComponent("\(legacyClient)-\(mode).py")
                let script = """
                #!\(python)
                import base64,os,subprocess,sys,time
                mode='\(mode)'
                auth=sys.argv[1]=='auth'
                if mode=='deadline': time.sleep(0.18)
                if auth:
                    if mode=='aggregate': os.write(2,b'p'*1100000)
                    sys.exit(0)
                os.write(1,base64.b64decode('\(base64)'))
                if mode=='aggregate': os.write(2,b'r'*1100000)
                if mode=='chatty':
                    while True: os.write(2,b'x'*65536)
                if mode=='descendant': subprocess.Popen(['/bin/sleep','3'],stdout=sys.stdout,stderr=sys.stderr)
                sys.exit(7 if mode=='failed_valid' else 0)
                """
                try script.write(to: file, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
                let realLocator = GhLocator(environment: [GhLocator.overrideVariable: file.path])
                let start = ContinuousClock.now
                let timeout = mode == "deadline" ? 0.25 : 6.0
                let label = "real \(legacyClient ? "legacy" : "scoped") \(mode)"
                if legacyClient {
                    let result = GhClient(locator: realLocator, timeout: timeout).fetch()
                    check(label, mode == "positive" ? complete(result) : !complete(result))
                } else {
                    let result = ScopedGhClient(locator: realLocator, timeout: timeout).fetch()
                    let expected: ScopedFetchIssue? = ["aggregate": .outputLimit, "chatty": .outputLimit, "descendant": .incompleteOutput, "deadline": .deadline, "failed_valid": .transport][mode]
                    check(label, mode == "positive" ? result.complete : (!result.complete && result.issues.contains(expected!)))
                }
                print("TIMING \(label) elapsed=\(start.duration(to: .now))")
            }
        }

        // Deterministic cancellation from a GCD readiness observer, not an async sleep race.
        let fifo = root.appendingPathComponent("started")
        precondition(mkfifo(fifo.path, 0o600) == 0)
        let fd = open(fifo.path, O_RDWR | O_NONBLOCK); precondition(fd >= 0)
        let unrelated = Process(), input = Pipe(), ended = DispatchGroup()
        unrelated.executableURL = URL(fileURLWithPath: "/bin/cat"); unrelated.standardInput = input
        unrelated.standardOutput = FileHandle.nullDevice; unrelated.standardError = FileHandle.nullDevice
        ended.enter(); unrelated.terminationHandler = { _ in ended.leave() }; try unrelated.run()
        let activeBudget = CommandBudget(timeout: 5), receipt = Receipt(), observer = DispatchGroup()
        let task = Task.detached {
            try ProcessCommandRunner().run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf '%s\\n' $$ > \"$1\"; exec /bin/sleep 10", "qa", fifo.path], budget: activeBudget)
        }
        observer.enter()
        DispatchQueue(label: "qa.cancel.independent").async {
            defer { close(fd); observer.leave() }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&descriptor, 1, 4000) > 0 {
                var bytes = [UInt8](repeating: 0, count: 64)
                let count = read(fd, &bytes, bytes.count)
                if count > 0, let pid = Int32(String(decoding: bytes.prefix(count), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) { receipt.record(pid, activeBudget.remaining) }
            }
            task.cancel()
        }
        do { _ = try await task.value; check("inflight cancellation typed", false) }
        catch { check("inflight cancellation typed", error as? CommandError == .cancelled) }
        check("independent handshake completed", observer.wait(timeout: .now() + 2) == .success)
        check("cancel actual child before deadline; child gone; unrelated alive", receipt.pid > 1 && receipt.alive && receipt.remaining > 0 && kill(receipt.pid, 0) == -1 && errno == ESRCH && unrelated.isRunning)
        try input.fileHandleForWriting.close()
        check("own unrelated fixture exits cleanly", ended.wait(timeout: .now() + 2) == .success)
        let marker = root.appendingPathComponent("should-not-launch")
        let gate = DispatchSemaphore(value: 0)
        let pre = Task.detached {
            guard gate.wait(timeout: .now() + 2) == .success else { throw CommandError.timedOut }
            return try ProcessCommandRunner().run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf x > \"$1\"", "qa", marker.path], timeout: 5)
        }
        pre.cancel(); gate.signal()
        do { _ = try await pre.value; check("prelaunch cancellation", false) } catch { check("prelaunch cancellation", error as? CommandError == .cancelled && !FileManager.default.fileExists(atPath: marker.path)) }
        print("RESULT checks=\(checks) failures=\(failures); NORMAL import, no authentication/network/UI")
        exit(failures == 0 ? 0 : 1)
    }
}
