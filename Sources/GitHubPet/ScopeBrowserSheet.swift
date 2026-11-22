import GitHubPetCore
import SwiftUI

/// Choose Repositories to Monitor (#137): a sheet on the Settings window with an owner sidebar,
/// a searchable checkbox list per owner, and Apply. It edits the same draft Settings shows; Apply
/// runs the editor's validated Apply and closes on success, Cancel restores the draft as it was
/// when the sheet opened. There is no limit on how many entries can be selected.
struct ScopeBrowserSheet: View {
    @ObservedObject var model: AppModel
    @ObservedObject var browser: ScopeBrowser
    @ObservedObject var editor: ScopeEditor
    let close: () -> Void

    @State private var snapshot: ScopeEditor.DraftSnapshot?
    @State private var addingByName: Bool
    @State private var applySequence: Int?
    /// The editor's status when the sheet opened: the footer shows only what happened since.
    @State private var statusAtOpen: String??
    @FocusState private var focus: Focus?
    private enum Focus: Hashable { case search, detail }

    /// `initialSnapshot`: what Cancel restores when the opener already changed the draft
    /// (choosing Selected in Settings); otherwise the draft as the sheet appears.
    init(model: AppModel, browser: ScopeBrowser, addByName: Bool = false, initialSnapshot: ScopeEditor.DraftSnapshot? = nil,
         close: @escaping () -> Void) {
        self.model = model; self.browser = browser; self.editor = browser.editor; self.close = close
        _addingByName = State(initialValue: addByName)
        _snapshot = State(initialValue: initialSnapshot)
    }

    static let idealSize = CGSize(width: 780, height: 540)
    private var entries: [ScopeEntry] { ScopeEntry.entries(editor) }

