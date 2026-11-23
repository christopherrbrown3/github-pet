import Foundation
import Testing
@testable import GitHubPetCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func item(_ id: String, _ kind: ItemKind, minutesAgo: Double = 0, attention: String? = nil,
                  demo: Bool = false) -> InboxItem {
    InboxItem(id: id, kind: kind, repository: "example/repo", title: "Title \(id)",
              url: URL(string: "https://github.com/example/repo/pull/1"),
              updatedAt: t0.addingTimeInterval(-minutesAgo * 60), isDemo: demo, attention: attention)
}

private func incident(_ id: String, _ impact: IncidentImpact) -> ServiceIncident {
    ServiceIncident(id: id, name: "Incident \(id)", status: .investigating, impact: impact, updatedAt: t0)
}

private func overview(_ state: DataState, items: [InboxItem] = [], authored: Int = 0, deployments: Int = 0,
                      deploymentsComplete: Bool = true, service: ServiceStatusState = .operational,
                      incidents: [ServiceIncident] = [], allDismissed: Bool = false) -> InboxOverview {
    InboxOverview(dataState: state, items: items, allDismissed: allDismissed, authoredWaiting: authored,
                  deploymentsWaiting: deployments, deploymentsComplete: deploymentsComplete,
                  serviceState: service, incidents: incidents)
}

private let allStates: [DataState] = [.loading, .ready, .empty, .hiddenOnly(2), .partial, .stale, .ghMissing,
                                      .unauthenticated, .error("boom")]

@Suite struct InboxGroupingTests {
    @Test func everyKindHasOneGroupAndSymbol() {
        for kind in ItemKind.allCases {
            _ = InboxGroup(kind: kind)
            #expect(!kind.symbolName.isEmpty)
        }
        #expect(InboxGroup(kind: .ciFailure) == .failingWorkflows)
        #expect(InboxGroup(kind: .workflowFailure) == .failingWorkflows)
        #expect(InboxGroup(kind: .deploymentApproval) == .approvals)
        #expect(InboxGroup(kind: .entitlement) == .approvals)
        #expect(InboxGroup(kind: .reviewRequest) == .reviewRequests)
        #expect(InboxGroup(kind: .authoredPullRequest) == .yourPullRequests)
        #expect(InboxGroup(kind: .assignedIssue) == .assignedIssues)
        #expect(InboxGroup(kind: .serviceIncident) == .incidents)
    }

    @Test func sectionsFollowGroupOrderAndKeepItemOrder() {
        let items = [item("r1", .reviewRequest, minutesAgo: 1), item("a1", .assignedIssue, minutesAgo: 2),
                     item("f1", .workflowFailure, minutesAgo: 3), item("r2", .reviewRequest, minutesAgo: 4),
                     item("e1", .entitlement, minutesAgo: 5), item("p1", .authoredPullRequest, minutesAgo: 6),
                     item("c1", .ciFailure, minutesAgo: 7)]
        let sections = InboxPresentation.sections(items)
        #expect(sections.map(\.group) == [.failingWorkflows, .approvals, .reviewRequests, .yourPullRequests, .assignedIssues])
        #expect(sections[0].items.map(\.id) == ["f1", "c1"])
        #expect(sections[2].items.map(\.id) == ["r1", "r2"])
        // Grouping never adds, drops or duplicates a row.
        #expect(sections.flatMap(\.items).count == items.count)
        #expect(Set(sections.flatMap(\.items).map(\.id)) == Set(items.map(\.id)))
    }

    @Test func noItemsNoSections() {
        #expect(InboxPresentation.sections([]).isEmpty)
    }

    @Test func contextHidesRepositoryInPrivacyMode() {
        let row = item("r", .reviewRequest, attention: "Changes requested", demo: true)
        #expect(InboxPresentation.context(row, privacy: false) == "Demo · Changes requested · example/repo")
        #expect(InboxPresentation.context(row, privacy: true) == "Demo · Changes requested")
        // Never an empty secondary line: the generic kind label stands in.
        #expect(InboxPresentation.context(item("x", .assignedIssue), privacy: true) == "Assigned issue")
        #expect(InboxPresentation.context(item("x", .assignedIssue, demo: true), privacy: true) == "Demo · Assigned issue")
    }
}

