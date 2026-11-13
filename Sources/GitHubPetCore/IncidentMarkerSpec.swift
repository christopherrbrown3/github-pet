import Foundation

/// Design's incident-marker specification (#37, docs/design/incidents/incident-marker.json), the
/// subset the native drawing uses. Values are transcribed into `standard`; a unit test decodes the
/// canonical json into this type and fails if they drift. Units are the 256-unit art canvas (origin
/// top-left of the art square, y down) unless a name says points.
public struct IncidentMarkerSpec: Decodable, Equatable, Sendable {
    public struct KeepOut: Decodable, Equatable, Sendable {
        public var topBandMaxY: Double
        public var labelMarginPt: Double
    }

    public struct TierLayers: Decodable, Equatable, Sendable {
        public var beaconSweep: Bool
        public var siren: Bool
        /// "flames.major" or "flames.critical"; nil for no flames.
        public var flames: String?
        public var smoke: Bool
    }

    public struct Siren: Decodable, Equatable, Sendable {
        public struct Base: Decodable, Equatable, Sendable { public var rect: [Double]; public var cornerRadius: Double }
        public struct Band: Decodable, Equatable, Sendable { public var rect: [Double] }
        public struct Dome: Decodable, Equatable, Sendable {
            public var rect: [Double]
            public var topRadius: Double
            public var band: Band
        }
        public struct Ellipse: Decodable, Equatable, Sendable { public var cx, cy, rx, ry: Double }
        public struct Gloss: Decodable, Equatable, Sendable { public var ellipse: Ellipse }
        public struct Outline: Decodable, Equatable, Sendable { public var widthUnits, minWidthPt: Double }
        public struct Glow: Decodable, Equatable, Sendable {
            public var center: [Double]
            public var radius, alpha: Double
        }
        public var base: Base
        public var dome: Dome
        public var gloss: Gloss
        public var outline: Outline
        public var glow: Glow
    }

    public struct BeaconSweep: Decodable, Equatable, Sendable {
        public var center: [Double]
        public var radius, widthDeg, periodMs, edgeFeatherDeg, alpha: Double
    }

    public struct Tongue: Decodable, Equatable, Sendable {
        public var cx, halfWidth, height, phase: Double
    }

    public struct Flames: Decodable, Equatable, Sendable {
        public struct Nested: Decodable, Equatable, Sendable {
            public var token: String
            public var width, height: Double
        }
        public struct Rim: Decodable, Equatable, Sendable { public var token: String; public var widthPt: Double }
        public struct Shape: Decodable, Equatable, Sendable {
            public var leftControl1, leftControl2: [Double]
            public var tipLeanFactor: Double
        }
        public struct Wave: Decodable, Equatable, Sendable { public var periodS, amp, phaseMul: Double }
        /// Highest a flame tip may reach (smallest y) per tier, at any flicker.
        public struct MaxTip: Decodable, Equatable, Sendable { public var majorMinY, criticalMinY: Double }
        public struct Flicker: Decodable, Equatable, Sendable {
            public var heightBase, heightAmp, waveOffset: Double
            public var waves: [Wave]
            public var leanUnits, leanPeriodS: Double
        }
        public var baseY: Double
        public var nestedScales: [Nested]
        public var rim: Rim
        public var shape: Shape
        public var major: [Tongue]
        public var critical: [Tongue]
        public var flicker: Flicker
        public var maxTip: MaxTip
    }

    public struct Smoke: Decodable, Equatable, Sendable {
        public struct Emitter: Decodable, Equatable, Sendable { public var x, y, dx, dy, phase: Double }
        public struct Curve: Decodable, Equatable, Sendable { public var motion: [Double] }
        public struct Puff: Decodable, Equatable, Sendable { public var cx, cy, r: Double }
        public struct Lobe: Decodable, Equatable, Sendable { public var dx, dy, rScale: Double }
        public var color: String
        public var emitters: [Emitter]
        public var lifeMs: Double
        public var countPerEmitter: Int
        public var staggerMs: Double
        public var radius: [Double]
        public var curve: Curve
        public var `static`: [Puff]
        public var puffCluster: [Lobe]
        public var softEdgeStart: Double
        public var alphaScale: [Double]
    }

    public struct SizeOverride: Decodable, Equatable, Sendable {
        public var flamesMajor: [Tongue]
        public var flamesCritical: [Tongue]
        public var nestedScaleTokens: [String]
        public var smokeMinRadius: Double
        public var smokeCountPerEmitter: Int

        enum CodingKeys: String, CodingKey {
            case flamesMajor = "flames.major", flamesCritical = "flames.critical"
            case nestedScaleTokens, smokeMinRadius, smokeCountPerEmitter
        }
    }

