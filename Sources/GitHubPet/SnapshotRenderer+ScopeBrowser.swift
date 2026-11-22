import AppKit
import GitHubPetCore
import SwiftUI

/// Choose Repositories sheet (#137), offscreen, light and dark: one render per state, driven by
/// the offline browse fixture through the production parsers and the real editor draft. Invented
/// `demo-` names only. Every line says which presentation is shown, and render-check asserts that
/// only the truly empty owner claims "no repositories".
extension SnapshotRenderer {
    static func scopeBrowserRenders(model: AppModel, directory: URL) async -> [String] {
        var report = ["## scope browser (#137)"]
        let editor = model.scopeEditor
        editor.cancel()
        let size = ScopeBrowserSheet.idealSize

        report.append("scope-browser identity=\(editor.identity == .demo ? "demo" : "other")")
        func browser(_ mode: ScopeBrowseFixture.Mode) -> ScopeBrowser {
            let browser = ScopeBrowser(editor: editor, now: { model.clock() }) { _ in
                ScopeBrowseFixture(mode: mode, account: ScopeBrowser.demoAccount, login: "demo-user", now: model.clock())
            }
            browser.announce = { _ in }
            return browser
        }
        func owner(_ browser: ScopeBrowser, _ login: String) -> ScopeBrowseOwner? {
            browser.owners.first { $0.login == login }
        }
        func phase(_ value: ScopeBrowser.OwnersPhase) -> String {
            if case .failed(let failure) = value { return "failed:\(failure)" }
            return "\(value)"
        }
        func line(_ name: String, _ browser: ScopeBrowser) -> String {
            let current = browser.currentOwner
            let presentation = current.map { "\(browser.presentation($0))" } ?? "none"
            let rows = current.map { browser.visibleRows($0).rows.count + browser.visibleRows($0).fromSearch.count } ?? 0
            let pane: String
            switch browser.pane {
            case .selected: pane = "selected"
            case .browse: pane = "browse"
            case .owner: pane = "owner:\(current?.login ?? "?")"
            }
            return "scope-browser \(name): pane=\(pane) owners=\(browser.owners.count) phase=\(phase(browser.ownersPhase)) "
                + "presentation=\(presentation) rows=\(rows) selected=\(editor.draft.rows.count) "
                + "empty-claim=\(current.map { browser.presentation($0) == .empty } ?? false) "
                + "notice=\(browser.notice == nil ? "none" : "shown")"
        }
        func shoot(_ name: String, _ browser: ScopeBrowser) async {
            report.append(line(name, browser))
            for (suffix, appearance) in [("", NSAppearance.Name.aqua), ("-dark", .darkAqua)] {
                report += await render(ScopeBrowserSheet(model: model, browser: browser) {}
                                        .frame(width: size.width, height: size.height),
                                       name: "scope-browser-\(name)\(suffix)", directory: directory, appearance: appearance,
                                       asWindow: true)
            }
        }
        func opened(_ mode: ScopeBrowseFixture.Mode, _ login: String?) async -> ScopeBrowser {
            let value = browser(mode)
            value.sync()
            await value.settle()
            if let login, let target = owner(value, login) { value.open(target); await value.settle() }
            return value
        }

        // Browse an organization with two repositories checked.
        let browse = await opened(.complete, "demo-lumen-labs")
        if let lumen = owner(browse, "demo-lumen-labs") {
            browse.visibleRows(lumen).rows.prefix(2).forEach { browse.toggle($0, true) }
        }
        await shoot("browse", browse)
        // All repositories replaces those picks; the rows show as included.
        if let lumen = owner(browse, "demo-lumen-labs") { browse.toggleAll(lumen, true) }
        await shoot("all-repositories", browse)
        editor.cancel()
        // Nudge: three picks in one organization.
        let nudge = await opened(.complete, "demo-example-org")
        if let example = owner(nudge, "demo-example-org") {
            nudge.visibleRows(example).rows.prefix(3).forEach { nudge.toggle($0, true) }
        }
        // A badge beside a four-digit count: the count stays on one line, the name truncates.
        if let harbor = owner(nudge, "demo-harbor"), let row = nudge.visibleRows(harbor).rows.first { nudge.toggle(row, true) }
        await shoot("nudge", nudge)
        editor.cancel()

        let loading = await opened(.complete, nil)
        if let example = owner(loading, "demo-example-org") { loading.showLoadingForSnapshot(example) }
        await shoot("loading", loading)
        await shoot("capped", await opened(.complete, "demo-harbor"))
        await shoot("partial", await opened(.partial, "demo-example-org"))
        await shoot("rate-limited", await opened(.rateLimited, "demo-example-org"))
        await shoot("denied", await opened(.complete, "demo-tidewater"))
        await shoot("empty", await opened(.complete, "demo-quiet-meadow"))
        // Shared with you, including a managed-user owner's repository that can't be a target.
        let managed = await opened(.complete, nil)
        if let shared = managed.owners.first(where: { $0.kind == .shared }) { managed.open(shared); await managed.settle() }
        let unsupported = managed.currentOwner.map { managed.visibleRows($0).rows.filter { $0.target == nil }.count } ?? 0
        report.append("scope-browser managed-rows: unsupported=\(unsupported)")
        await shoot("managed", managed)
        await shoot("signed-out", await opened(.signedOut, nil))
        await shoot("gh-missing", await opened(.ghMissing, nil))
        // Identity changed mid-browse: the page names another account; everything is discarded.
        await shoot("identity-changed", await opened(.identityMismatch, "demo-example-org"))

        // Search: loaded matches, then GitHub search in a large owner merges "From search" rows.
        let search = await opened(.complete, "demo-harbor")
        search.searchText = "org:demo-x lantern"
        search.searchAllOwners = false
        if let harbor = owner(search, "demo-harbor") { search.searchServer(harbor); await search.settle() }
        await shoot("search", search)
        let noMatch = await opened(.complete, "demo-lumen-labs")
        noMatch.searchText = "zephyr"
        noMatch.searchAllOwners = false
        await shoot("no-matches", noMatch)
        let allOwners = await opened(.complete, "demo-lumen-labs")
        allOwners.searchText = "beacon"
        await shoot("search-all-owners", allOwners)

        // A long selection through the real draft (no product cap since #140): the review and the
        // Settings summary scroll with an edge fade and an "N more" count. One entry added by name,
        // one with an inline format error.
        editor.setMode(.selected)
        for index in 0..<Self.longSelectionCount {
            if index % 9 == 0 {
                editor.setSelected(try! MonitoringTarget(organization: "demo-org-\(index)"), true)
            } else {
                editor.setSelected(try! MonitoringTarget(repository: "demo-owner-\(index % 7)/demo-repository-\(index)"), true)
            }
        }
        editor.addByName("demo-partner/private-tools")
        if let row = editor.draft.rows.dropFirst(4).first { editor.update(row.id, text: "org:demo is:pr") }
        let review = await opened(.complete, nil)
        review.pane = .selected
        await shoot("selected-long", review)
        let count = editor.draft.rows.count
        let hidden = ScrollingEntryList<EmptyView>.hiddenBelow(count: count, rowHeight: MonitoringScopeSection.rowHeight, offset: 0,
                                                             viewport: CGFloat(MonitoringScopeSection.visibleRows) * MonitoringScopeSection.rowHeight)
        report.append("scope-settings-long: entries=\(count) draft=real visible-rows=\(MonitoringScopeSection.visibleRows) more-cue=\(hidden)")
        for (suffix, appearance) in [("", NSAppearance.Name.aqua), ("-dark", .darkAqua)] {
            report += await render(Form { MonitoringScopeSection(model: model, editor: editor) }
                                    .formStyle(.grouped).frame(width: 520),
                                   name: "scope-settings-long\(suffix)", directory: directory, appearance: appearance)
            report += await render(AddByNameSheet(editor: editor, text: "demo-partner/more-tools") {},
                                   name: "scope-add-by-name\(suffix)", directory: directory, appearance: appearance)
            report += await render(AddByNameSheet(editor: editor, text: "org:demo is:pr") {},
                                   name: "scope-add-by-name-invalid\(suffix)", directory: directory, appearance: appearance)
        }
        editor.cancel()
        report.append("")
        return report
    }

    /// The account isn't verified yet (here: the GitHub CLI source with gh missing): the sheet
    /// says it is checking the account instead of showing an empty list.
    static func scopeBrowserCheckingAccountRender(model: AppModel, directory: URL) async -> [String] {
        var report = ["## scope browser account check (#137)"]
        let browser = ScopeBrowser(editor: model.scopeEditor, now: { model.clock() }) { _ in
            ScopeBrowseFixture(mode: .complete, account: ScopeBrowser.demoAccount, login: "demo-user", now: model.clock())
        }
        browser.announce = { _ in }
        browser.sync()
        report.append("scope-browser checking-account: identity=\(model.scopeEditor.identity == nil ? "none" : "known") phase=\(browser.ownersPhase)")
        for (suffix, appearance) in [("", NSAppearance.Name.aqua), ("-dark", .darkAqua)] {
            report += await render(ScopeBrowserSheet(model: model, browser: browser) {}
                                    .frame(width: ScopeBrowserSheet.idealSize.width, height: ScopeBrowserSheet.idealSize.height),
                                   name: "scope-browser-checking-account\(suffix)", directory: directory, appearance: appearance)
        }
        report.append("")
        return report
    }

    static let longSelectionCount = 120
}
