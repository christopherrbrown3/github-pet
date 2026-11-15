import Foundation
import GitHubPetCore

@main struct LegacyExitQA {
    static func main() throws {
        let dir = URL(fileURLWithPath: CommandLine.arguments[1])
        let payload = #"{"data":{"viewer":{"id":"U_fixture","login":"fixture-user"},"reviews":{"issueCount":0,"nodes":[]},"assigned":{"issueCount":0,"nodes":[]},"reviews0":{"issueCount":0,"nodes":[],"pageInfo":{"hasNextPage":false}},"assigned0":{"issueCount":0,"nodes":[],"pageInfo":{"hasNextPage":false}}}}"#
        let script = dir.appendingPathComponent("gh")
        try "#!/bin/sh\nif [ \"$1\" = auth ]; then exit 0; fi\nprintf '%s' '\(payload)'\nprintf '%s\\n' 'fixture transport failure' >&2\nexit 7\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let locator = GhLocator(environment: [GhLocator.overrideVariable: script.path])
        let raw = try ProcessCommandRunner().run(executable: script, arguments: ["api"], timeout: 3)
        print("RAW exit=\(raw.exitCode) complete=\(raw.outputComplete) stderr=\(raw.stderrText.debugDescription)")
        let legacy = GhClient(locator: locator, timeout: 3).fetchWithAccount()
        let scoped = ScopedGhClient(locator: locator, timeout: 3).fetch()
        print("LEGACY account=\(legacy.account ?? "nil") outcome=\(legacy.outcome)")
        print("SCOPED complete=\(scoped.complete) issues=\(scoped.issues) outcome=\(scoped.outcome)")
        if case .snapshot(let items, let complete) = legacy.outcome {
            print("OBSERVED legacy rows=\(items.count) complete=\(complete)")
        }
    }
}
