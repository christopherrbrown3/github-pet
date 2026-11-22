import GitHubPetCore
import SwiftUI

/// One selected entry as Settings and the sheet's Selected review show it.
struct ScopeEntry: Identifiable, Equatable {
    let id: Int
    let text: String
    let kind: MonitoringTarget.Kind
    let named: Bool
    let problem: String?
    /// True for a format problem (fix the text); false for an Apply finding (access, rename).
    var needsFixing = false

    var owner: String { String(text.split(separator: "/").first ?? Substring(text)) }
    var kindLabel: String {
        (kind == .organization ? "All repositories" : "Repository") + (named ? " · added by name" : "")
    }
    var spoken: String {
        "\(text), \(kindLabel.replacingOccurrences(of: " · ", with: ", "))" + (problem.map { ", error: \($0)" } ?? "")
    }

    /// Entries with a problem first, so they can be found among hundreds; otherwise draft order.
    @MainActor static func entries(_ editor: ScopeEditor) -> [ScopeEntry] {
        let all = editor.draft.rows.map { row -> ScopeEntry in
            let problem = editor.problem(row)
            return ScopeEntry(id: row.id, text: row.text, kind: row.kind, named: row.target.map(editor.namedTargets.contains) ?? false,
                              problem: problem.map { message($0, kind: row.kind) },
                              needsFixing: problem.map { $0 != .unavailable && $0 != .renamed } ?? false)
        }
        return all.filter { $0.problem != nil } + all.filter { $0.problem == nil }
    }

    /// One malformed-input message for both forms, the same in Add by Name and the lists: the
    /// kind of a mistyped entry is a guess.
    static let malformedMessage = "Use an organization login, or owner/name for a repository: letters, digits and hyphens for owners; letters, digits, '.', '-' and '_' for repository names."

    static func message(_ problem: ScopeRowProblem, kind: MonitoringTarget.Kind) -> String {
        problem == .malformed ? malformedMessage : problem.message(for: kind)
    }

    /// The Selected review's banner: format problems need fixing; Apply findings weren't verified.
    static func problemSummary(_ entries: [ScopeEntry]) -> String? {
        let fix = entries.filter { $0.problem != nil && $0.needsFixing }.count
        let unverified = entries.filter { $0.problem != nil && !$0.needsFixing }.count
        var parts: [String] = []
        if fix > 0 { parts.append("\(fix) \(fix == 1 ? "entry needs" : "entries need") fixing.") }
        if unverified > 0 { parts.append("\(unverified) \(unverified == 1 ? "entry" : "entries") could not be verified.") }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " ") + " Remove or correct \(fix + unverified == 1 ? "it" : "them"), then Apply. They're listed first."
    }
}

/// A 20 pt rounded square with a stable hue from the owner login and its white initial.
/// Never an avatar: that would be a request outside gh.
struct Monogram: View {
    let login: String
    var size: CGFloat = 20

    /// FNV-1a: stable across launches (String.hashValue is seeded per process).
    static func hue(_ login: String) -> Double {
        var hash: UInt32 = 2_166_136_261
        for byte in login.lowercased().utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return Double(hash % 360) / 360
    }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
            .fill(Color(hue: Self.hue(login), saturation: 0.55, brightness: 0.72))
            .frame(width: size, height: size)
            .overlay(Text(login.first.map { String($0).uppercased() } ?? "·")
                .font(.system(size: size * 0.55, weight: .semibold)).foregroundStyle(.white))
            .accessibilityHidden(true)
    }
}

enum ScopeDates {
    /// Named relative style; "now" under a minute; absolute month and year after six months.
    static func relative(_ date: Date?, now: Date) -> String {
        guard let date else { return "never pushed" }
        if now.timeIntervalSince(date) < 60 { return "now" }
        if now.timeIntervalSince(date) > 182 * 86_400 {
            let formatter = DateFormatter(); formatter.setLocalizedDateFormatFromTemplate("MMM yyyy")
            return formatter.string(from: date)
        }
        let formatter = RelativeDateTimeFormatter(); formatter.dateTimeStyle = .named; formatter.unitsStyle = .full
        return formatter.localizedString(for: min(date, now), relativeTo: now)
    }
    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

/// A state banner: one combined element for the text, its action button kept separate.
struct ScopeBanner: View {
    enum Tone { case info, warning, error }
    let tone: Tone
    let symbol: String
    let text: String
    var actionTitle: String?
    var actionEnabled = true
    /// A second action, shown before the main one (e.g. Add by Name beside Retry).
    var secondary: (title: String, action: () -> Void)?
    var action: () -> Void = {}

    private var color: Color { tone == .error ? .red : tone == .warning ? .orange : .accentColor }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: {
                Image(systemName: symbol).foregroundStyle(color)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 4)
            if let secondary {
                Button(secondary.title, action: secondary.action).controlSize(.small)
            }
            if let actionTitle {
                Button(actionTitle, action: action).disabled(!actionEnabled).controlSize(.small)
            }
        }
        .font(.callout)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(color.opacity(0.35)))
    }
}

