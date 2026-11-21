import Foundation

/// WCAG 2.x relative luminance and contrast ratio, for 8-bit sRGB channels.
public enum WCAGContrast {
    public static let normalTextAA = 4.5

    public static func luminance(_ red: Double, _ green: Double, _ blue: Double) -> Double {
        func linear(_ channel: Double) -> Double {
            let c = channel / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    public static func ratio(_ a: Double, _ b: Double) -> Double {
        (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Contrast of a gray foreground (0...255) drawn at `alpha` over a gray background.
    public static func grayRatio(foreground: Double, alpha: Double, background: Double) -> Double {
        let blended = background + (foreground - background) * alpha
        return ratio(luminance(blended, blended, blended), luminance(background, background, background))
    }
}

/// How last-known Inbox rows (stale, partial, error) are dimmed (#104). Text keeps its contrast:
/// instead of fading the whole list (which put secondary text near 2:1), the text colour is the
/// system label colour at these alphas, which stay at or above WCAG AA 4.5:1 on the window
/// backgrounds. With Increase Contrast on, nothing is dimmed; the "Showing last known items"
/// line still says the data is old.
public enum InboxDimming {
    public enum Role: Sendable { case title, context, glyph }

    /// macOS `labelColor` is black (light) or white (dark) at this alpha.
    public static let systemLabelAlpha = 0.85

    public static func alpha(_ role: Role, dimmed: Bool, increasedContrast: Bool) -> Double {
        guard dimmed, !increasedContrast else { return 1 }
        switch role {
        case .title: return 0.75
        case .context: return 0.7
        case .glyph: return 0.6
        }
    }

    /// Contrast of dimmed text against a gray window background, from the label colour's own alpha.
    public static func textRatio(_ role: Role, labelGray: Double, backgroundGray: Double,
                                 increasedContrast: Bool = false) -> Double {
        let alpha = systemLabelAlpha * alpha(role, dimmed: true, increasedContrast: increasedContrast)
        return WCAGContrast.grayRatio(foreground: labelGray, alpha: alpha, background: backgroundGray)
    }
}

/// Row heights that follow the text size (#104). `textScale` is 1 at the default size and grows
/// with Dynamic Type; the list scrolls once its natural height passes the cap, so larger text never
/// pushes a popover or window off screen.
public enum InboxRowMetrics {
    public static let rowHeight = 40.0
    public static let sectionHeaderHeight = 26.0
    public static let maxListHeight = 340.0

    public static func naturalListHeight(rows: Int, sections: Int, textScale: Double = 1) -> Double {
        (Double(rows) * rowHeight + Double(sections) * sectionHeaderHeight) * max(1, textScale)
    }

    public static func scrolls(rows: Int, sections: Int, textScale: Double = 1) -> Bool {
        naturalListHeight(rows: rows, sections: sections, textScale: textScale) > maxListHeight
    }
}