@Suite struct SourceHealthTests {
    @Test func dataStatesMapToDistinctHealth() {
        #expect(SourceHealth(DataState.ready) == .healthy)
        #expect(SourceHealth(DataState.empty) == .healthy)
        #expect(SourceHealth(DataState.hiddenOnly(1)) == .healthy)
        #expect(SourceHealth(DataState.loading) == .loading)
        #expect(SourceHealth(DataState.ghMissing) == .unknown)
        #expect(SourceHealth(DataState.unauthenticated) == .unknown)
        #expect(SourceHealth(DataState.stale) == .stale)
        #expect(SourceHealth(DataState.partial) == .partial)
        #expect(SourceHealth(DataState.error("x")) == .error)
        let labels = [SourceHealth.healthy, .loading, .unknown, .stale, .partial, .error].map(\.label)
        #expect(Set(labels).count == 6)
    }

    @Test func serviceStatesMapToHealth() {
        #expect(SourceHealth(ServiceStatusState.operational) == .healthy)
        #expect(SourceHealth(ServiceStatusState.incidents) == .healthy)
        #expect(SourceHealth(ServiceStatusState.loading) == .loading)
        #expect(SourceHealth(ServiceStatusState.stale) == .stale)
        #expect(SourceHealth(ServiceStatusState.error("x")) == .error)
    }
}

@Suite struct InboxOverviewTests {
    @Test func assignedTileUsesTheBadgeCountNeverASecondCount() {
        let items = [item("r1", .reviewRequest), item("r2", .reviewRequest), item("a1", .assignedIssue)]
        for state in allStates {
            let tile = overview(state, items: items).assigned
            #expect(tile.value == (MascotPolicy.badge(dataState: state, count: items.count) ?? "0"))
        }
        let ready = overview(.ready, items: items).assigned
        #expect(ready.value == "3" && ready.detail == "2 reviews · 1 issue" && ready.tone == .neutral)
    }

    @Test func assignedIssuesAreNotTonedUrgent() {
        let tile = overview(.ready, items: [item("a1", .assignedIssue), item("c1", .ciFailure)]).assigned
        #expect(tile.tone == .neutral)
    }

    @Test func breakdownSummarisesAtMostTwoGroups() {
        let items = [item("c", .ciFailure), item("e", .entitlement), item("r", .reviewRequest)]
        #expect(overview(.ready, items: items).assigned.detail == "1 failing workflow · 1 approval · more")
    }

    @Test func degradedAssignedTileNeverReadsAsNothingNeedsYou() {
        for state in allStates where state != .empty && state != .ready {
            let tile = overview(state).assigned
            #expect(tile.detail != "Nothing needs you", "\(state)")
        }
        #expect(overview(.empty).assigned.detail == "Nothing needs you")
        #expect(overview(.empty).assigned.value == "0")
        #expect(overview(.stale).assigned.value == "?" && overview(.stale).assigned.tone == .caution)
        #expect(overview(.partial).assigned.value == "0+" && overview(.partial).assigned.tone == .caution)
        #expect(overview(.loading).assigned.value == "?" && overview(.loading).assigned.tone == .neutral)
        #expect(overview(.error("x")).assigned.tone == .critical)
        #expect(overview(.ghMissing).assigned.detail == "GitHub CLI needs setup")
        #expect(overview(.hiddenOnly(3)).assigned.detail == "Hidden from your account")
        #expect(overview(.ready, allDismissed: true).assigned.detail == "All dismissed locally")
    }

    @Test func waitingTileAddsAuthoredAndDeployments() {
        let tile = overview(.ready, authored: 2, deployments: 1).waiting
        #expect(tile.value == "3" && tile.detail == "2 pull requests · 1 deployment" && tile.tone == .neutral)
        #expect(overview(.empty).waiting.value == "0" && overview(.empty).waiting.detail == "Nothing waiting")
    }

    @Test func waitingTileIsALowerBoundWhenIncomplete() {
        #expect(overview(.partial, authored: 1).waiting.value == "1+")
        #expect(overview(.partial, authored: 1).waiting.detail == "At least 1 pull request")
        let incomplete = overview(.ready, deployments: 0, deploymentsComplete: false).waiting
        #expect(incomplete.value == "0+" && incomplete.detail == "Some sources unavailable" && incomplete.tone == .caution)
    }

    @Test func waitingTileIsUnknownWithoutUsableData() {
        for state in [DataState.loading, .ghMissing, .unauthenticated, .error("x")] {
            #expect(overview(state, authored: 4).waiting.value == "?")
        }
        // Stale: unknown like the Assigned tile and the badge; the last known count is labelled.
        let stale = overview(.stale, authored: 2, deployments: 1).waiting
        #expect(stale.value == "?" && stale.detail == "Last known: 2 pull requests · 1 deployment" && stale.tone == .caution)
        #expect(overview(.stale).waiting.value == "?" && overview(.stale).waiting.detail == "Last known, out of date")
    }