    var body: some View {
        VStack(spacing: 0) {
            header
            toolbar
            if let notice = browser.notice {
                ScopeBanner(tone: .info, symbol: "person.crop.circle.badge.exclamationmark", text: notice)
                    .padding(.horizontal, 12).padding(.bottom, 8)
            }
            Divider()
            HStack(spacing: 0) {
                ScopeBrowserSidebar(browser: browser, editor: editor, selectedCount: entries.count)
                    .frame(width: 230)
                Divider()
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(minWidth: 640, idealWidth: Self.idealSize.width, maxWidth: .infinity,
               minHeight: 460, idealHeight: Self.idealSize.height, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if snapshot == nil { snapshot = editor.snapshotDraft() }
            if statusAtOpen == nil { statusAtOpen = .some(editor.status) }
            browser.sync()
            focus = .search
        }
        .onChange(of: model.monitoringScopeIdentity) { _ in browser.sync() }
        .onChange(of: editor.applyEvent) { event in
            guard let event, event.sequence == applySequence else { return }
            applySequence = nil
            switch event.outcome {
            case .applied: close()
            case .rejected: browser.pane = .selected
            case .failed, .superseded: break
            }
        }
        // Esc and ⌘.: clear the search first, then Cancel.
        .onExitCommand { if browser.searchText.isEmpty { cancel() } else { browser.searchText = "" } }
        .sheet(isPresented: $addingByName) {
            AddByNameSheet(editor: editor) { addingByName = false }
        }
        .background(shortcuts)
    }

    // MARK: Header and toolbar

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text("Choose Repositories to Monitor").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Label(editor.accountDescription, systemImage: "person.crop.circle")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .accessibilityLabel("GitHub CLI account: \(editor.accountDescription)")
            }
            if model.simulatesScope {
                Text("Simulated/Demo: invented organizations, checked offline.").font(.caption).foregroundStyle(.secondary)
            } else if browser.isDemo {
                Text("Demo: invented organizations, checked offline.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Search repositories and organizations", text: $browser.searchText,
                          prompt: Text("Search repositories and organizations"))
                    .textFieldStyle(.plain)
                    .labelsHidden()
                    .focused($focus, equals: .search)
                    .onSubmit(submitSearch)
                    // A plain-style field doesn't publish its hidden title as the name.
                    .accessibilityLabel("Search repositories and organizations")
                    .accessibilityHint("Filters loaded repositories. Return searches GitHub in the current owner.")
                if !browser.searchText.isEmpty {
                    Button { browser.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                        .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.35)))
            if !browser.searchText.isEmpty, let owner = browser.currentOwner {
                Picker("Search in", selection: $browser.searchAllOwners) {
                    Text("All owners").tag(true)
                    Text(browser.displayName(owner)).tag(false)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            Menu {
                Toggle("Hide archived", isOn: $browser.hideArchived)
                Toggle("Hide forks", isOn: $browser.hideForks)
            } label: { Label("Filter", systemImage: "line.3.horizontal.decrease.circle") }
                .fixedSize()
                .accessibilityLabel("Filter: \(filterSummary)")
            Picker("Sort", selection: $browser.sort) {
                Text("Recently pushed").tag(ScopeBrowseSort.pushed)
                Text("Name").tag(ScopeBrowseSort.name)
            }
            .pickerStyle(.menu).fixedSize()
        }
        .padding(.horizontal, 12).padding(.bottom, 8)
    }

    private var filterSummary: String {
        [browser.hideArchived ? "archived hidden" : "archived shown", browser.hideForks ? "forks hidden" : "forks shown"]
            .joined(separator: ", ")
    }

    /// ⌘F focuses search; ↓ from search moves into the list. Hidden, keyboard only.
    private var shortcuts: some View {
        ZStack {
            Button("Focus search") { focus = .search }.keyboardShortcut("f", modifiers: .command)
            Button("Move to list") { focus = .detail }
                .keyboardShortcut(.downArrow, modifiers: [])
                .disabled(focus != .search)
        }
        .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }

    private func submitSearch() {
        let owner = browser.currentOwner
        if let owner, browser.canSearchServer(owner) { browser.searchServer(owner) }
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        switch browser.pane {
        case .selected:
            SelectedReview(editor: editor, entries: entries, addByName: { addingByName = true })
                .focused($focus, equals: .detail)
        case .browse:
            if let blocking = accountProblem { blocking } else { opening }
        case .owner(let id):
            if let blocking = accountProblem {
                blocking
            } else if let owner = browser.owner(id) {
                if !browser.searchText.isEmpty && browser.searchAllOwners {
                    ScopeSearchResults(browser: browser, addByName: { addingByName = true })
                        .focused($focus, equals: .detail)
                } else {
                    OwnerDetail(browser: browser, owner: owner, addByName: { addingByName = true })
                        .focused($focus, equals: .detail)
                }
            } else {
                opening
            }
        }
    }

    /// Before any owner is shown: account check, owners loading, or why owners failed.
    @ViewBuilder private var opening: some View {
        switch browser.ownersPhase {
        case .failed(let failure):
            VStack(alignment: .leading, spacing: 8) {
                ScopeBanner(tone: failure == .accessDenied ? .error : .warning,
                            symbol: failure == .accessDenied ? "lock.trianglebadge.exclamationmark" : "exclamationmark.triangle.fill",
                            text: failure.message + " Your organizations aren't listed yet; this doesn't mean there are none.",
                            actionTitle: "Retry", actionEnabled: !browser.retryBlocked) { browser.loadOwners() }
                Button("Add by Name…") { addingByName = true }
            }
            .padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        default:
            VStack(spacing: 8) {
                ProgressView().accessibilityHidden(true)
                Text(browser.ownersPhase == .checkingAccount ? "Checking your GitHub CLI account…" : "Loading your organizations…")
                    .foregroundStyle(.secondary)
                if browser.notice != nil { Button("Reload") { browser.reload() } }
            }
            .accessibilityElement(children: .contain)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// State 6 and account checks replace the owner pane; the Selected review stays reachable.
    private var accountProblem: AnyView? {
        switch browser.ownersPhase {
        case .failed(let failure) where failure == .signedOut || failure == .ghMissing:
            return AnyView(AccountProblemView(
                symbol: failure == .ghMissing ? "terminal" : "person.crop.circle.badge.xmark",
                title: failure == .ghMissing ? "Install GitHub CLI to browse" : "Sign in to GitHub CLI to browse",
                detail: failure == .ghMissing ? "GitHub Pet lists repositories through your installed gh."
                    : "Run gh auth login in Terminal, then Try Again. Your selection is kept.",
                retry: { browser.loadOwners() }, addByName: { addingByName = true }))
        default: return nil
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Text("\(entries.count) selected")
                .font(.callout.weight(.semibold).monospacedDigit())
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                .accessibilityLabel("\(entries.count) \(entries.count == 1 ? "entry" : "entries") selected")
            Button("Add by Name…") { addingByName = true }
            Spacer(minLength: 8)
            if editor.phase == .validating {
                ProgressView().controlSize(.small).accessibilityHidden(true)
                Text("Checking access…").font(.callout).foregroundStyle(.secondary)
            } else if let reason = footerMessage {
                Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.tail)
            }
            Button("Cancel", action: cancel)
                .accessibilityHint("Restores the selection from when this window opened. Nothing is applied.")
            Button("Apply") { applySequence = (editor.applyEvent?.sequence ?? 0) + 1; editor.apply() }
                .keyboardShortcut(focus == .search ? nil : .defaultAction)
                .disabled(!editor.canApply)
                .accessibilityHint((editor.canApply ? "" : editor.hasChanges ? (editor.applyBlockedReason.map { $0 + " " } ?? "")
                                    : "No changes to apply. ") + "Checks access to every entry, then starts monitoring them.")
                .accessibilityIdentifier("scopeBrowser.apply")
        }
        .padding(12)
    }

    private var footerMessage: String? {
        if editor.hasChanges, let reason = editor.applyBlockedReason { return reason }
        return editor.status == statusAtOpen.flatMap { $0 } ? nil : editor.status
    }

    private func cancel() {
        if let snapshot { editor.restoreDraft(snapshot) }
        close()
    }
}

// MARK: Sidebar

struct ScopeBrowserSidebar: View {
    @ObservedObject var browser: ScopeBrowser
    @ObservedObject var editor: ScopeEditor
    let selectedCount: Int

    var body: some View {
        List(selection: Binding<ScopeBrowser.Pane?>(
            get: { browser.pane },
            set: { pane in
                guard let pane else { return }
                if case .owner(let id) = pane, let owner = browser.owner(id) { browser.open(owner) } else { browser.pane = pane }
            })) {
            Label { Text("Selected · \(selectedCount)").monospacedDigit() } icon: { Image(systemName: "checklist") }
                .tag(ScopeBrowser.Pane.selected)
                .accessibilityLabel("Selected, \(selectedCount) \(selectedCount == 1 ? "entry" : "entries")")
            switch browser.ownersPhase {
            case .idle, .loading, .checkingAccount:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                    Text(browser.ownersPhase == .checkingAccount ? "Checking your GitHub CLI account…" : "Loading organizations…")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            case .failed(let failure):
                Label(failure.message, systemImage: failure == .accessDenied ? "lock.trianglebadge.exclamationmark" : "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(failure == .accessDenied ? .red : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            case .loaded:
                let mine = browser.owners.filter { $0.kind != .organization && browser.sidebarMatches($0) }
                if !mine.isEmpty {
                    Section("Your account") { ForEach(mine) { row($0) } }
                }
                Section("Organizations") {
                    let organizations = browser.organizations.filter(browser.sidebarMatches)
                    ForEach(organizations) { row($0) }
                    if browser.organizations.isEmpty {
                        Text("You're not a member of any organization.").font(.caption).foregroundStyle(.secondary)
                    } else if organizations.isEmpty {
                        Text("No organization matches.").font(.caption).foregroundStyle(.secondary)
                    }
                    if browser.moreOrganizations {
                        Text("First 100 organizations listed. Use Add by Name for others.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        // Not .sidebar: its vibrant selection needs window-server blending and draws black in
        // offscreen renders; a plain list keeps the same keyboard selection behaviour.
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.5))
    }

    private func row(_ owner: ScopeBrowseOwner) -> some View {
        let state = browser.state(owner)
        let selected = browser.selectedRepositoryCount(owner), all = browser.allSelected(owner)
        let denied = owner.denied || state.failure == .accessDenied
        return HStack(spacing: 6) {
            if owner.kind == .shared {
                Image(systemName: "person.2").frame(width: 20).foregroundStyle(.secondary)
            } else {
                Monogram(login: owner.login)
            }
            Text(browser.displayName(owner)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if state.loading || state.searching {
                ProgressView().controlSize(.mini)
            } else if denied {
                Image(systemName: "lock.trianglebadge.exclamationmark").foregroundStyle(.red)
            } else if all {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
            } else if selected > 0 {
                Text("\(selected)").font(.caption2.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor.opacity(0.2)))
            }
            Text(denied ? "—" : owner.repositoryCount.map { $0.formatted() } ?? "")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .tag(ScopeBrowser.Pane.owner(owner.id))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken(owner, denied: denied, selected: selected, all: all, loading: state.loading))
    }

    private func spoken(_ owner: ScopeBrowseOwner, denied: Bool, selected: Int, all: Bool, loading: Bool) -> String {
        var parts = [owner.kind == .shared ? "Shared with you" : owner.login]
        parts.append(owner.kind == .organization ? "organization" : owner.kind == .viewer ? "your account" : "repositories of other owners")
        if denied { parts.append("repositories hidden by GitHub") }
        else if let count = owner.repositoryCount { parts.append("\(count) \(count == 1 ? "repository" : "repositories")") }
        if all { parts.append("all repositories selected") } else if selected > 0 { parts.append("\(selected) selected") }
        if loading { parts.append("loading") }
        return parts.joined(separator: ", ")
    }
}

// MARK: Owner detail

struct OwnerDetail: View {
    @ObservedObject var browser: ScopeBrowser
    @ObservedObject var editor: ScopeEditor
    let owner: ScopeBrowseOwner
    let addByName: () -> Void

    init(browser: ScopeBrowser, owner: ScopeBrowseOwner, addByName: @escaping () -> Void) {
        self.browser = browser; self.editor = browser.editor; self.owner = owner; self.addByName = addByName
    }

    var body: some View {
        let state = browser.state(owner), presentation = browser.presentation(owner)
        let visible = browser.visibleRows(owner)
        List {
            ownerHeader(state).listRowSeparator(.hidden)
            if let banner = banner(presentation, state) { banner.listRowSeparator(.hidden) }
            if let organization = owner.organizationTarget {
                allRepositories(organization).listRowSeparator(.hidden)
            }
            if browser.showsNudge(owner) {
                ScopeBanner(tone: .info, symbol: "lightbulb",
                            text: "Picking several here? “All repositories” covers every repository in \(owner.login), including new ones.",
                            actionTitle: "Use All Repositories") { browser.toggleAll(owner, true) }
                    .listRowSeparator(.hidden)
            }
            switch presentation {
            case .loading:
                loadingRows
            case .empty:
                emptyState.listRowSeparator(.hidden)
            case .signedOut, .ghMissing, .denied, .failed, .notLoaded:
                EmptyView()
            case .rateLimited where state.repositories.isEmpty:
                EmptyView()
            case .rows, .capped, .partial, .rateLimited:
                repositoriesCaption(visible.hiddenArchived, visible.hiddenForks).listRowSeparator(.hidden)
                ForEach(visible.rows) { RepositoryRow(browser: browser, editor: editor, repository: $0, now: browser.now) }
                if !visible.fromSearch.isEmpty {
                    Text("FROM SEARCH").font(.caption.weight(.semibold)).foregroundStyle(.secondary).listRowSeparator(.hidden)
                    ForEach(visible.fromSearch) { RepositoryRow(browser: browser, editor: editor, repository: $0, now: browser.now) }
                }
                if !browser.searchText.isEmpty {
                    ScopeServerSearchRow(browser: browser, owner: owner, addByName: addByName, noLocalMatches: visible.rows.isEmpty && visible.fromSearch.isEmpty)
                }
                pageFooter(state, presentation).listRowSeparator(.hidden)
            }
        }
        .listStyle(.inset)
    }

    private func ownerHeader(_ state: ScopeBrowser.OwnerState) -> some View {
        HStack(spacing: 8) {
            if owner.kind == .shared { Image(systemName: "person.2").font(.title2).foregroundStyle(.secondary) }
            else { Monogram(login: owner.login, size: 28) }
            VStack(alignment: .leading, spacing: 1) {
                Text(browser.displayName(owner)).font(.title3.weight(.semibold))
                Text(ownerSubtitle(state)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func ownerSubtitle(_ state: ScopeBrowser.OwnerState) -> String {
        let kind = owner.kind == .organization ? "organization" : owner.kind == .viewer ? "your account" : "other owners"
        if owner.denied || state.failure == .accessDenied { return "Repositories hidden by GitHub · \(kind)" }
        guard let count = state.total ?? owner.repositoryCount else { return kind }
        return "\(count.formatted()) \(count == 1 ? "repository" : "repositories") · \(kind)"
    }

    private func allRepositories(_ organization: MonitoringTarget) -> some View {
        Toggle(isOn: Binding(get: { browser.allSelected(owner) }, set: { browser.toggleAll(owner, $0) })) {
            VStack(alignment: .leading, spacing: 1) {
                Text("All repositories in \(owner.login)").fontWeight(.semibold)
                Text("Includes repositories added later, as one entry.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
        .accessibilityHint("Selects every repository in this organization, including future ones, and replaces individual picks here.")
    }

    @ViewBuilder private var loadingRows: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small).accessibilityHidden(true)
            Text(browser.sort == .pushed ? "Loading the most recently pushed repositories…" : "Loading repositories by name…")
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .listRowSeparator(.hidden)
        ForEach(0..<6, id: \.self) { index in
            RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.12))
                .frame(width: CGFloat(140 + (index * 37) % 120), height: 10)
                .frame(height: 20)
                .accessibilityHidden(true)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("No repositories you can read.", systemImage: "tray").font(.callout.weight(.semibold))
            Text("GitHub returned a complete answer for \(browser.displayName(owner)).").font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .padding(.vertical, 8)
    }

    private func banner(_ presentation: ScopeBrowser.Presentation, _ state: ScopeBrowser.OwnerState) -> ScopeBanner? {
        let retry = { browser.loadPage(owner) }
        switch presentation {
        case .partial:
            return ScopeBanner(tone: .warning, symbol: "exclamationmark.triangle.fill",
                               text: "Incomplete list: \(state.repositories.count) loaded, then GitHub stopped answering. More exist.",
                               actionTitle: "Retry", action: retry)
        case .rateLimited:
            let reset = browser.rateLimitReset.map { " Resumes after \(ScopeDates.time($0))." } ?? " Try again later."
            return ScopeBanner(tone: .warning, symbol: "clock.badge.exclamationmark",
                               text: "GitHub rate limit reached.\(reset) Loaded repositories stay usable, and Add by Name still works.",
                               actionTitle: "Retry", actionEnabled: !browser.retryBlocked, action: retry)
        case .denied:
            return ScopeBanner(tone: .error, symbol: "lock.trianglebadge.exclamationmark",
                               text: ScopeBrowseFailure.accessDenied.message
                                + (owner.kind == .organization ? " “All repositories” can still be selected; Apply checks access." : ""),
                               actionTitle: "Retry", action: retry)
        case .failed:
            return ScopeBanner(tone: .error, symbol: "xmark.octagon.fill",
                               text: (state.failure?.message ?? "GitHub returned no usable answer.") + " Nothing here means there are no repositories.",
                               actionTitle: "Retry", action: retry)
        case .signedOut:
            return ScopeBanner(tone: .error, symbol: "person.crop.circle.badge.xmark", text: ScopeBrowseFailure.signedOut.message,
                               actionTitle: "Try Again", action: retry)
        case .ghMissing:
            return ScopeBanner(tone: .error, symbol: "terminal", text: ScopeBrowseFailure.ghMissing.message,
                               actionTitle: "Try Again", action: retry)
        case .notLoaded:
            return ScopeBanner(tone: .info, symbol: "arrow.down.circle", text: "Not loaded yet.", actionTitle: "Load", action: retry)
        case .loading, .rows, .capped, .empty:
            return nil
        }
    }

    private func repositoriesCaption(_ archived: Int, _ forks: Int) -> some View {
        HStack {
            Text("REPOSITORIES").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            let hidden = [archived > 0 ? "\(archived) archived" : nil, forks > 0 ? "\(forks) \(forks == 1 ? "fork" : "forks")" : nil]
                .compactMap { $0 }
            if !hidden.isEmpty {
                Text("\(hidden.joined(separator: ", ")) hidden").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    @ViewBuilder private func pageFooter(_ state: ScopeBrowser.OwnerState, _ presentation: ScopeBrowser.Presentation) -> some View {
        let loaded = state.repositories.count
        HStack {
            if presentation == .capped || state.cursor != nil {
                Text("Showing the \(loaded) \(browser.sort == .pushed ? "most recently pushed" : "first by name") of \((state.total ?? loaded).formatted()). Search finds the rest.")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                if state.loading { ProgressView().controlSize(.small) }
                Button("Load \(min(ScopeRepositoryPagePlan.pageSize, max(0, (state.total ?? loaded) - loaded))) More") {
                    browser.loadPage(owner, more: true)
                }
                .disabled(state.loading || state.cursor == nil)
            } else if presentation == .rows {
                Text("Showing all \(loaded)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
}

/// One repository: a single VoiceOver element (the checkbox) carrying the whole sentence.
struct RepositoryRow: View {
    @ObservedObject var browser: ScopeBrowser
    @ObservedObject var editor: ScopeEditor
    let repository: ScopeBrowseRepository
    let now: () -> Date

    var body: some View {
        let covered = browser.isCovered(repository)
        let checked = covered || browser.isSelected(repository)
        let pushed = ScopeDates.relative(repository.pushedAt, now: now())
        HStack(spacing: 6) {
            Toggle(isOn: Binding(get: { checked }, set: { browser.toggle(repository, $0) })) {
                Text(sentence(pushed: pushed, covered: covered))
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(covered || repository.target == nil)
            .help(repository.target == nil ? "This owner's name can't be used as a monitoring target." : "")
            Group {
                Image(systemName: repository.isFork ? "tuningfork" : repository.isPrivate ? "lock" : "book.closed")
                    .foregroundStyle(.secondary).frame(width: 14)
                Text(repository.name)
                    .foregroundStyle(repository.isArchived || covered ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.middle)
                if repository.isArchived { RowTag(text: "Archived") }
                if repository.isFork { RowTag(text: "Fork") }
                Spacer(minLength: 4)
                Text(covered ? "Included by All repositories" : pushed)
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
            .accessibilityHidden(true)
        }
        .frame(height: 22)
        .contentShape(Rectangle())
        .onTapGesture { if !covered && repository.target != nil { browser.toggle(repository, !checked) } }
    }

    private func sentence(pushed: String, covered: Bool) -> String {
        var parts = [repository.name, repository.owner, repository.isPrivate ? "private" : "public"]
        if repository.isFork { parts.append("fork") }
        if repository.isArchived { parts.append("archived") }
        parts.append("pushed \(pushed)")
        if covered { parts.append("included by All repositories in \(repository.owner)") }
        return parts.joined(separator: ", ")
    }
}

private struct RowTag: View {
    let text: String
    var body: some View {
        Text(text).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.secondary.opacity(0.5)))
    }
}

/// "Search GitHub for “term” in {owner}" for an owner that isn't fully loaded; also the no-match
/// state, which always says how much is unloaded instead of reading as empty.
struct ScopeServerSearchRow: View {
    @ObservedObject var browser: ScopeBrowser
    let owner: ScopeBrowseOwner
    let addByName: () -> Void
    var noLocalMatches: Bool

    var body: some View {
        let state = browser.state(owner)
        let loaded = state.repositories.count, total = state.total ?? owner.repositoryCount
        VStack(alignment: .leading, spacing: 6) {
            if noLocalMatches {
                Text(state.complete ? "No repository in \(browser.displayName(owner)) matches “\(browser.searchText)”."
                     : "No loaded repository in \(browser.displayName(owner)) matches “\(browser.searchText)”.")
                    .font(.callout)
                if !state.complete, let total, total > loaded {
                    Text("\((total - loaded).formatted()) repositories aren't loaded yet.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let term = state.searchedTerm, !state.searching {
                if let failure = state.searchFailure {
                    Label(failure.message, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                } else {
                    Text("GitHub search for “\(term)” found \(state.searchTotal ?? 0) \(state.searchTotal == 1 ? "match" : "matches") by name.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                if owner.kind != .shared && !state.complete && !owner.denied {
                    Button {
                        browser.searchServer(owner)
                    } label: {
                        Label("Search GitHub for “\(browser.sanitizedSearch ?? browser.searchText)” in \(browser.displayName(owner))",
                              systemImage: "magnifyingglass")
                    }
                    .disabled(!browser.canSearchServer(owner))
                    if state.searching { ProgressView().controlSize(.small) }
                    if let total {
                        Text("\(loaded.formatted()) of \(total.formatted()) loaded").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                if noLocalMatches { Button("Add by Name…", action: addByName) }
            }
        }
        .padding(.vertical, 4)
    }
}

/// All owners scope: loaded matches grouped by owner, plus a server search row per owner that
/// isn't fully loaded.
struct ScopeSearchResults: View {
    @ObservedObject var browser: ScopeBrowser
    let addByName: () -> Void

    var body: some View {
        let groups = browser.searchOwners.map { ($0, browser.visibleRows($0)) }
        let matches = groups.reduce(0) { $0 + $1.1.rows.count + $1.1.fromSearch.count }
        List {
            Text(matches == 0 ? "No loaded repository matches “\(browser.searchText)”." : "\(matches) loaded \(matches == 1 ? "match" : "matches")")
                .font(.callout.weight(.semibold)).listRowSeparator(.hidden)
            ForEach(groups, id: \.0.id) { owner, visible in
                let searchable = owner.kind != .shared && !browser.state(owner).complete && !owner.denied
                if !visible.rows.isEmpty || !visible.fromSearch.isEmpty || (searchable && owner.id == browser.currentOwner?.id) {
                    Section {
                        ForEach(visible.rows + visible.fromSearch) {
                            RepositoryRow(browser: browser, editor: browser.editor, repository: $0, now: browser.now)
                        }
                        if searchable {
                            ScopeServerSearchRow(browser: browser, owner: owner, addByName: addByName, noLocalMatches: false)
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Monogram(login: owner.login.isEmpty ? "shared" : owner.login, size: 16)
                            Text(browser.displayName(owner))
                        }
                    }
                }
            }
            if matches == 0 {
                let unloaded = browser.owners.reduce(0) { total, owner in
                    total + max(0, (browser.state(owner).total ?? owner.repositoryCount ?? 0) - browser.state(owner).repositories.count)
                }
                VStack(alignment: .leading, spacing: 6) {
                    if unloaded > 0 {
                        Text("\(unloaded.formatted()) repositories aren't loaded yet. Search GitHub in an owner, or add one by name.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Add by Name…", action: addByName)
                }
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.inset)
    }
}

/// The Selected review: every entry, removable, with inline access problems after Apply.
struct SelectedReview: View {
    @ObservedObject var editor: ScopeEditor
    let entries: [ScopeEntry]
    let addByName: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Selected").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
            if editor.draft.mode == .everything {
                Text("Monitoring everything you can access. Check repositories or organizations to monitor only those.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if entries.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Nothing selected yet.").font(.callout)
                    Text("Choose an owner on the left, or add one by name.").font(.caption).foregroundStyle(.secondary)
                    Button("Add by Name…", action: addByName)
                }
            } else {
                let problems = entries.filter { $0.problem != nil }.count
                if problems > 0 {
                    ScopeBanner(tone: .error, symbol: "exclamationmark.triangle.fill",
                                text: "\(problems) \(problems == 1 ? "entry" : "entries") could not be verified. Remove or correct \(problems == 1 ? "it" : "them"), then Apply.")
                }
                ScrollingEntryList(entries: entries, rowHeight: 40) { entry in
                    ScopeEntryRow(entry: entry) { remove(entry) }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func remove(_ entry: ScopeEntry) {
        if editor.draft.rows.contains(where: { $0.id == entry.id }) { editor.remove(entry.id) }
    }
}

struct AccountProblemView: View {
    let symbol: String
    let title: String
    let detail: String
    let retry: () -> Void
    let addByName: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(.orange).accessibilityHidden(true)
            Text(title).font(.title3.weight(.semibold))
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack {
                Button("Try Again", action: retry)
                Button("Add by Name…", action: addByName)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}
