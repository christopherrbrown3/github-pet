import Foundation
import GitHubPetCore

@main struct JSONValidationQA {
    static func main() throws {
        let account = try ScopeAccount(viewerID: "U_fixture_A")
        let selected = try ScopeQueryPlan(scope: MonitoringScope(selected: [MonitoringTarget(repository: "example/pet")]), expectedAccount: account)
        let everything = try ScopeQueryPlan()
        func body(_ plan: ScopeQueryPlan, viewerID: String = "U_fixture_A", metadataID: String = "R_fixture") -> [String: Any] {
            var value: [String: Any] = ["viewer": ["id": viewerID, "login": "fixture-user"]]
            if plan.scope.mode == .selected {
                value["target0"] = ["__typename": "Repository", "id": metadataID, "nameWithOwner": "example/pet"]
            }
            for search in plan.searches { value[search.alias] = ["issueCount": 0, "nodes": [], "pageInfo": ["hasNextPage": false]] }
            return value
        }
        func parse(_ body: [String: Any], plan: ScopeQueryPlan) throws -> ScopedPollResult {
            ScopedResponseParser.parse(try JSONSerialization.data(withJSONObject: ["data": body]), plan: plan)
        }
        let baseline = try parse(body(selected), plan: selected)
        guard baseline.complete, baseline.successfulSources == 2 else { fatalError("positive fixture control is invalid") }
        print("CONTROL selected-targets=\(selected.scope.targets.count) aliases=\(selected.searches.map(\.alias)) complete=\(baseline.complete)")
        var metadataAccepted = 0, freshViewerAccepted = 0, selectedMismatches = 0
        for (label, suffix) in [("LF", "\n"), ("CR", "\r"), ("CRLF", "\r\n"), ("NEL", "\u{85}"), ("LS", "\u{2028}"), ("PS", "\u{2029}")] {
            let raw = (try? ScopeAccount(viewerID: "U_fixture_A" + suffix)) != nil
            let meta = try parse(body(selected, metadataID: "R_fixture" + suffix), plan: selected)
            let fresh = try parse(body(everything, viewerID: "U_fixture_A" + suffix), plan: everything)
            let submitted = try parse(body(selected, viewerID: "U_fixture_A" + suffix), plan: selected)
            if meta.complete { metadataAccepted += 1 }
            if fresh.complete && fresh.viewer != nil { freshViewerAccepted += 1 }
            if submitted.issues == [.identityMismatch] && submitted.items.isEmpty { selectedMismatches += 1 }
            print("\(label): raw-native-account-accepted=\(raw) JSON-metadata-complete=\(meta.complete) JSON-fresh-Everything-complete=\(fresh.complete) JSON-fresh-viewer-ID=\(fresh.viewer?.account.viewerID.debugDescription ?? "nil") JSON-selected-issues=\(submitted.issues) selected-items=\(submitted.items.count)")
        }
        for id in ["", "R_fixture!"] {
            let control = try parse(body(selected, metadataID: id), plan: selected)
            guard !control.complete, control.issues.contains(.malformedTarget(0)) else { fatalError("invalid metadata control passed") }
            print("CONTROL invalid metadata \(id.debugDescription) rejected")
        }
        print("RESULT metadata-accepted=\(metadataAccepted)/6 fresh-Everything-viewer-accepted=\(freshViewerAccepted)/6 selected-mismatch-discard=\(selectedMismatches)/6; probe execution complete, not product PASS")
    }
}
