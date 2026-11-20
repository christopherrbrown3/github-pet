import Foundation
import Testing
@testable import GitHubPetCore

@Suite struct SemanticVersionTests {
    @Test func precedenceTable() {
        let ordered = ["0.1.0-alpha", "0.1.0-alpha.1", "0.1.0-alpha.beta", "0.1.0-beta", "0.1.0-beta.2", "0.1.0-beta.3",
                       "0.1.0-beta.10", "0.1.0-rc.1", "0.1.0", "0.1.1", "0.2.0", "1.0.0"]
        for (index, lower) in ordered.enumerated() {
            for upper in ordered[(index + 1)...] {
                #expect(SemanticVersion.isOrdered(SemanticVersion(lower)!, before: SemanticVersion(upper)!), "\(lower) < \(upper)" as Comment)
                #expect(!SemanticVersion.isOrdered(SemanticVersion(upper)!, before: SemanticVersion(lower)!), "\(upper) !< \(lower)" as Comment)
            }
        }
    }

    @Test func parsingAcceptsAndRejects() {
        #expect(SemanticVersion("v0.1.0-beta.3")?.description == "0.1.0-beta.3")
        for bad in ["", "v", "1.2", "1.2.3.4", "01.2.3", "1.2.3-", "1.2.3-beta..1", "1.2.3-01", "a.b.c", "1.2.3-be ta", "latest"] {
            #expect(SemanticVersion(bad) == nil, "\(bad)" as Comment)
        }
    }
}

@Suite struct UpdatePolicyTests {
    private func installed(_ release: String?) -> InstalledBuild {
        InstalledBuild(infoDictionary: ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "214",
                                        "GitHubPetReleaseVersion": release as Any])
    }

    @Test func stableUsersAreNeverMovedToBeta() {
        #expect(UpdateChannelPolicy.allowedChannels(installed: installed("0.1.0"), optedInToBeta: false).isEmpty)
        // A build that doesn't record its tag is treated as stable too.
        #expect(UpdateChannelPolicy.allowedChannels(installed: installed(nil), optedInToBeta: false).isEmpty)
    }

    @Test func betaNeedsAPrereleaseBuildOrAnExplicitOptIn() {
        #expect(UpdateChannelPolicy.allowedChannels(installed: installed("0.1.0"), optedInToBeta: true) == ["beta"])
        #expect(UpdateChannelPolicy.allowedChannels(installed: installed("0.1.0-beta.4"), optedInToBeta: false) == ["beta"])
        #expect(installed("0.1.0-beta.4").isPrerelease)
        #expect(!installed("0.1.0").isPrerelease)
    }

    @Test func installedBuildDisplay() {
        #expect(installed("0.1.0-beta.4").displayVersion == "0.1.0-beta.4 (build 214)")
        #expect(installed(nil).displayVersion == "0.1.0 (build 214)")
        #expect(InstalledBuild(infoDictionary: nil).displayVersion == "0.0.0 (build ?)")
    }

    private let key = Data(repeating: 7, count: 32).base64EncodedString()
    private let feed = "https://raw.githubusercontent.com/christopherrbrown3/github-pet/main/updates/appcast.xml"

    @Test func configuredNeedsFeedAndValidKey() {
        #expect(UpdateConfiguration(infoDictionary: ["SUFeedURL": feed, "SUPublicEDKey": key]).state == .configured)
    }

    @Test func missingOrInvalidKeyIsNotConfigured() {
        for info in [["SUFeedURL": feed], ["SUFeedURL": feed, "SUPublicEDKey": ""], ["SUFeedURL": feed, "SUPublicEDKey": "not base64!"],
                     ["SUFeedURL": feed, "SUPublicEDKey": Data(repeating: 1, count: 16).base64EncodedString()]] {
            guard case .notConfigured = UpdateConfiguration(infoDictionary: info).state else {
                Issue.record("expected not configured for \(info)"); continue
            }
        }
    }

    @Test func missingOrOddFeedIsNotConfigured() {
        for info in [["SUPublicEDKey": key], ["SUFeedURL": "ftp://example.com/a.xml", "SUPublicEDKey": key], ["SUFeedURL": "", "SUPublicEDKey": key]] {
            #expect(!UpdateConfiguration(infoDictionary: info).state.isConfigured)
        }
        #expect(!UpdateConfiguration(infoDictionary: nil).state.isConfigured)
    }

    @Test func automaticInstallIsOffUnlessTheBuildAllowsIt() {
        #expect(!UpdateConfiguration(infoDictionary: ["SUFeedURL": feed]).allowsAutomaticInstall)
        #expect(UpdateConfiguration(infoDictionary: ["SUAllowsAutomaticUpdates": true]).allowsAutomaticInstall)
    }

    @Test func betaOptInIsOffByDefaultAndSticks() {
        let defaults = EphemeralDefaults.named("dev.github-pet.tests.update-\(UUID().uuidString)")
        let prefs = UpdatePreferences(defaults: defaults)
        #expect(!prefs.betaOptIn)
        prefs.betaOptIn = true
        #expect(UpdatePreferences(defaults: defaults).betaOptIn)
    }
}
