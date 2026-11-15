import Foundation
import GitHubPetCore

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
        func parse(login: String?, id: String = "U_fixture_A", selectedMode: Bool) throws -> ScopedPollResult {
            let plan = try ScopeQueryPlan(scope: selectedMode ? selected : .everything, expectedAccount: selectedMode ? a : nil)
            var viewer: [String: Any] = ["id": id]
            if let login { viewer["login"] = login }
            var body: [String: Any] = ["viewer": viewer]
            if selectedMode { body["target0"] = ["__typename": "Repository", "id": "R_fixture", "nameWithOwner": "example/pet"] }
            for search in plan.searches { body[search.alias] = ["issueCount": 0, "nodes": [], "pageInfo": ["hasNextPage": false]] }
            return ScopedResponseParser.parse(try JSONSerialization.data(withJSONObject: ["data": body]), plan: plan)
        }
        for selectedMode in [false, true] {
            for login in ["fixture-user", "fixture-user_demo", "demo_admin"] {
                let result = try parse(login: login, selectedMode: selectedMode)
                print("OBSERVED selected=\(selectedMode) login=\(login) complete=\(result.complete) viewer=\(result.viewer?.login ?? "nil") issues=\(result.issues)")
                if login == "fixture-user" || fixed {
                    check("valid display login \(login) selected=\(selectedMode)", result.complete && result.viewer?.account == a && result.viewer?.login == login)
                }
            }
            if !fixed { continue }
            for bad in [Optional<String>.none, "", "bad login", "bad\nlogin", String(repeating: "a", count: 40)] {
                let result = try parse(login: bad, selectedMode: selectedMode)
                check("missing/invalid display login rejected selected=\(selectedMode) input=\(bad.debugDescription)", result.viewer == nil && !result.complete)
            }
            let badID = try parse(login: "demo_admin", id: "U_fixture_A\n", selectedMode: selectedMode)
            check("valid EMU display cannot bypass nodeID guard selected=\(selectedMode)", badID.viewer == nil && !badID.complete)
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
