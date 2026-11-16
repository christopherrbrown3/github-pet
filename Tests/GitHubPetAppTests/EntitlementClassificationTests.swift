import Foundation
import Testing
@testable import GitHubPetCore
@testable import GitHubPet

private final class FrozenClock: @unchecked Sendable {
    private let instant = ContinuousClock.now
    func now() -> ContinuousClock.Instant { instant }
}

/// #8 through the real AppModel in the offline simulated launch (throwaway in-memory settings).
@Suite(.serialized) @MainActor struct EntitlementClassificationTests {
    private func model() -> AppModel {
        var options = LaunchOptions.parse(arguments: ["GitHubPet", "--simulate-monitoring-scope", "--placeholder"], environment: [:])
        options.forcePlaceholder = true
        let clock = FrozenClock()
        return AppModel(options: options, runtime: AppModel.Runtime(now: { Date(timeIntervalSince1970: 1_763_208_000) },
            systemReducedMotion: { true }, schedulesTimers: false,
            repositoryBudget: { CommandBudget(timeout: 20, now: { clock.now() }) }, scopeSimulationHoldLimit: nil))
    }
    private func settled(_ app: AppModel) async throws {
        await app.repositoryPollSettled()
        try #require(!app.repositoryFetchInFlight)
    }

    @Test func listedRepositoriesShowReviewRequestsAsEntitlementsWithoutNewEvents() async throws {
        let app = model(); defer { app.cleanupScopeSimulation() }
        try await settled(app)
        let before = app.items
        let review = try #require(before.first { $0.kind == .reviewRequest && $0.repository == "demo-a/pet" })
        let unseen = app.unseenCount, badge = app.badge
        #expect(app.addEntitlementRepository("Demo-A/Pet") == nil)
        let shown = try #require(app.items.first { $0.id == review.id })
        #expect(shown.kind == .entitlement && shown.url == review.url, "same row and link, entitlement wording")
        #expect(app.items.map(\.id) == before.map(\.id) && app.unseenCount == unseen && app.badge == badge,
                "reclassifying never makes rows new")
        #expect(app.items.filter { $0.repository != "demo-a/pet" }.allSatisfy { $0.kind != .entitlement })
        #expect(app.addEntitlementRepository("demo-a/pet") == .duplicate)
        #expect(app.addEntitlementRepository("demo-a") == .invalid)

        // A genuinely new review request from a listed repository alerts once, as an entitlement.
        #expect(app.addEntitlementRepository("demo-a/new-pet") == nil)
        app.simulateScopeInject(); try await settled(app)
        let injected = try #require(app.items.first { $0.repository == "demo-a/new-pet" })
        #expect(injected.kind == .entitlement && app.unseenCount == unseen + 1)

        app.removeEntitlementRepository("demo-a/pet")
        #expect(app.items.first { $0.id == review.id }?.kind == .reviewRequest)
        #expect(app.settings.entitlementRepositories == ["demo-a/new-pet"])
    }
}
