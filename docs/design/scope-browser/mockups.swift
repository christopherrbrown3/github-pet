// Throwaway design mockups for the monitoring scope browser (#137). Not production code: it lives
// outside Sources, draws static SwiftUI layouts with invented demo names only, and renders them
// offscreen to PNG (light and dark) the same way SnapshotRenderer does. It never launches the app,
// never calls gh and writes nothing but the PNGs.
//
//   swiftc -O docs/design/scope-browser/mockups.swift -o <scratch>/scope-mockups
//   <scratch>/scope-mockups docs/design/scope-browser
import AppKit
import SwiftUI

// MARK: Demo data (invented)

enum Check { case off, on, inherited, disabled }

struct Repo: Identifiable {
    let id = UUID()
    var owner: String
    var name: String
    var isPrivate = false
    var archived = false
    var fork = false
    var pushed: String
    var check = Check.off
}

struct Owner: Identifiable {
    let id = UUID()
    var login: String
    var detail: String
    var badge: Badge = .none
    var isYou = false
    enum Badge { case none, all, count(Int), warning, loading }
}

let owners: [Owner] = [
    Owner(login: "demo-user", detail: "23", isYou: true),
    Owner(login: "example-org", detail: "240", badge: .all),
    Owner(login: "harbor-demo", detail: "6,500"),
    Owner(login: "lumen-labs", detail: "38", badge: .count(2)),
    Owner(login: "tidewater-demo", detail: "—", badge: .warning),
    Owner(login: "quiet-meadow", detail: "0"),
]

let lumenRepos: [Repo] = [
    Repo(owner: "lumen-labs", name: "lantern-api", isPrivate: true, pushed: "2 hours ago", check: .on),
    Repo(owner: "lumen-labs", name: "lantern-web", isPrivate: true, pushed: "5 hours ago", check: .on),
    Repo(owner: "lumen-labs", name: "design-tokens", pushed: "yesterday"),
    Repo(owner: "lumen-labs", name: "infra-terraform", isPrivate: true, pushed: "3 days ago"),
    Repo(owner: "lumen-labs", name: "docs-site", pushed: "last week"),
    Repo(owner: "lumen-labs", name: "swift-format", fork: true, pushed: "last month"),
    Repo(owner: "lumen-labs", name: "legacy-dashboard", isPrivate: true, archived: true, pushed: "Mar 2024"),
]

// MARK: Building blocks

func hue(_ text: String) -> Color {
    let owner = text.split(separator: "/").first.map(String.init) ?? text
    let sum = owner.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
    return Color(hue: Double(sum % 360) / 360, saturation: 0.45, brightness: 0.72)
}

struct Monogram: View {
    var login: String
    var size: CGFloat = 20
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28)
            .fill(hue(login))
            .frame(width: size, height: size)
            .overlay(Text(login.prefix(1).uppercased()).font(.system(size: size * 0.55, weight: .semibold)).foregroundColor(.white))
    }
}

struct CheckBox: View {
    var state: Check
    var body: some View {
        switch state {
        case .off: Image(systemName: "square").foregroundColor(.secondary)
        case .on: Image(systemName: "checkmark.square.fill").foregroundColor(.accentColor)
        case .inherited: Image(systemName: "checkmark.square.fill").foregroundColor(.secondary.opacity(0.6))
        case .disabled: Image(systemName: "square").foregroundColor(.secondary.opacity(0.35))
        }
    }
}

struct Tag: View {
    var text: String
    var body: some View {
        Text(text).font(.system(size: 10, weight: .medium)).foregroundColor(.secondary)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .overlay(Capsule().stroke(Color.secondary.opacity(0.5), lineWidth: 0.5))
    }
}

struct RepoRow: View {
    var repo: Repo
    var showOwner = false
    var body: some View {
        HStack(spacing: 8) {
            CheckBox(state: repo.check).font(.system(size: 14))
            Image(systemName: repo.isPrivate ? "lock.fill" : (repo.fork ? "tuningfork" : "book.closed"))
                .font(.system(size: 11)).foregroundColor(.secondary).frame(width: 14)
            Text(showOwner ? "\(repo.owner)/\(repo.name)" : repo.name)
                .foregroundColor(repo.check == .disabled || repo.archived ? .secondary : .primary)
                .lineLimit(1).truncationMode(.middle)
            if repo.archived { Tag(text: "Archived") }
            if repo.fork { Tag(text: "Fork") }
            Spacer(minLength: 8)
            Text(repo.pushed).font(.callout).foregroundColor(.secondary).monospacedDigit()
        }
        .padding(.horizontal, 12).frame(height: 26)
    }
}

