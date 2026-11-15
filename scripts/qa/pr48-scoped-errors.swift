import Foundation
import GitHubPetCore

@main struct ScopedErrorsQA {
    static func main() throws {
        let plan = try ScopeQueryPlan()
        let node: [String: Any] = ["__typename": "PullRequest", "id": "PR_errors", "number": 7, "title": "Fixture", "url": "https://github.com/example/pet/pull/7", "updatedAt": "2026-11-14T00:00:00Z", "repository": ["nameWithOwner": "example/pet"]]
        func parse(rows: Bool, errors: Any? = nil) throws -> ScopedPollResult {
            var outer: [String: Any] = ["data": ["viewer": ["id": "U_fixture", "login": "fixture-user"], "reviews0": ["issueCount": rows ? 1 : 0, "nodes": rows ? [node] : [], "pageInfo": ["hasNextPage": false]], "assigned0": ["issueCount": 0, "nodes": [], "pageInfo": ["hasNextPage": false]]]]
            if let errors { outer["errors"] = errors }
            return ScopedResponseParser.parse(try JSONSerialization.data(withJSONObject: outer), plan: plan)
        }
        let fixed = CommandLine.arguments.contains("--fixed")
        var checks = 0, failures = 0
        func check(_ name: String, _ value: @autoclosure () -> Bool) {
            checks += 1
            if value() { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
        }
        for rows in [false, true] {
            let control = try parse(rows: rows)
            check("absent errors valid control rows=\(rows)", control.complete && control.items.count == (rows ? 1 : 0))
            if !fixed {
                let result = try parse(rows: rows, errors: [Any]())
                print("NEGATIVE-BEFORE errors=[] rows=\(rows) complete=\(result.complete) items=\(result.items.count) issues=\(result.issues)")
                continue
            }
            let values: [(String, Any)] = [("reported", [["message": "fixture"]]), ("string", "bad"), ("object", ["message": "bad"]), ("null", NSNull()), ("emptyarray", [Any]()), ("nullentry", [NSNull()]), ("emptyentry", [[String: Any]()]), ("boolean", false), ("number", 42)]
            for (name, errors) in values {
                let result = try parse(rows: rows, errors: errors)
                check("errors=\(name) rows=\(rows) partial with proven rows", !result.complete && result.issues.contains(.graphQLError) && result.items.count == (rows ? 1 : 0) && result.viewer != nil)
            }
            let limited = try parse(rows: rows, errors: [["type": "RATE_LIMITED"]])
            check("rate limit typed/proven rows retained rows=\(rows)", !limited.complete && limited.issues.contains(.rateLimited) && limited.items.count == (rows ? 1 : 0))
        }
        print("RESULT checks=\(checks) failures=\(failures) mode=\(fixed ? "fixed" : "negative-before evidence only")")
        exit(failures == 0 ? 0 : 1)
    }
}
