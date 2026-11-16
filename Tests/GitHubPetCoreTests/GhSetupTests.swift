import Foundation
import Testing
@testable import GitHubPetCore

@Suite struct GhSetupTests {
    @Test func urlsAreTheHardcodedCLISiteConstants() {
        #expect(GhSetup.installURL.absoluteString == "https://cli.github.com/")
        #expect(GhSetup.signInURL.absoluteString == "https://cli.github.com/manual/gh_auth_login")
        for link in GhSetupLink.allCases { #expect(GhSetup.isAllowed(link.url)) }
    }

    @Test func onlyPlainHTTPSOnTheCLIHostIsAllowed() {
        for bad in ["http://cli.github.com/", "https://github.com/", "https://cli.github.com.evil.example/",
                    "https://evil.example/cli.github.com", "https://user@cli.github.com/",
                    "https://cli.github.com:8443/", "file:///etc/passwd", "javascript:alert(1)"] {
            #expect(!GhSetup.isAllowed(URL(string: bad)!), "\(bad)")
        }
    }

    @Test func linksExistOnlyForTheTwoSetupStates() {
        #expect(GhSetup.links(for: .ghMissing) == [.getCLI])
        #expect(GhSetup.links(for: .unauthenticated) == [.signIn])
        let others: [DataState] = [.loading, .ready, .empty, .partial, .stale, .error("boom")]
        for state in others { #expect(GhSetup.links(for: state).isEmpty, "\(state)") }
    }

    @Test func copyCommandOnlyWhenSignedOut() {
        #expect(GhSetup.copyableCommand(for: .unauthenticated) == "gh auth login")
        #expect(GhSetup.copyableCommand(for: .ghMissing) == nil)
        #expect(GhSetup.copyableCommand(for: .ready) == nil)
    }

    @Test func titlesAndHintsAreAccessibleText() {
        #expect(GhSetupLink.getCLI.title == "Get GitHub CLI")
        #expect(GhSetupLink.signIn.title == "How to sign in")
        for link in GhSetupLink.allCases { #expect(!link.accessibilityHint.isEmpty) }
    }

    @Test func existingMessagesAreKept() {
        #expect(DataState.ghMissing.hint == "Install it with: brew install gh")
        #expect(DataState.unauthenticated.hint == "Run: gh auth login")
    }
}