struct SearchField: View {
    var text: String
    var focused = false
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary)
            if text.isEmpty {
                Text("Search repositories and organizations").foregroundColor(.secondary.opacity(0.8))
            } else {
                Text(text)
            }
            Spacer()
            if !text.isEmpty { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) }
        }
        .padding(.horizontal, 7).frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(focused ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.35),
                                                          lineWidth: focused ? 3 : 0.5))
    }
}

struct PillButton: View {
    var title: String
    var symbol: String
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text(title)
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
        }
        .font(.callout).padding(.horizontal, 8).frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)))
    }
}

enum BannerKind { case info, warning, error }

struct Banner: View {
    var kind: BannerKind
    var title: String
    var message: String
    var action: String?
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: kind == .info ? "info.circle.fill" : kind == .warning ? "exclamationmark.triangle.fill" : "xmark.octagon.fill")
                .foregroundColor(kind == .info ? .accentColor : kind == .warning ? .orange : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(message).font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if let action { Button(action) {}.controlSize(.small) }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill((kind == .info ? Color.accentColor : kind == .warning ? .orange : .red).opacity(0.10)))
    }
}

// MARK: Sheet

struct Sidebar: View {
    var selectedLogin: String?
    var selectedRowCount = 4
    var ownerOverride: [Owner]? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            row(icon: "checklist", title: "Selected", trailing: "\(selectedRowCount)", selected: selectedLogin == "Selected")
            header("Your account")
            ForEach((ownerOverride ?? owners).filter(\.isYou)) { ownerRow($0) }
            row(icon: "person.2", title: "Shared with you", trailing: "7", selected: false)
            header("Organizations")
            ForEach((ownerOverride ?? owners).filter { !$0.isYou }) { ownerRow($0) }
            Spacer()
        }
        .padding(.horizontal, 8).padding(.top, 8)
        .frame(width: 224)
        .frame(maxHeight: .infinity)
        .background(Color.secondary.opacity(0.06))
    }

    func header(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
            .padding(.leading, 8).padding(.top, 10).padding(.bottom, 2)
    }

    func row(icon: String, title: String, trailing: String, selected: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon).frame(width: 20).foregroundColor(selected ? .white : .accentColor)
            Text(title).foregroundColor(selected ? .white : .primary)
            Spacer()
            Text(trailing).font(.callout).foregroundColor(selected ? .white.opacity(0.85) : .secondary).monospacedDigit()
        }
        .padding(.horizontal, 8).frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Color.accentColor : .clear))
    }

    func ownerRow(_ owner: Owner) -> some View {
        let selected = owner.login == selectedLogin
        return HStack(spacing: 7) {
            Monogram(login: owner.login)
            Text(owner.isYou ? "\(owner.login) (you)" : owner.login).lineLimit(1).foregroundColor(selected ? .white : .primary)
            Spacer()
            switch owner.badge {
            case .all: Image(systemName: "checkmark.circle.fill").foregroundColor(selected ? .white : .accentColor)
            case .count(let n):
                Text("\(n)").font(.system(size: 11, weight: .semibold)).foregroundColor(.white)
                    .padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(selected ? Color.white.opacity(0.3) : Color.accentColor))
            case .warning: Image(systemName: "lock.trianglebadge.exclamationmark").foregroundColor(selected ? .white : .orange)
            case .loading: ProgressView().controlSize(.small).scaleEffect(0.7)
            case .none: EmptyView()
            }
            Text(owner.detail).font(.callout).foregroundColor(selected ? .white.opacity(0.85) : .secondary).monospacedDigit()
        }
        .padding(.horizontal, 8).frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Color.accentColor : .clear))
    }
}

struct OwnerHeader: View {
    var login: String
    var subtitle: String
    var allState: Check
    var allNote: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Monogram(login: login, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(login).font(.title3.weight(.semibold))
                    Text(subtitle).font(.callout).foregroundColor(.secondary)
                }
                Spacer()
            }
            HStack(alignment: .top, spacing: 8) {
                CheckBox(state: allState).font(.system(size: 14))
                VStack(alignment: .leading, spacing: 1) {
                    Text("All repositories in \(login)").fontWeight(.medium)
                    Text(allNote).font(.callout).foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
        }
        .padding(.horizontal, 12).padding(.top, 12)
    }
}

