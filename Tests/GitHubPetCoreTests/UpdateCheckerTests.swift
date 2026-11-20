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
                #expect(!SemanticVersion.isOrdered(SemanticVersion(upper)!, before: SemanticVersion(lower)!), "\(upper) !< \(lower)")
            }
        }
    }

    @Test func buildNumberOnlyBreaksTies() {
        #expect(SemanticVersion.isOrdered(SemanticVersion("v0.1.0-beta.3+45")!, before: SemanticVersion("v0.1.0-beta.3+46")!))
        #expect(SemanticVersion.isOrdered(SemanticVersion("v0.1.0-beta.3+99")!, before: SemanticVersion("v0.1.0-beta.4+1")!))
        #expect(!SemanticVersion.isOrdered(SemanticVersion("0.1.0+5")!, before: SemanticVersion("0.1.0")!))
    }

    @Test func parsingAcceptsAndRejects() {
        #expect(SemanticVersion("v0.1.0-beta.3")?.description == "0.1.0-beta.3")
        for bad in ["", "v", "1.2", "1.2.3.4", "01.2.3", "1.2.3-", "1.2.3-beta..1", "1.2.3-01", "a.b.c", "1.2.3-be ta",
                    "latest", "v1.2.3-é", String(repeating: "1", count: 80)] {
            #expect(SemanticVersion(bad) == nil, "\(bad)")
        }
    }
}

@Suite struct UpdateCheckerTests {
    private let beta3 = UpdateFixture.installedBuild

    private func run(_ fixture: UpdateFixture, channel: UpdateChannel, installed: InstalledBuild? = nil) async -> Result<UpdateCheckResult, UpdateCheckError> {
        await UpdateChecker(transport: fixture.transport).check(installed: installed ?? beta3, channel: channel)
    }

    private func available(_ result: Result<UpdateCheckResult, UpdateCheckError>) -> AvailableUpdate? {
        guard case .success(.available(let update)) = result else { Issue.record("expected an update, got \(result)"); return nil }
        return update
    }

    @Test func noUpdate() async {
        let result = await run(.noUpdate, channel: .beta)
        #expect(result == .success(.upToDate))
    }

    @Test func betaUpdateAvailableWithNotesDateAndLink() async {
        guard let update = available(await run(.betaAvailable, channel: .beta)) else { return }
        #expect(update.version.description == "0.1.0-beta.4")
        #expect(update.isPrerelease)
        #expect(update.url.absoluteString == "https://github.com/christopherrbrown3/github-pet/releases/tag/v0.1.0-beta.4")
        #expect(update.notes == "- Fixture: a newer beta.\n- Another change.")
        #expect(nil != update.publishedAt)
    }

    @Test func stableChannelNeverOffersABeta() async {
        let result = await run(.betaAvailable, channel: .stable)
        #expect(result == .success(.upToDate))
    }

    @Test func stableReleaseBeatsBetaOnEitherChannel() async {
        for channel in UpdateChannel.allCases {
            #expect(available(await run(.stableAvailable, channel: channel))?.version.description == "0.1.0")
        }
    }

    @Test func draftsAreIgnored() async {
        let result = await run(.draftsOnly, channel: .beta)
        #expect(result == .success(.upToDate))
    }

    @Test func untrustedMetadataIsAnErrorNotUpToDate() async {
        // A link off github.com or a tag that isn't a version must never read as "up to date".
        #expect(await run(.untrustedMetadata, channel: .beta) == .failure(.malformed))
    }

    @Test func malformedJSON() async {
        #expect(await run(.malformed, channel: .beta) == .failure(.malformed))
    }

    @Test func offline() async {
        #expect(await run(.offline, channel: .beta) == .failure(.offline))
    }

    @Test func rateLimitVariantsCarryResetTime() async {
        let reset = Date(timeIntervalSince1970: TimeInterval(UpdateFixture.resetEpoch))
        #expect(await run(.rateLimited403, channel: .beta) == .failure(.rateLimited(resetAt: reset)))
        #expect(await run(.rateLimited429, channel: .beta) == .failure(.rateLimited(resetAt: reset)))
    }

    @Test func plain403And500AreHTTPErrors() async {
        #expect(await run(.forbidden403, channel: .beta) == .failure(.httpStatus(403)))
        #expect(await run(.serverError500, channel: .beta) == .failure(.httpStatus(500)))
    }

    @Test func emptyReleaseListIsUpToDate() throws {
        #expect(try UpdateChecker.evaluate(Data("[]".utf8), installed: beta3, channel: .beta) == .upToDate)
    }

