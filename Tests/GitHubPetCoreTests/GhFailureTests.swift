import Foundation
import Testing
@testable import GitHubPetCore

/// #7: one classification of why a gh call failed. Each state, then the callers that use it.
@Suite struct GhFailureTests {
    private func result(_ code: Int32, _ stderr: String = "") -> CommandResult {
        CommandResult(exitCode: code, stderr: Data(stderr.utf8))
    }

    @Test func signedOutFromGhExitAndWording() {
        #expect(GhFailure.isSignedOut(result(4)))
        for text in ["You are not logged in to any hosts", "To get started with GitHub CLI, please run:  gh auth login",
                     "authentication required", "HTTP 401: Bad credentials", "Bad credentials"] {
            #expect(GhFailure.isSignedOut(result(1, text)), "\(text)")
        }
        #expect(!GhFailure.isSignedOut(result(1, "HTTP 403: Resource not accessible")))
        #expect(!GhFailure.isSignedOut(result(0)))
        // The narrower gh-only form excludes GitHub's own 401 wording.
        #expect(GhFailure.isAuthFailure(result(4)) && !GhFailure.isAuthFailure(result(1, "HTTP 401")))
    }

    @Test func rateLimitIsDistinctFromDenial() {
        #expect(GhFailure.isRateLimited("API rate limit exceeded for user"))
        #expect(!GhFailure.isRateLimited("HTTP 403: Resource protected by organization SAML enforcement"))
    }

    @Test func scopeSamlAndForbiddenAreDenials() {
        for text in ["HTTP 403: Forbidden", "Resource protected by organization SAML enforcement",
                     "required scopes are missing", "INSUFFICIENT_SCOPES", "SAML single sign-on required",
                     "Your token has not been granted the required scopes"] {
            #expect(GhFailure.deniesAccess(text), "\(text)")
        }
        #expect(!GhFailure.deniesAccess("Could not resolve host: api.github.com for saml-team"))
        #expect(!GhFailure.deniesAccess("HTTP 500"))
    }

    @Test func preflightClassificationCoversEveryState() {
        #expect(GhFailure.classifyPreflight(result(1, "API rate limit exceeded; HTTP 403")) == .rateLimited)
        #expect(GhFailure.classifyPreflight(result(1, "HTTP 403: SAML enforcement")) == .accessDenied)
        #expect(GhFailure.classifyPreflight(result(1, "dial tcp: connection refused")) == .transport)
        #expect(GhFailure.classifyPreflight(result(1, "You are not logged in")) == .signedOut)
        #expect(GhFailure.classifyPreflight(result(4)) == .signedOut)
        #expect(GhFailure.classifyPreflight(result(2, "boom")) == .transport)
    }

    @Test func missingCLIIsReportedByEveryCallerWithoutRunningGh() throws {
        let locator = GhLocator(environment: ["PATH": "/nonexistent"], isExecutable: { _ in false })
        let account = try ScopeAccount(viewerID: "u1")
        let scope = try MonitoringScope(selected: [try MonitoringTarget(repository: "octo/repo")])
        let repositories = [try MonitoringTarget(repository: "octo/repo")]
        #expect(GhClient(locator: locator).authState() == .missing)
        #expect(GhClient(locator: locator).fetchWithAccount().outcome == .failure(.ghMissing))
        #expect(ScopedGhClient(locator: locator).fetch(scope: scope, expectedAccount: account) == .failure(.ghMissing))
        #expect(ActionsGhClient(locator: locator).fetch(repositories: repositories, expectedAccount: account,
                                                       budget: CommandBudget(timeout: 1)) == .failure(.ghMissing))
        #expect(DeploymentGhClient(locator: locator).fetch(repositories: repositories, expectedAccount: account,
                                                           budget: CommandBudget(timeout: 1)) == .failure(.ghMissing))
        #expect(ScopeGhAccess(locator: locator).validate(scope: scope, expectedAccount: account,
                                                        budget: CommandBudget(timeout: 1)) == .failed(.ghMissing))
        #expect(ScopeGhAccess(locator: locator).discover(expectedAccount: account,
                                                        budget: CommandBudget(timeout: 1)) == .failed(.ghMissing))
    }

    @Test func scopeAccessTransportUsesTheSameClassification() {
        #expect(ScopeGraphQL.transportFailure(result(4)) == .signedOut)
        #expect(ScopeGraphQL.transportFailure(result(1, "HTTP 401")) == .signedOut)
        #expect(ScopeGraphQL.transportFailure(result(1, "rate limit exceeded")) == .rateLimited)
        #expect(ScopeGraphQL.transportFailure(CommandResult(exitCode: 0, outputComplete: false)) == .incompleteOutput)
        #expect(ScopeGraphQL.transportFailure(result(0)) == nil)
    }
}