struct ListCaption: View {
    var left: String
    var right: String = ""
    var body: some View {
        HStack {
            Text(left).font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
            Spacer()
            Text(right).font(.system(size: 11)).foregroundColor(.secondary)
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 2)
    }
}

struct Footer: View {
    var count: Int
    var note: String? = nil
    var applyEnabled = true
    var body: some View {
        HStack(spacing: 10) {
            Text("\(count) of 10 selected")
                .font(.callout.weight(.medium)).monospacedDigit()
                .foregroundColor(count >= 10 ? .orange : .primary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill((count >= 10 ? Color.orange : Color.secondary).opacity(0.12)))
            if let note { Text(note).font(.callout).foregroundColor(.secondary).lineLimit(1) }
            Button("Add by Name…") {}
            Spacer()
            Button("Cancel") {}.keyboardShortcut(.cancelAction)
            Button("Apply") {}.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(!applyEnabled)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}

struct SheetChrome<Content: View>: View {
    var search = ""
    var searchFocused = false
    var sidebarSelection: String?
    var count = 4
    var footerNote: String? = nil
    var ownerOverride: [Owner]? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Choose Repositories to Monitor").font(.headline)
                Spacer()
                Text("GitHub CLI account: demo-user").font(.callout).foregroundColor(.secondary)
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
            HStack(spacing: 8) {
                SearchField(text: search, focused: searchFocused)
                PillButton(title: "Hide archived", symbol: "line.3.horizontal.decrease.circle")
                PillButton(title: "Recently pushed", symbol: "arrow.up.arrow.down")
            }
            .padding(.horizontal, 16).padding(.bottom, 10)
            Divider()
            HStack(spacing: 0) {
                Sidebar(selectedLogin: sidebarSelection, selectedRowCount: count, ownerOverride: ownerOverride)
                Divider()
                VStack(alignment: .leading, spacing: 0) { content() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            Divider()
            Footer(count: count, note: footerNote)
        }
        .frame(width: 780, height: 540)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: Screens

struct BrowseScreen: View {
    var body: some View {
        SheetChrome(sidebarSelection: "lumen-labs") {
            OwnerHeader(login: "lumen-labs", subtitle: "38 repositories · organization",
                        allState: .off, allNote: "Includes repositories added later. Uses 1 of 10.")
            ListCaption(left: "REPOSITORIES", right: "1 archived hidden")
            ForEach(lumenRepos.filter { !$0.archived }) { RepoRow(repo: $0) }
            HStack(spacing: 6) {
                Image(systemName: "lightbulb").foregroundColor(.secondary)
                Text("Picking several here? “All repositories” uses one slot and covers new ones.")
                    .font(.callout).foregroundColor(.secondary)
            }
            .padding(.horizontal, 12).padding(.top, 10)
            Spacer()
            HStack {
                Text("Showing all 38").font(.callout).foregroundColor(.secondary)
                Spacer()
            }
            .padding(12)
        }
    }
}

struct OrgAllScreen: View {
    var body: some View {
        SheetChrome(sidebarSelection: "example-org") {
            OwnerHeader(login: "example-org", subtitle: "240 repositories · organization",
                        allState: .on, allNote: "Selected. Every repository, including new ones. Uses 1 of 10.")
            ListCaption(left: "REPOSITORIES · INCLUDED BY “ALL REPOSITORIES”", right: "100 of 240 loaded")
            ForEach([
                Repo(owner: "example-org", name: "checkout-service", isPrivate: true, pushed: "12 minutes ago", check: .inherited),
                Repo(owner: "example-org", name: "mobile-app", isPrivate: true, pushed: "1 hour ago", check: .inherited),
                Repo(owner: "example-org", name: "payments-gateway", isPrivate: true, pushed: "3 hours ago", check: .inherited),
                Repo(owner: "example-org", name: "public-website", pushed: "yesterday", check: .inherited),
                Repo(owner: "example-org", name: "openapi-specs", pushed: "2 days ago", check: .inherited),
                Repo(owner: "example-org", name: "eslint-config", fork: true, pushed: "last week", check: .inherited),
                Repo(owner: "example-org", name: "terraform-modules", isPrivate: true, pushed: "last week", check: .inherited),
            ]) { RepoRow(repo: $0) }
            Spacer()
            HStack {
                Text("Showing the 100 most recently pushed of 240").font(.callout).foregroundColor(.secondary)
                Spacer()
                Button("Load 100 More") {}.controlSize(.small)
            }
            .padding(12)
        }
    }
}

struct SearchScreen: View {
    var body: some View {
        SheetChrome(search: "lant", searchFocused: true, sidebarSelection: nil) {
            HStack(spacing: 0) {
                Picker("", selection: .constant(0)) {
                    Text("All owners").tag(0)
                    Text("lumen-labs").tag(1)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                Spacer()
                Text("3 matches in loaded repositories").font(.callout).foregroundColor(.secondary)
            }
            .padding(.horizontal, 12).padding(.top, 12)
            ListCaption(left: "LUMEN-LABS")
            RepoRow(repo: Repo(owner: "lumen-labs", name: "lantern-api", isPrivate: true, pushed: "2 hours ago", check: .on), showOwner: true)
            RepoRow(repo: Repo(owner: "lumen-labs", name: "lantern-web", isPrivate: true, pushed: "5 hours ago", check: .on), showOwner: true)
            ListCaption(left: "DEMO-USER")
            RepoRow(repo: Repo(owner: "demo-user", name: "lantern-notes", pushed: "Jun 2025"), showOwner: true)
            ListCaption(left: "NOT FULLY LOADED")
            VStack(alignment: .leading, spacing: 6) {
                searchMore("harbor-demo", "100 of 6,500 loaded")
                searchMore("example-org", "100 of 240 loaded")
            }
            .padding(.horizontal, 12)
            Spacer()
        }
    }

    func searchMore(_ owner: String, _ detail: String) -> some View {
        HStack(spacing: 8) {
            Monogram(login: owner, size: 16)
            Text("Search GitHub for “lant” in \(owner)")
            Text(detail).font(.callout).foregroundColor(.secondary)
            Spacer()
            Image(systemName: "arrow.forward.circle").foregroundColor(.accentColor)
        }
        .padding(.horizontal, 8).frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3), lineWidth: 0.5))
    }
}

struct SelectedScreen: View {
    var body: some View {
        SheetChrome(sidebarSelection: "Selected") {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Selected").font(.title3.weight(.semibold))
                    Text("4 of 10 · Apply checks access to each before monitoring changes").font(.callout).foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(12)
            selected("example-org", "All repositories · 240", "building.2")
            selected("lumen-labs/lantern-api", "Repository · private", "lock.fill")
            selected("lumen-labs/lantern-web", "Repository · private", "lock.fill")
            selected("partner-sso-demo/billing", "Added by name · not listed by GitHub", "character.cursor.ibeam")
            Spacer()
        }
    }

    func selected(_ name: String, _ detail: String, _ icon: String) -> some View {
        HStack(spacing: 8) {
            Monogram(login: name, size: 20)
            VStack(alignment: .leading, spacing: 0) {
                Text(name)
                HStack(spacing: 4) {
                    Image(systemName: icon).font(.system(size: 9))
                    Text(detail)
                }
                .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Image(systemName: "minus.circle.fill").foregroundColor(.secondary).font(.system(size: 14))
        }
        .padding(.horizontal, 12).frame(height: 38)
    }
}

// MARK: States

struct StatePanel<Content: View>: View {
    var title: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .bold)).foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 0) { content() }
                .frame(width: 360, height: 232, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.35), lineWidth: 0.5))
                .clipped()
        }
    }
}

