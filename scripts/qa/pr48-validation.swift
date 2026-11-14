import Foundation
import GitHubPetCore

@main struct ValidationQA {
    static func main() throws {
        print("OS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        let separators = ["\n", "\r", "\r\n", "\u{85}", "\u{2028}", "\u{2029}"]
        var failures = 0, cases = 0
        for separator in separators {
            // These call the actual compiled 940231d declarations, not a stand-alone regex.
            let embeddedRepository = "example" + separator + "/pet"
            let id = "U_fixture_A" + separator
            let rejectedRepository = (try? MonitoringTarget(repository: embeddedRepository)) == nil
            let rejectedID = (try? ScopeAccount(viewerID: id)) == nil
            print("\(rejectedRepository && rejectedID ? "PASS" : "FAIL") separator=\(separator.debugDescription) embedded-owner-rejected=\(rejectedRepository) node-ID-rejected=\(rejectedID)")
            cases += 2
            if !rejectedRepository { failures += 1 }
            if !rejectedID { failures += 1 }
            // Trailing user input whitespace normalization is intentional, unlike raw node IDs.
            let normalized = try MonitoringTarget(organization: " Example" + separator)
            if normalized.owner != "example" { failures += 1 }
        }
        print("RESULT raw rejection cases=\(cases) failures=\(failures); no newline defect reproduced on this target")
        exit(failures == 0 ? 0 : 1)
    }
}