/// Scrolling list of selected entries with no length limit. Lazy rows of a fixed height, so it
/// stays smooth with hundreds of entries and can say exactly how many are hidden below: the
/// bottom edge fades, and a reserved strip under the list counts what is out of view. The strip
/// is there whenever the list overflows, so scrolling never changes the layout.
struct ScrollingEntryList<Row: View>: View {
    let entries: [ScopeEntry]
    let rowHeight: CGFloat
    /// Nil fills the available height; otherwise the list grows to this many rows, then scrolls.
    var maximumVisibleRows: Int?
    @ViewBuilder let row: (ScopeEntry) -> Row

    @State private var offset: CGFloat = 0
    @State private var viewport: CGFloat = 0
    private let space = "scope-entry-list"

    /// Rows whose bottom edge is below the viewport (a half-shown row counts as hidden).
    static func hiddenBelow(count: Int, rowHeight: CGFloat, offset: CGFloat, viewport: CGFloat) -> Int {
        guard viewport > 0, rowHeight > 0 else { return 0 }
        return max(0, count - Int(((max(0, offset) + viewport + 0.5) / rowHeight).rounded(.down)))
    }
    var hiddenBelow: Int { Self.hiddenBelow(count: entries.count, rowHeight: rowHeight, offset: offset, viewport: viewport) }

    var body: some View {
        let below = hiddenBelow, scrolled = offset > 1
        let overflows = viewport > 0 && CGFloat(entries.count) * rowHeight > viewport + 0.5
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(entries) { entry in row(entry).frame(height: rowHeight) }
                }
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: ScopeEntryOffsetKey.self, value: -proxy.frame(in: .named(space)).minY)
                })
            }
            .coordinateSpace(name: space)
            .frame(height: maximumVisibleRows.map { CGFloat(min(entries.count, $0)) * rowHeight })
            .background(GeometryReader { proxy in
                Color.clear.onAppear { viewport = proxy.size.height }.onChange(of: proxy.size.height) { viewport = $0 }
            })
            .onPreferenceChange(ScopeEntryOffsetKey.self) { offset = $0 }
            .mask(LinearGradient(stops: [
                .init(color: scrolled ? .clear : .black, location: 0),
                .init(color: .black, location: scrolled ? 0.08 : 0),
                .init(color: .black, location: below > 0 ? 0.82 : 1),
                .init(color: below > 0 ? .black.opacity(0.15) : .black, location: 1),
            ], startPoint: .top, endPoint: .bottom))
            if overflows || maximumVisibleRows.map({ entries.count > $0 }) == true {
                HStack(spacing: 4) {
                    Image(systemName: below > 0 ? "arrow.down" : "checkmark").accessibilityHidden(true)
                    Text(below > 0 ? "\(below) more below" : "End of list · all \(entries.count) shown")
                }
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: Self.stripHeight)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(below > 0 ? "\(below) more \(below == 1 ? "entry" : "entries") below; scroll to see them"
                                    : "End of list, all \(entries.count) entries shown")
            }
        }
    }

    static var stripHeight: CGFloat { 20 }
}

private struct ScopeEntryOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// One row of the read-only Settings summary and the sheet's Selected review.
struct ScopeEntryRow: View {
    let entry: ScopeEntry
    var remove: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Monogram(login: entry.owner)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.text).lineLimit(1).truncationMode(.middle)
                if let problem = entry.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(entry.kindLabel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(entry.spoken)
            .help(entry.problem ?? "")
            Spacer(minLength: 4)
            if let remove {
                Button(action: remove) { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .help("Remove from the selection")
                    .accessibilityLabel("Remove \(entry.text)")
            }
        }
        .padding(.horizontal, 6)
    }
}

/// Add by Name: for owners GitHub does not list (SSO, outside collaborator, renamed). No
/// network call; Apply checks access. The live line uses the draft's own format rules.
struct AddByNameSheet: View {
    @ObservedObject var editor: ScopeEditor
    let close: () -> Void
    @State private var text: String
    @FocusState private var focused: Bool

    init(editor: ScopeEditor, text: String = "", close: @escaping () -> Void) {
        self.editor = editor; self.close = close
        _text = State(initialValue: text)
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var kind: MonitoringTarget.Kind { ScopeEditor.nameKind(trimmed) }
    private var problem: ScopeRowProblem? { editor.addByNameProblem(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add by Name").font(.headline)
            Text("For organizations or repositories GitHub doesn't list, such as ones behind single sign-on. Apply checks access.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Organization login or owner/name", text: $text, prompt: Text("login or owner/name"))
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(add)
            Group {
                if trimmed.isEmpty {
                    Text("Enter an organization login or a repository as owner/name.").foregroundStyle(.secondary)
                } else if let problem {
                    Label(ScopeEntry.message(problem, kind: kind), systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Label(kind == .organization ? "Organization · \(trimmed) (all its repositories)" : "Repository · \(trimmed)",
                          systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            .font(.caption)
            .accessibilityElement(children: .combine)
            HStack {
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("Add", action: add).keyboardShortcut(.defaultAction).disabled(trimmed.isEmpty || problem != nil)
            }
        }
        .padding(16)
        .frame(width: 400)
        .onAppear { focused = true }
    }

    private func add() {
        guard problem == nil, !trimmed.isEmpty else { return }
        if editor.addByName(trimmed) == nil { close() }
    }
}