struct CenteredState: View {
    var symbol: String
    var title: String
    var message: String
    var actions: [String]
    var tint: Color = .secondary
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 26)).foregroundColor(tint)
            Text(title).font(.headline).multilineTextAlignment(.center)
            Text(message).font(.callout).foregroundColor(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack { ForEach(actions, id: \.self) { Button($0) {}.controlSize(.small) } }
        }
        .padding(18).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MiniHeader: View {
    var login: String
    var subtitle: String
    var body: some View {
        HStack(spacing: 8) {
            Monogram(login: login, size: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(login).font(.headline)
                Text(subtitle).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(10)
    }
}

let sample: [Repo] = [
    Repo(owner: "harbor-demo", name: "dock-scheduler", isPrivate: true, pushed: "4 minutes ago"),
    Repo(owner: "harbor-demo", name: "crane-ui", pushed: "1 hour ago"),
    Repo(owner: "harbor-demo", name: "manifest-tools", isPrivate: true, pushed: "today"),
]

struct StatesScreen: View {
    var body: some View {
        let columns = [GridItem(.fixed(360), spacing: 20), GridItem(.fixed(360), spacing: 20), GridItem(.fixed(360), spacing: 20)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
            StatePanel(title: "1 · LOADING (FIRST PAGE)") {
                MiniHeader(login: "harbor-demo", subtitle: "6,500 repositories")
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading the most recently pushed repositories…").font(.callout).foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                ForEach(0..<4, id: \.self) { _ in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.15)).frame(width: 14, height: 14)
                        RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.15)).frame(width: 150, height: 10)
                        Spacer()
                        RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.10)).frame(width: 60, height: 10)
                    }
                    .padding(.horizontal, 12).frame(height: 26)
                }
            }
            StatePanel(title: "2 · CAPPED (LARGE ORGANIZATION)") {
                MiniHeader(login: "harbor-demo", subtitle: "6,500 repositories")
                ForEach(sample) { RepoRow(repo: $0) }
                Spacer()
                HStack {
                    Text("100 of 6,500 loaded. Search finds the rest.").font(.callout).foregroundColor(.secondary)
                    Spacer()
                    Button("Load 100 More") {}.controlSize(.small)
                }
                .padding(10)
            }
            StatePanel(title: "3 · PARTIAL (STOPPED MID-WAY)") {
                MiniHeader(login: "harbor-demo", subtitle: "6,500 repositories")
                Banner(kind: .warning, title: "Incomplete list", message: "200 loaded, then GitHub stopped answering. More exist.", action: "Retry")
                    .padding(.horizontal, 10)
                ForEach(sample.prefix(2)) { RepoRow(repo: $0) }
            }
            StatePanel(title: "4 · RATE LIMITED") {
                MiniHeader(login: "harbor-demo", subtitle: "6,500 repositories")
                Banner(kind: .warning, title: "GitHub rate limit reached",
                       message: "Loaded rows stay usable. Browsing resumes after 14:05; Add by Name still works.", action: nil)
                    .padding(.horizontal, 10)
                ForEach(sample.prefix(2)) { RepoRow(repo: $0) }
            }
            StatePanel(title: "5 · ACCESS DENIED (SSO / TOKEN SCOPE)") {
                MiniHeader(login: "tidewater-demo", subtitle: "Repositories hidden by GitHub")
                Banner(kind: .error, title: "GitHub withheld this list",
                       message: "Single sign-on or a token scope blocks it. Run gh auth refresh and authorize SSO, then Retry.",
                       action: "Retry")
                    .padding(.horizontal, 10)
                HStack(spacing: 8) {
                    CheckBox(state: .off)
                    Text("All repositories in tidewater-demo")
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.top, 10)
                Button("Add a Repository by Name…") {}.controlSize(.small).padding(.horizontal, 12).padding(.top, 8)
            }
            StatePanel(title: "6 · SIGNED OUT / GH MISSING") {
                CenteredState(symbol: "person.crop.circle.badge.exclamationmark", title: "Sign in to GitHub CLI to browse",
                              message: "Run gh auth login in Terminal, then Try Again. Your current selection is kept.",
                              actions: ["Try Again", "Add by Name…"], tint: .orange)
            }
            StatePanel(title: "7 · TRULY EMPTY (COMPLETE ANSWER)") {
                MiniHeader(login: "quiet-meadow", subtitle: "0 repositories")
                CenteredState(symbol: "tray", title: "No repositories you can read",
                              message: "GitHub returned a complete answer for quiet-meadow. You can still monitor the organization.",
                              actions: ["Add by Name…"])
            }
            StatePanel(title: "8 · NO SEARCH MATCHES") {
                CenteredState(symbol: "magnifyingglass", title: "No loaded repository matches “zeta”",
                              message: "harbor-demo has 6,400 repositories not loaded yet.",
                              actions: ["Search GitHub in harbor-demo", "Add by Name…"])
            }
            StatePanel(title: "9 · LIMIT REACHED (10 OF 10)") {
                MiniHeader(login: "harbor-demo", subtitle: "6,500 repositories")
                Banner(kind: .info, title: "10 of 10 selected",
                       message: "Remove an entry, or choose “All repositories” for an organization to cover more.", action: nil)
                    .padding(.horizontal, 10)
                RepoRow(repo: Repo(owner: "harbor-demo", name: "dock-scheduler", isPrivate: true, pushed: "4 minutes ago", check: .on))
                RepoRow(repo: Repo(owner: "harbor-demo", name: "crane-ui", pushed: "1 hour ago", check: .disabled))
            }
        }
        .padding(24)
        .frame(width: 1160)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: Settings section and Add by Name