    @Test func prereleaseFlagMustMatchTag() throws {
        let json = #"[{"tag_name":"v0.2.0","draft":false,"prerelease":true,"html_url":"https://github.com/christopherrbrown3/github-pet/releases/tag/v0.2.0","published_at":null,"body":null,"target_commitish":"main"}]"#
        #expect(throws: (any Error).self) { try UpdateChecker.evaluate(Data(json.utf8), installed: beta3, channel: .beta) }
    }

    @Test func rejectsLookalikeReleaseLinks() throws {
        for url in ["https://github.com/other/repo/releases/tag/v0.2.0", "https://github.com.evil.example/christopherrbrown3/github-pet/releases/tag/v0.2.0",
                    "http://github.com/christopherrbrown3/github-pet/releases/tag/v0.2.0"] {
            let json = #"[{"tag_name":"v0.2.0","draft":false,"prerelease":false,"html_url":"\#(url)","published_at":null,"body":null,"target_commitish":"main"}]"#
            #expect(throws: (any Error).self) { try UpdateChecker.evaluate(Data(json.utf8), installed: beta3, channel: .beta) }
        }
    }

    @Test func untaggedBuildIsOfferedTheMatchingBetaUnlessItIsThatRelease() async {
        let untagged = InstalledBuild(shortVersion: "0.1.0", buildNumber: "214")
        guard let update = available(await run(.noUpdate, channel: .beta, installed: untagged)) else { return }
        #expect(update.version.description == "0.1.0-beta.3")
        // A non-hex revision in the plist is ignored.
        #expect(InstalledBuild(infoDictionary: ["GitHubPetSourceRevision": "main"]).revision == nil)
    }

    @Test func revisionMatchMakesUntaggedBuildCurrent() throws {
        let sha = "96b70d05e268dcd6db9c8768c217803b84d0fdc6"
        let json = #"[{"tag_name":"v0.1.0-beta.3","draft":false,"prerelease":true,"html_url":"https://github.com/christopherrbrown3/github-pet/releases/tag/v0.1.0-beta.3","published_at":null,"body":null,"target_commitish":"\#(sha)"}]"#
        let build = InstalledBuild(shortVersion: "0.1.0", buildNumber: "214", revision: sha)
        #expect(try UpdateChecker.evaluate(Data(json.utf8), installed: build, channel: .beta) == .upToDate)
    }

    @Test func stableIsTheDefaultChannelForEveryBuild() async {
        #expect(UpdateChannel.default == .stable)
        // A beta build on the default channel is not told about betas: that needs an explicit opt-in.
        #expect(await run(.betaAvailable, channel: UpdateChannel.default) == .success(.upToDate))
        #expect(InstalledBuild(shortVersion: "0.1.0", buildNumber: "1", releaseVersion: SemanticVersion("0.1.0-beta.3")).mayBePrerelease)
        #expect(InstalledBuild(shortVersion: "0.1.0", buildNumber: "1").mayBePrerelease)
        #expect(!InstalledBuild(shortVersion: "0.1.0", buildNumber: "1", releaseVersion: SemanticVersion("0.1.0")).mayBePrerelease)
    }

    @Test func updateCheckingIsBehindAProtocol() async {
        let checker: any UpdateChecking = UpdateChecker(transport: UpdateFixture.noUpdate.transport)
        #expect(await checker.check(installed: beta3, channel: .beta) == .success(.upToDate))
    }

    @Test func notesAreShortenedAndStrippedOfHeadings() {
        let long = "## Heading\\n" + String(repeating: "word ", count: 300)
        let notes = UpdateChecker.shortNotes(long.replacingOccurrences(of: "\\n", with: "\n"))
        #expect(notes.count <= UpdateChecker.notesLimit + 1)
        #expect(!notes.contains("Heading"))
    }

    @Test func endpointUsesReleaseListNotLatest() {
        #expect(UpdateChecker.endpoint.path.hasSuffix("/releases"))
        #expect(UpdateChecker.hostAllowed(UpdateChecker.endpoint))
        #expect(!UpdateChecker.hostAllowed(URL(string: "https://api.github.com.evil.example/x")))
        #expect(!UpdateChecker.hostAllowed(URL(string: "http://api.github.com/x")))
    }

    @Test func preferencesDailyGate() {
        let defaults = EphemeralDefaults.named("dev.github-pet.tests.update-\(UUID().uuidString)")
        let prefs = UpdatePreferences(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(prefs.isDue(now: now))
        prefs.lastCheck = now.addingTimeInterval(-3600)
        #expect(!prefs.isDue(now: now))
        prefs.lastCheck = now.addingTimeInterval(-25 * 3600)
        #expect(prefs.isDue(now: now))
        prefs.autoCheck = false
        #expect(!prefs.isDue(now: now))
        #expect(nil == prefs.channel)
    }
}
