import CoreGraphics
import Foundation

/// The incident marker behind the mascot (#37): shown only for a fresh, confirmed, unresolved
/// GitHub service incident. Loading, stale and failed status never show it; they keep their own
/// status text. Separate from the actionable count, which never includes incidents.
public struct IncidentMarker: Equatable, Sendable {
    /// From the most severe impact: `none`/`minor` → minor, `major` → major, `critical` → critical
    /// (design spec, docs/design/incidents). Maintenance is never a marker.
    public enum Tier: String, Comparable, Equatable, Sendable {
        case minor
        case major
        case critical

        init(_ impact: IncidentImpact) {
            switch impact {
            case .critical: self = .critical
            case .major: self = .major
            default: self = .minor
            }
        }

        public static func < (lhs: Tier, rhs: Tier) -> Bool {
            let order: [Tier] = [.minor, .major, .critical]
            return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
        }
    }

    public var tier: Tier
    /// Number of active incidents (at least 1).
    public var count: Int
    /// The most severe, then newest, incident: the one named in the hover summary.
    public var lead: ServiceIncident

    public init(tier: Tier, count: Int, lead: ServiceIncident) {
        self.tier = tier
        self.count = max(1, count)
        self.lead = lead
    }

    /// Longest incident name shown in the one-line hover summary.
    public static let maxNameLength = 60

    public static func current(state: ServiceStatusState, incidents: [ServiceIncident]) -> IncidentMarker? {
        guard state == .incidents else { return nil }
        let active = StatusPageDecoder.dedupe(incidents.filter { $0.status.isUnresolvedIncident && $0.impact != .maintenance })
        guard let lead = active.first else { return nil }
        return IncidentMarker(tier: Tier(lead.impact), count: active.count, lead: lead)
    }

    /// Length of the animated burst; the rest of the time the marker holds its static frame.
    public static let burstDuration: TimeInterval = 6

    /// Seconds into the marker's burst, or nil to draw the static frame. A burst starts with a #11
    /// incident event (a new incident, or escalation to major/critical), which baseline and
    /// reconnect never produce, so those stay static. Reduce Motion, quiet hours and snooze always
    /// draw the static frame; the marker itself stays visible.
    public static func burstElapsed(now: Date, burstStart: Date?, reducedMotion: Bool, alertsAllowed: Bool) -> TimeInterval? {
        guard let burstStart, !reducedMotion, alertsAllowed else { return nil }
        let elapsed = now.timeIntervalSince(burstStart)
        return elapsed >= 0 && elapsed < burstDuration ? elapsed : nil
    }

    /// Hover top line. Incident names are public status-page text, so privacy mode keeps them.
    public var hoverLine: String {
        let name = lead.name.count > Self.maxNameLength
            ? String(lead.name.prefix(Self.maxNameLength - 1)) + "…" : lead.name
        let demo = lead.isDemo ? "\(PrivacyText.demoLabel) " : ""
        return count == 1 ? "\(demo)GitHub incident: \(name)" : "\(demo)GitHub incidents: \(name) (+\(count - 1) more)"
    }

    /// Spoken clause, e.g. "1 active GitHub incident".
    public var accessibilityClause: String {
        count == 1 ? "1 active GitHub incident" : "\(count) active GitHub incidents"
    }

    /// Full hover summary with the incident line on top.
    public static func hoverLines(_ lines: [String], marker: IncidentMarker?) -> [String] {
        guard let marker else { return lines }
        return [marker.hoverLine] + lines
    }

    /// Compact hover stays at two lines (#27): the incident line, then the count's quality, with
    /// the Demo tag folded into it.
    public static func compactHoverLines(dataState: DataState, items: [InboxItem], unseenCount: Int, demo: Bool,
                                         marker: IncidentMarker?) -> [String] {
        let lines = PrivacyText.compactSummary(dataState: dataState, items: items, unseenCount: unseenCount, demo: demo)
        guard let marker else { return lines }
        let quality = demo ? "\(PrivacyText.demoLabel) · \(lines.last ?? "")" : (lines.first ?? "")
        return [marker.hoverLine, quality]
    }

    /// Menu-bar and mascot label: "GitHub Pet, 3 items, 1 active GitHub incident[, needs attention]".
    public static func statusLabel(dataState: DataState, count: Int, demo: Bool, needsAttention: Bool,
                                   marker: IncidentMarker?) -> String {
        var label = AccessibilityText.statusLabel(dataState: dataState, count: count, demo: demo, needsAttention: false)
        if let marker { label += ", " + marker.accessibilityClause }
        if needsAttention { label += ", needs attention" }
        return label
    }

    /// Design keep-out: the top 64 units of the 256-unit art canvas.
    public static let keepOutCanvasTop: CGFloat = 64

    /// The marker's slot in panel coordinates (origin bottom-left): the art square below the design
    /// keep-out and below every place a label can be (DEMO, and the count down to its lowest
    /// tracking position) less the layout's minimum gap. Every marker layer is clipped to it and
    /// drawn behind the art, so it never covers the badge, quality or DEMO.
    public static func frame(in layout: MascotLayout) -> CGRect {
        let art = layout.artFrame
        let top = min(art.maxY - keepOutCanvasTop * layout.artSide / 256, layout.tagBand.minY - layout.minimumGap)
        return CGRect(x: art.minX, y: art.minY, width: art.width, height: max(0, top - art.minY))
    }
}
