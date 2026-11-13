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

    /// Marker layers, back to front (design spec), each faded in as one layer.
    public enum Layer: String, CaseIterable, Sendable {
        case beaconSweep, smoke, flames, siren
    }

    /// One burst: when it started, and the tier the marker showed before it (nil: none), so only
    /// layers that were not visible fade in and nothing already shown blinks out.
    public struct Burst: Equatable, Sendable {
        public var start: Date
        public var fromTier: Tier?

        public init(start: Date, fromTier: Tier?) {
            self.start = start
            self.fromTier = fromTier
        }
    }

    /// What to draw at an instant: the burst time (nil for the static frame), how far the settle has
    /// crossfaded toward the static frame (1 = static), and each layer's fade-in opacity.
    public struct Phase: Equatable, Sendable {
        public var time: TimeInterval?
        public var staticWeight: Double
        public var fading: Set<Layer>
        public var envelope: Double

        public static let still = Phase(time: nil, staticWeight: 1, fading: [], envelope: 1)

        public func opacity(_ layer: Layer) -> Double { fading.contains(layer) ? envelope : 1 }
    }

    public static func layers(_ tier: Tier?, spec: IncidentMarkerSpec = .standard) -> Set<Layer> {
        guard let tier else { return [] }
        let tierLayers = spec.layers(tier)
        var layers: Set<Layer> = []
        if tierLayers.beaconSweep { layers.insert(.beaconSweep) }
        if tierLayers.siren { layers.insert(.siren) }
        if tierLayers.flames != nil { layers.insert(.flames) }
        if tierLayers.smoke { layers.insert(.smoke) }
        return layers
    }

    /// Length of the animated burst; the rest of the time the marker holds its static frame.
    public static var burstDuration: TimeInterval { IncidentMarkerSpec.standard.timing.burstMs / 1000 }

    /// The burst at `now`. A burst starts with a #11 incident event (a new incident, or a known one
    /// reaching a higher tier), which baseline and reconnect never produce, so those stay static.
    /// Reduce Motion, quiet hours and snooze draw the static frame at once (the marker stays
    /// visible). The first `fadeInMs` fades in, by opacity only, the layers not shown before the
    /// burst; the last `settleMs` crossfades to the static frame.
    public func phase(now: Date, burst: Burst?, reducedMotion: Bool, alertsAllowed: Bool,
                      spec: IncidentMarkerSpec = .standard) -> Phase {
        guard let burst, !reducedMotion, alertsAllowed else { return .still }
        let elapsed = now.timeIntervalSince(burst.start)
        let duration = spec.timing.burstMs / 1000, fadeIn = spec.timing.fadeInMs / 1000, settle = spec.timing.settleMs / 1000
        guard elapsed >= 0, elapsed < duration else { return .still }
        let envelope = elapsed < fadeIn ? Self.ease(elapsed / fadeIn, spec.timing.fadeInCurve) : 1
        let weight = elapsed > duration - settle ? (elapsed - (duration - settle)) / settle : 0
        let fading = Self.layers(tier, spec: spec).subtracting(Self.layers(burst.fromTier, spec: spec))
        return Phase(time: elapsed, staticWeight: min(max(weight, 0), 1), fading: fading, envelope: envelope)
    }

    /// CSS-style cubic Bezier ease (x1, y1, x2, y2): y for x in 0...1.
    public static func ease(_ x: Double, _ c: [Double]) -> Double {
        guard c.count == 4 else { return x }
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        func bezier(_ s: Double, _ p1: Double, _ p2: Double) -> Double {
            3 * (1 - s) * (1 - s) * s * p1 + 3 * (1 - s) * s * s * p2 + s * s * s
        }
        var low = 0.0, high = 1.0
        for _ in 0..<40 {
            let mid = (low + high) / 2
            if bezier(mid, c[0], c[2]) < x { low = mid } else { high = mid }
        }
        return bezier((low + high) / 2, c[1], c[3])
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

    /// Design keep-out: the top band of the 256-unit art canvas.
    public static var keepOutCanvasTop: CGFloat { CGFloat(IncidentMarkerSpec.standard.keepOut.topBandMaxY) }

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
