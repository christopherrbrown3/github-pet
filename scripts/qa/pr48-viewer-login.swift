import Foundation
import GitHubPetCore

private final class ViewerLoginRunner: CommandRunner, @unchecked Sendable {
    var replies: [CommandResult]
    init(_ data: Data) { replies = [CommandResult(exitCode: 0), CommandResult(exitCode: 0, stdout: data)] }
    func run(executable: URL, arguments: [String], timeout: TimeInterval) throws -> CommandResult { replies.removeFirst() }
}
@main struct ViewerLoginQA {
    static func main() throws {
        let a = try ScopeAccount(viewerID: "U_fixture_A")
        let selected = try MonitoringScope(selected: [MonitoringTarget(repository: "example/pet")])
        let fixed = CommandLine.arguments.contains("--fixed")
        var failures = 0, checks = 0
        func check(_ name: String, _ value: @autoclosure () -> Bool) {
            checks += 1
            if value() { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
        }
        func parse(login: String?, id: String = "U_fixture_A", selectedMode: Bool, bindEverything: Bool = false, throughClient: Bool = false) throws -> ScopedPollResult {
            let expected = selectedMode || bindEverything ? a : nil
            let scope: MonitoringScope = selectedMode ? selected : .everything
            let plan = try ScopeQueryPlan(scope: scope, expectedAccount: expected)
            var viewer: [String: Any] = ["id": id]
            if let login { viewer["login"] = login }
            var body: [String: Any] = ["viewer": viewer]
            if selectedMode { body["target0"] = ["__typename": "Repository", "id": "R_fixture", "nameWithOwner": "example/pet"] }
            for search in plan.searches { body[search.alias] = ["issueCount": 0, "nodes": [], "pageInfo": ["hasNextPage": false]] }
            let bytes = try JSONSerialization.data(withJSONObject: ["data": body])
            if throughClient {
                let locator = GhLocator(environment: [GhLocator.overrideVariable: "/viewer-login/fixture"], isExecutable: { _ in true })
                return ScopedGhClient(locator: locator, runner: ViewerLoginRunner(bytes)).fetch(scope: scope, expectedAccount: expected)
            }
            return ScopedResponseParser.parse(bytes, plan: plan)
        }
        let modes = fixed ? [(false, false), (false, true), (true, true)] : [(false, false), (true, true)]
        for (selectedMode, bound) in modes {
            let logins = fixed ? ["fixture-user", "fixture-user_demo", "demo_admin", String(repeating: "a", count: 34) + "_demo", "Fixture-User_demo"] : ["fixture-user", "fixture-user_demo", "demo_admin"]
            for login in logins {
                let result = try parse(login: login, selectedMode: selectedMode, bindEverything: bound)
                print("OBSERVED selected=\(selectedMode) bound=\(bound) login=\(login) complete=\(result.complete) viewer=\(result.viewer?.login ?? "nil") issues=\(result.issues)")
                if login == "fixture-user" || fixed {
                    check("valid display login \(login) selected=\(selectedMode)", result.complete && result.viewer?.account == a && result.viewer?.login == login)
                }
                if fixed {
                    let client = try parse(login: login, selectedMode: selectedMode, bindEverything: bound, throughClient: true)
                    check("client valid display login \(login) selected=\(selectedMode)", client.complete && client.viewer?.account == a && client.viewer?.login == login)
                }
            }
            if !fixed { continue }
            for bad in [Optional<String>.none, "", "bad login", "bad\nlogin", String(repeating: "a", count: 40)] {
                let result = try parse(login: bad, selectedMode: selectedMode, bindEverything: bound)
                check("missing/invalid display login rejected selected=\(selectedMode) input=\(bad.debugDescription)", result.viewer == nil && !result.complete)
                let client = try parse(login: bad, selectedMode: selectedMode, bindEverything: bound, throughClient: true)
                check("client missing/invalid display login rejected selected=\(selectedMode)", client.viewer == nil && !client.complete)
            }
            let badID = try parse(login: "demo_admin", id: "U_fixture_A\n", selectedMode: selectedMode)
            check("valid EMU display cannot bypass nodeID guard selected=\(selectedMode)", badID.viewer == nil && !badID.complete)
            if bound {
                let mismatch = try parse(login: "demo_admin", id: "U_fixture_B", selectedMode: selectedMode, bindEverything: true, throughClient: true)
                check("client expected account mismatch discards submitted results selected=\(selectedMode)", mismatch.issues == [.identityMismatch] && mismatch.items.isEmpty && mismatch.successfulSources == 0)
            }
        }
        if fixed {
            let switched = try parse(login: "demo_admin", id: "U_fixture_B", selectedMode: true)
            check("selected EMU viewer mismatch discards submitted rows", switched.viewer?.account.viewerID == "U_fixture_B" && switched.issues == [.identityMismatch] && switched.items.isEmpty && switched.successfulSources == 0)
            check("organization target underscore remains invalid", (try? MonitoringTarget(organization: "fixture_user")) == nil)
            check("repository owner underscore remains invalid", (try? MonitoringTarget(repository: "fixture_user/pet")) == nil)
        }
        print("RESULT checks=\(checks) failures=\(failures) mode=\(fixed ? "fixed" : "negative-before observations")")
        exit(failures == 0 ? 0 : 1)
    }
}
