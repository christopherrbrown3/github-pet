import Foundation
import GitHubPetCore

private final class QualityRunner: CommandRunner, @unchecked Sendable {
    var replies: [CommandResult]
    init(_ replies: [CommandResult]) { self.replies = replies }
    func run(executable: URL, arguments: [String], timeout: TimeInterval) throws -> CommandResult { replies.removeFirst() }
}
@main struct QualityQA {
    static func main() throws {
        var failures = 0, checks = 0
        func check(_ name: String, _ value: @autoclosure () -> Bool) {
            checks += 1
            if value() { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
        }
        let node: [String: Any] = ["id": "PR_quality", "number": 7, "title": "Quality fixture", "url": "https://github.com/example/pet/pull/7", "updatedAt": "2026-11-14T00:00:00Z", "repository": ["nameWithOwner": "example/pet"]]
        func payload(rows: Bool, errors: Any? = nil) throws -> Data {
            let page: [String: Any] = ["issueCount": rows ? 1 : 0, "nodes": rows ? [node] : []]
            var outer: [String: Any] = ["data": ["viewer": ["login": "fixture-user"], "reviews": page, "assigned": ["issueCount": 0, "nodes": []]]]
            if let errors { outer["errors"] = errors }
            return try JSONSerialization.data(withJSONObject: outer)
        }
        func checkFetch(_ name: String, _ fetch: GhClient.AccountFetch, rows: Bool, expectedComplete: Bool) {
            check(name + " same response account", fetch.account == "fixture-user")
            if case .snapshot(let items, let complete) = fetch.outcome {
                check(name + " quality and proven rows", complete == expectedComplete && items.count == (rows ? 1 : 0))
                let engine = InboxEngine()
                engine.apply(fetch.outcome, now: Date(timeIntervalSince1970: 1000))
                check(name + " engine does not certify errored empty/count", expectedComplete ? engine.state.countIsKnown : (engine.state == .partial && !engine.state.countIsKnown))
            } else { check(name + " retains valid pages as snapshot", false) }
        }
        let locator = GhLocator(environment: [GhLocator.overrideVariable: "/quality/fixture"], isExecutable: { _ in true })
        let variants: [(String, Any)] = [("reported", [["message": "fixture error"]]), ("string", "bad"), ("object", ["message": "bad"]), ("null", NSNull()), ("emptyarray", [Any]()), ("nullentry", [NSNull()]), ("emptyentry", [[String: Any]()]), ("boolean", false), ("number", 42)]
        for rows in [false, true] {
            for (name, errors) in variants {
                let data = try payload(rows: rows, errors: errors)
                check("parser tracks errors presence \(name) rows=\(rows)", GhGraphQLParser.parse(data)?.hasErrorEnvelope == true)
                let runner = QualityRunner([CommandResult(exitCode: 0), CommandResult(exitCode: 0, stdout: data)])
                checkFetch("errors=\(name) rows=\(rows)", GhClient(locator: locator, runner: runner).fetchWithAccount(), rows: rows, expectedComplete: false)
            }
            let data = try payload(rows: rows)
            check("parser no-error control rows=\(rows)", GhGraphQLParser.parse(data)?.hasErrorEnvelope == false)
            for exitCode in [Int32(0), 7] {
                let runner = QualityRunner([CommandResult(exitCode: 0), CommandResult(exitCode: exitCode, stdout: data)])
                checkFetch("exit=\(exitCode) rows=\(rows)", GhClient(locator: locator, runner: runner).fetchWithAccount(), rows: rows, expectedComplete: exitCode == 0)
            }
        }
        // Actual collector/fake-gh positive-after cases; no real CLI authentication or network.
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        for (label, code, rows, errors) in [("failedempty", 7, false, false), ("failedrow", 7, true, false), ("errorexit0", 0, false, true), ("positivezero", 0, false, false)] {
            let folder = root.appendingPathComponent(label)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try payload(rows: rows, errors: errors ? [["message": "fixture failure"]] : nil).write(to: folder.appendingPathComponent("payload"))
            let gh = folder.appendingPathComponent("gh")
            try "#!/bin/sh\nif [ \"$1\" = auth ]; then exit 0; fi\n/bin/cat \"${0%/*}/payload\"\nexit \(code)\n".write(to: gh, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh.path)
            let actual = GhClient(locator: GhLocator(environment: [GhLocator.overrideVariable: gh.path]), timeout: 3).fetchWithAccount()
            checkFetch("real \(label)", actual, rows: rows, expectedComplete: code == 0 && !errors)
        }
        print("RESULT checks=\(checks) failures=\(failures); NORMAL import, isolated fixtures only")
        exit(failures == 0 ? 0 : 1)
    }
}