    public struct Timing: Decodable, Equatable, Sendable {
        public var burstMs, fadeInMs, settleMs: Double
        public var fadeInCurve: [Double]
    }

    public struct Static: Decodable, Equatable, Sendable {
        public var beaconAngleDeg, beaconAlpha, flameHeightFactor, flameLean, smokeAlphaScale: Double
        public var sirenGlow: Bool
    }

    public struct Token: Decodable, Equatable, Sendable {
        public var hex: String
        public var alpha: Double

        /// sRGB components 0...1, or nil for a malformed hex.
        public var rgb: (red: Double, green: Double, blue: Double)? {
            guard hex.count == 7, hex.first == "#", let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
            return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
        }
    }

    public struct Palette: Decodable, Equatable, Sendable {
        public var light: [String: Token]
        public var dark: [String: Token]
    }

    public var keepOut: KeepOut
    public var tiers: [String: TierLayers]
    public var siren: Siren
    public var beaconSweep: BeaconSweep
    public var flames: Flames
    public var smoke: Smoke
    public var sizeOverrides: [String: SizeOverride]
    public var timing: Timing
    public var `static`: Static
    public var palette: Palette

    public func layers(_ tier: IncidentMarker.Tier) -> TierLayers {
        tiers[tier.rawValue] ?? TierLayers(beaconSweep: true, siren: true, flames: nil, smoke: false)
    }

    /// The 64 pt override applies to art below 96 pt (nearer 64 than 128).
    public func sizeOverride(artSide: Double) -> SizeOverride? {
        artSide < 96 ? sizeOverrides["64"] : nil
    }

    public func tongues(_ tier: IncidentMarker.Tier, artSide: Double) -> [Tongue] {
        let override = sizeOverride(artSide: artSide)
        switch layers(tier).flames {
        case "flames.major": return override?.flamesMajor ?? flames.major
        case "flames.critical": return override?.flamesCritical ?? flames.critical
        default: return []
        }
    }
}