    /// #148: the Waiting on others group's count is the tile's value; a complete, healthy count is
    /// exactly its rows, and degraded data never reads as nothing waiting.
    @Test func waitingGroupFollowsTheTileAndIsHonestAboutQuality() {
        let rows = [item("a", .authoredPullRequest), item("b", .authoredPullRequest), item("d", .deploymentApproval)]
        let ready = InboxWaitingGroup(dataState: .ready, items: rows, deploymentsComplete: true)
        let tile = overview(.ready, authored: 2, deployments: 1).waiting
        #expect(ready.count == tile.value && ready.count == "\(rows.count)" && ready.isShown && ready.note == nil && !ready.lastKnown)
        #expect(ready.accessibilityLabel == "Waiting on others, 3 items" && ready.countLabel == "3 items")
        #expect(InboxWaitingGroup(dataState: .partial, items: rows, deploymentsComplete: true).countLabel == "3+ items")
        let none = InboxWaitingGroup(dataState: .empty, items: [], deploymentsComplete: true)
        #expect(!none.isShown && none.count == "0", "verified nothing waiting: the tile says so, no empty group")
        let partial = InboxWaitingGroup(dataState: .partial, items: Array(rows.prefix(1)), deploymentsComplete: true)
        #expect(partial.isShown && partial.count == "1+" && partial.count == overview(.partial, authored: 1).waiting.value)
        #expect(partial.note == "Some sources didn't load, so there may be more." && partial.spokenCount == "at least 1 item")
        let deployments = InboxWaitingGroup(dataState: .ready, items: [], deploymentsComplete: false)
        #expect(deployments.isShown && deployments.count == "0+" && deployments.note != nil, "incomplete deployments: never nothing waiting")
        let stale = InboxWaitingGroup(dataState: .stale, items: rows, deploymentsComplete: true)
        #expect(stale.isShown && stale.lastKnown && stale.count == "?" && stale.note == "Last known, out of date.")
        #expect(stale.accessibilityLabel == "Waiting on others, count unknown, 3 last known" && stale.countLabel == "Count unknown")
        let failed = InboxWaitingGroup(dataState: .error("x"), items: [], deploymentsComplete: true)
        #expect(failed.isShown && failed.count == "?" && failed.note == "Unknown until the next successful update.")
        for state in [DataState.loading, .ghMissing, .unauthenticated] {
            #expect(!InboxWaitingGroup(dataState: state, items: rows, deploymentsComplete: true).isShown, "\(state)")
        }
        for state in allStates {
            let group = InboxWaitingGroup(dataState: state, items: [], deploymentsComplete: true)
            #expect(!(group.isShown && group.count == "0" && group.note == nil), "\(state): a shown group never claims nothing waiting")
        }
    }

    @Test func tilesAgreeOnUnknownCounts() {
        // QA #92: no tile may show a current-looking count while another says the count is unknown.
        for state in allStates where !state.countIsKnown && state != .partial {
            let tiles = overview(state, items: [item("r", .reviewRequest)], authored: 3, deployments: 2)
            #expect(tiles.assigned.value == "?" && tiles.waiting.value == "?", "\(state)")
        }
    }

    @Test func statusTileIsOperationalOnlyWhenFreshAndVerified() {
        #expect(overview(.ready, service: .operational).status.value == "Operational")
        #expect(overview(.ready, service: .operational).status.tone == .positive)
        for state in [ServiceStatusState.loading, .stale, .error("x"), .incidents] {
            let tile = overview(.ready, service: state, incidents: [incident("i", .minor)]).status
            #expect(tile.value != "Operational" && tile.tone != .positive, "\(state)")
        }
        #expect(overview(.ready, service: .stale).status.value == "Stale")
        #expect(overview(.ready, service: .error("x")).status.value == "Unavailable")
        #expect(overview(.ready, service: .loading).status.value == "Checking…")
    }

    @Test func statusTileNamesTheWorstIncident() {
        let minor = overview(.ready, service: .incidents, incidents: [incident("a", .minor)]).status
        #expect(minor.value == "1 incident" && minor.detail == "Minor impact" && minor.tone == .caution)
        let major = overview(.ready, service: .incidents, incidents: [incident("a", .minor), incident("b", .major)]).status
        #expect(major.value == "2 incidents" && major.detail == "Major impact" && major.tone == .critical)
    }