struct SettingsScreen: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("Account") { Text("demo-user") }
                Picker("Monitor", selection: .constant(1)) {
                    Text("Everything accessible").tag(0)
                    Text("Selected organizations and repositories").tag(1)
                }
                .pickerStyle(.radioGroup)
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Selected").font(.headline)
                        Text("4 of 10").foregroundColor(.secondary).monospacedDigit()
                        Spacer()
                    }
                    .padding(.bottom, 6)
                    entry("example-org", "All repositories")
                    entry("lumen-labs/lantern-api", "Repository")
                    entry("lumen-labs/lantern-web", "Repository")
                    entry("partner-sso-demo/billing", "Repository · added by name")
                }
                HStack {
                    Button("Choose Repositories…") {}
                    Button("Add by Name…") {}
                    Spacer()
                }
                HStack {
                    Text("Applied 2 minutes ago. Monitoring 4 entries.").font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Button("Cancel") {}.disabled(true)
                    Button("Apply") {}.disabled(true)
                }
            } header: {
                Text("Monitoring scope")
            } footer: {
                Text("Applies to requested reviews and assigned issues. Public GitHub service incidents are always shown.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 470)
    }

    func entry(_ name: String, _ kind: String) -> some View {
        HStack(spacing: 8) {
            Monogram(login: name, size: 18)
            Text(name).lineLimit(1).truncationMode(.middle)
            Text(kind).font(.caption).foregroundColor(.secondary)
            Spacer()
            Image(systemName: "minus.circle").foregroundColor(.secondary)
        }
        .frame(height: 26)
    }
}

