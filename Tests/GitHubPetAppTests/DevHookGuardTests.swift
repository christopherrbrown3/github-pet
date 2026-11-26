import Foundation
import Testing
@testable import GitHubPet

/// #138: the dev-only hooks (`--replay-clips`, `--dump-incident-frames`) are dropped under the
/// production bundle ID, so the shipping app never replays clips, writes frame dumps, or swaps to
/// fixtures and an in-memory preferences domain because of them.
@Suite struct DevHookGuardTests {
    static let arguments = ["GitHubPet", "--replay-clips", "5", "--dump-incident-frames", "/tmp/github-pet-dump"]

    @Test func productionBundleIgnoresDevHooks() {
        let options = LaunchOptions.parse(arguments: Self.arguments, environment: [:],
                                          bundleIdentifier: LaunchOptions.productionBundleID)
        #expect(options.replayClipsEvery == nil)
        #expect(options.dumpIncidentFrames == nil)
        #expect(options.forcedSource == nil, "the dump's fixtures switch must not apply either")
        #expect(options.defaultsSuite == nil)
        #expect(!options.resetSettings)
    }

    @Test func otherBundlesKeepDevHooks() {
        for id in [LaunchOptions.productionBundleID + ".qa", "dev.github-pet.GitHubPetX", nil] as [String?] {
            let options = LaunchOptions.parse(arguments: Self.arguments, environment: [:], bundleIdentifier: id)
            #expect(options.replayClipsEvery == 5, "\(id ?? "nil")")
            #expect(options.dumpIncidentFrames?.path == "/tmp/github-pet-dump", "\(id ?? "nil")")
            #expect(options.forcedSource == "fixtures")
            #expect(options.defaultsSuite == LaunchOptions.dumpDefaultsSuite)
        }
    }
}