    @Test func tileAccessibilityLabelSaysEverything() {
        let tile = overview(.ready, items: [item("r", .reviewRequest)]).assigned
        #expect(tile.accessibilityLabel == "Needs you: 1, 1 review", "named like the section and the badge (#148)")
    }
}

@Suite struct InboxEmptyStateTests {
    @Test func onlyAVerifiedEmptyInboxIsAllClear() {
        for state in allStates {
            let empty = InboxEmptyState(dataState: state, allDismissed: false)
            let verified = state == .empty || state == .ready
            #expect((empty == .allClear) == verified, "\(state)")
            #expect(empty.showsMascot == verified, "\(state)")
            if !verified { #expect(empty.headline != "All caught up") }
        }
    }

    /// QA #92: the exact cases. Verified empty → All caught up; emptied by local dismissals →
    /// the dismissed message; degraded data keeps its own message even with dismissals.
    @Test func dismissedMessageOnlyForAnInboxEmptiedByDismissals() {
        #expect(InboxEmptyState(dataState: .empty, allDismissed: false) == .allClear)
        #expect(InboxEmptyState(dataState: .ready, allDismissed: false) == .allClear)
        #expect(InboxEmptyState(dataState: .ready, allDismissed: false).headline == "All caught up")
        #expect(InboxEmptyState(dataState: .ready, allDismissed: true) == .allDismissed)
        #expect(InboxEmptyState(dataState: .ready, allDismissed: true).headline == "All current Inbox items are dismissed.")
        #expect(!InboxEmptyState.allDismissed.showsMascot)
        // GitHub returned nothing: verified empty, whatever the local dismissal list holds.
        #expect(InboxEmptyState(dataState: .empty, allDismissed: true) == .allClear)
        let degraded: [(DataState, InboxEmptyState)] = [
            (.hiddenOnly(2), .hiddenOnly(2)), (.partial, .partial), (.stale, .stale), (.loading, .loading),
            (.ghMissing, .setupNeeded), (.unauthenticated, .setupNeeded), (.error("x"), .failed),
        ]
        for (state, expected) in degraded {
            #expect(InboxEmptyState(dataState: state, allDismissed: true) == expected, "\(state)")
            #expect(InboxEmptyState(dataState: state, allDismissed: false) == expected, "\(state)")
        }
    }

    @Test func assignedTileDismissedDetailOnlyWhenEmptiedByDismissals() {
        #expect(overview(.ready, allDismissed: true).assigned.detail == "All dismissed locally")
        #expect(overview(.ready, allDismissed: false).assigned.detail == "Nothing needs you")
        #expect(overview(.empty, allDismissed: true).assigned.detail == "Nothing needs you")
    }

    @Test func degradedStatesSayWhatIsUnknown() {
        #expect(InboxEmptyState(dataState: .partial, allDismissed: false).headline == "No items in the sources that loaded.")
        #expect(InboxEmptyState(dataState: .stale, allDismissed: false) == .stale)
        #expect(InboxEmptyState(dataState: .loading, allDismissed: false) == .loading)
        #expect(InboxEmptyState(dataState: .ghMissing, allDismissed: false) == .setupNeeded)
        #expect(InboxEmptyState(dataState: .error("x"), allDismissed: false) == .failed)
        #expect(InboxEmptyState(dataState: .hiddenOnly(2), allDismissed: false).detail == "2 matches hidden from your account")
        for state in [InboxEmptyState.partial, .stale, .loading, .setupNeeded, .failed, .hiddenOnly(1)] {
            #expect(state.symbolName != nil)
        }
    }

    @Test func updatedTextNeverClaimsAnUpdateThatDidNotHappen() {
        let format: (Date) -> String = { _ in "10:42" }
        #expect(InboxPresentation.updatedText(lastSuccess: nil, dataState: .loading, format: format) == "Not updated yet")
        #expect(InboxPresentation.updatedText(lastSuccess: nil, dataState: .error("x"), format: format) == "No successful update yet")
        #expect(InboxPresentation.updatedText(lastSuccess: t0, dataState: .ready, format: format) == "Updated 10:42")
        #expect(InboxPresentation.updatedText(lastSuccess: t0, dataState: .stale, format: format) == "Last updated 10:42")
        #expect(InboxPresentation.updatedText(lastSuccess: t0, dataState: .error("x"), format: format) == "Last updated 10:42")
    }
}