extension IncidentMarkerSpec {
    // Transcribed from docs/design/incidents/incident-marker.json at e0ace80 (PR #38).
    public static let standard = IncidentMarkerSpec(
        keepOut: KeepOut(topBandMaxY: 64, labelMarginPt: 2),
        tiers: [
            "minor": TierLayers(beaconSweep: true, siren: true, flames: nil, smoke: false),
            "major": TierLayers(beaconSweep: true, siren: true, flames: "flames.major", smoke: false),
            "critical": TierLayers(beaconSweep: true, siren: true, flames: "flames.critical", smoke: true),
        ],
        siren: Siren(
            base: .init(rect: [10, 236, 36, 12], cornerRadius: 3),
            dome: .init(rect: [14, 202, 28, 34], topRadius: 14, band: .init(rect: [14, 226, 28, 4])),
            gloss: .init(ellipse: .init(cx: 22, cy: 214, rx: 3.5, ry: 7)),
            outline: .init(widthUnits: 2.5, minWidthPt: 1),
            glow: .init(center: [28, 214], radius: 34, alpha: 0.6)),
        beaconSweep: BeaconSweep(center: [28, 214], radius: 120, widthDeg: 36, periodMs: 1200, edgeFeatherDeg: 8,
                                 alpha: 0.42),
        flames: Flames(
            baseY: 246,
            nestedScales: [.init(token: "incident.flame.outer", width: 1.0, height: 1.0),
                           .init(token: "incident.flame.mid", width: 0.7, height: 0.72),
                           .init(token: "incident.flame.core", width: 0.45, height: 0.45)],
            rim: .init(token: "incident.flame.rim", widthPt: 1),
            shape: .init(leftControl1: [-1.0, 0.55], leftControl2: [-0.15, 0.85], tipLeanFactor: 0.5),
            major: [.init(cx: 24, halfWidth: 22, height: 96, phase: 0.0), .init(cx: 54, halfWidth: 18, height: 70, phase: 0.37),
                    .init(cx: 98, halfWidth: 26, height: 60, phase: 0.71), .init(cx: 158, halfWidth: 26, height: 60, phase: 0.19),
                    .init(cx: 202, halfWidth: 18, height: 74, phase: 0.58), .init(cx: 232, halfWidth: 22, height: 104, phase: 0.83)],
            critical: [.init(cx: 24, halfWidth: 24, height: 150, phase: 0.0), .init(cx: 54, halfWidth: 20, height: 110, phase: 0.37),
                       .init(cx: 98, halfWidth: 28, height: 90, phase: 0.71), .init(cx: 158, halfWidth: 28, height: 90, phase: 0.19),
                       .init(cx: 202, halfWidth: 20, height: 116, phase: 0.58), .init(cx: 232, halfWidth: 24, height: 158, phase: 0.83)],
            flicker: .init(heightBase: 0.86, heightAmp: 0.14, waveOffset: 0.5,
                           waves: [.init(periodS: 0.42, amp: 0.35, phaseMul: 1), .init(periodS: 0.61, amp: 0.15, phaseMul: 2)],
                           leanUnits: 6, leanPeriodS: 0.9),
            maxTip: .init(majorMinY: 142, criticalMinY: 88)),
        smoke: Smoke(
            color: "incident.smoke",
            emitters: [.init(x: 34, y: 160, dx: -10, dy: -66, phase: 0.0), .init(x: 222, y: 160, dx: 10, dy: -66, phase: 0.5)],
            lifeMs: 2400, countPerEmitter: 4, staggerMs: 600, radius: [10, 24],
            curve: .init(motion: [0.2, 0.8, 0.2, 1]),
            static: [.init(cx: 34, cy: 130, r: 17), .init(cx: 24, cy: 100, r: 20),
                     .init(cx: 222, cy: 130, r: 17), .init(cx: 232, cy: 100, r: 20)],
            puffCluster: [.init(dx: 0, dy: 0, rScale: 1.0), .init(dx: -0.55, dy: 0.3, rScale: 0.72),
                          .init(dx: 0.5, dy: 0.35, rScale: 0.66)],
            softEdgeStart: 0.55, alphaScale: [1.0, 0.0]),
        sizeOverrides: [
            "64": SizeOverride(
                flamesMajor: [.init(cx: 18, halfWidth: 30, height: 100, phase: 0.0),
                              .init(cx: 128, halfWidth: 44, height: 64, phase: 0.45),
                              .init(cx: 238, halfWidth: 30, height: 104, phase: 0.83)],
                flamesCritical: [.init(cx: 18, halfWidth: 32, height: 150, phase: 0.0),
                                 .init(cx: 128, halfWidth: 46, height: 92, phase: 0.45),
                                 .init(cx: 238, halfWidth: 32, height: 158, phase: 0.83)],
                nestedScaleTokens: ["incident.flame.outer", "incident.flame.core"],
                smokeMinRadius: 12, smokeCountPerEmitter: 3),
        ],
        timing: Timing(burstMs: 6000, fadeInMs: 300, settleMs: 600, fadeInCurve: [0.2, 0.8, 0.2, 1]),
        static: Static(beaconAngleDeg: -100, beaconAlpha: 0.34, flameHeightFactor: 0.93, flameLean: 0,
                       smokeAlphaScale: 0.8, sirenGlow: true),
        palette: Palette(
            light: ["incident.flame.outer": .init(hex: "#E5482B", alpha: 1.0), "incident.flame.mid": .init(hex: "#FF8A00", alpha: 1.0),
                    "incident.flame.core": .init(hex: "#FFD23F", alpha: 1.0), "incident.flame.rim": .init(hex: "#B3261E", alpha: 1.0),
                    "incident.smoke": .init(hex: "#5B5F66", alpha: 0.7), "incident.siren.dome": .init(hex: "#FF5A4E", alpha: 1.0),
                    "incident.siren.domeShade": .init(hex: "#B3261E", alpha: 1.0), "incident.siren.base": .init(hex: "#3A2A2A", alpha: 1.0),
                    "incident.siren.outline": .init(hex: "#2B1B1B", alpha: 1.0), "incident.siren.gloss": .init(hex: "#FFFFFF", alpha: 0.8),
                    "incident.beacon": .init(hex: "#FF3B30", alpha: 1.0)],
            dark: ["incident.flame.outer": .init(hex: "#F05A3C", alpha: 1.0), "incident.flame.mid": .init(hex: "#FF9A1F", alpha: 1.0),
                   "incident.flame.core": .init(hex: "#FFE066", alpha: 1.0), "incident.flame.rim": .init(hex: "#8F1D16", alpha: 1.0),
                   "incident.smoke": .init(hex: "#C9CDD3", alpha: 0.55), "incident.siren.dome": .init(hex: "#FF6B5F", alpha: 1.0),
                   "incident.siren.domeShade": .init(hex: "#C2352A", alpha: 1.0), "incident.siren.base": .init(hex: "#5A4646", alpha: 1.0),
                   "incident.siren.outline": .init(hex: "#140B0B", alpha: 1.0), "incident.siren.gloss": .init(hex: "#FFFFFF", alpha: 0.85),
                   "incident.beacon": .init(hex: "#FF5248", alpha: 1.0)]))
}