struct AddByNameScreen: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add by Name").font(.headline)
            TextField("", text: .constant("partner-sso-demo/billing")).textFieldStyle(.roundedBorder)
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                Text("Repository · partner-sso-demo/billing").font(.callout)
            }
            Text("Use this for organizations or repositories GitHub doesn’t list, for example behind SAML single sign-on. Type an organization login, or owner/name for a repository. Apply checks access.")
                .font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") {}.keyboardShortcut(.cancelAction)
                Button("Add") {}.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 340)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: Render

func render<V: View>(_ view: V, name: String, directory: URL, appearance: NSAppearance.Name) {
    let hosting = NSHostingView(rootView: view)
    hosting.frame = CGRect(origin: .zero, size: hosting.fittingSize)
    let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = hosting
    window.appearance = NSAppearance(named: appearance)
    window.isReleasedWhenClosed = false
    window.setFrameOrigin(CGPoint(x: -10_000, y: -10_000))
    window.orderFrontRegardless()
    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    hosting.layoutSubtreeIfNeeded()
    hosting.wantsLayer = true
    guard let layer = hosting.layer else { return }
    let scale: CGFloat = 2
    let width = Int(hosting.bounds.width * scale), height = Int(hosting.bounds.height * scale)
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    var background = NSColor.windowBackgroundColor.cgColor
    window.appearance?.performAsCurrentDrawingAppearance { background = NSColor.windowBackgroundColor.cgColor }
    context.setFillColor(background)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.scaleBy(x: scale, y: scale)
    if hosting.isFlipped { context.translateBy(x: 0, y: hosting.bounds.height); context.scaleBy(x: 1, y: -1) }
    layer.render(in: context)
    if let image = context.makeImage(), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
        try? png.write(to: directory.appendingPathComponent("\(name).png"))
        print("\(name).png \(Int(hosting.bounds.width))x\(Int(hosting.bounds.height)) pt")
    }
    window.orderOut(nil)
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
for (suffix, appearance) in [("", NSAppearance.Name.aqua), ("-dark", .darkAqua)] {
    render(SettingsScreen(), name: "01-settings-section\(suffix)", directory: output, appearance: appearance)
    render(BrowseScreen(), name: "02-browse-organization\(suffix)", directory: output, appearance: appearance)
    render(OrgAllScreen(), name: "03-all-repositories\(suffix)", directory: output, appearance: appearance)
    render(SearchScreen(), name: "04-search\(suffix)", directory: output, appearance: appearance)
    render(SelectedScreen(), name: "05-selected-review\(suffix)", directory: output, appearance: appearance)
    render(AddByNameScreen(), name: "06-add-by-name\(suffix)", directory: output, appearance: appearance)
    render(StatesScreen(), name: "07-states\(suffix)", directory: output, appearance: appearance)
}
