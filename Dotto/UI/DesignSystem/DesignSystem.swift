import SwiftUI
import AppKit

/// The design tokens every Dotto panel draws with: a blue accent on dark surfaces, corner radii and animation timing.
/// The button styles built from them live in DesignSystemButtonStyles.swift.
enum DesignSystem {

    // MARK: - Color Tokens

    enum Colors {

        // ── Surfaces, from deepest to most elevated; higher surfaces are lighter ──

        /// Panel fill.
        static let background = Color(hex: "#101211")
        static let surface1 = Color(hex: "#171918")
        /// Cards and fields inside a panel, and resting buttons.
        static let surface2 = Color(hex: "#202221")
        /// Hovered controls.
        static let surface3 = Color(hex: "#272A29")
        /// Pressed controls.
        static let surface4 = Color(hex: "#2E3130")

        // ── Borders ──────────────────────────────────────────────────

        /// Panel and card outlines, dividers.
        static let borderSubtle = Color(hex: "#373B39")
        /// Hovered outlines.
        static let borderStrong = Color(hex: "#444947")

        // ── Text ─────────────────────────────────────────────────────

        /// Titles and body text.
        static let textPrimary = Color(hex: "#ECEEED")
        /// Descriptions and muted labels.
        static let textSecondary = Color(hex: "#ADB5B2")
        /// Section labels, hints and counts.
        static let textTertiary = Color(hex: "#6B736F")

        /// Text on the accent fill, like the primary button label.
        static let textOnAccent: Color = .white

        // ── Accent (Tailwind blue) ───────────────────────────────────

        /// Accent fill for solid buttons: Blue 600, ~5.1:1 contrast with white text (WCAG AA).
        static let accent = Color(hex: "#2563eb")

        /// Hover darkens to Blue 700, ~6.5:1 contrast with white text.
        static let accentHover = Color(hex: "#1d4ed8")

        /// Blue 400: accent-colored text and icons on dark backgrounds.
        static let accentText = Color(hex: "#60a5fa")

        /// A faint Blue 500 tint behind the current checklist item.
        static let accentSubtle = Color(hex: "#3b82f6").opacity(0.10)

        // ── Semantic Colors ──────────────────────────────────────────

        /// Stop, delete, failures, and Dotto's cursor while it is stuck.
        static let destructive = Color(hex: "#E5484D")        // Radix Red 9

        /// Brighter, for red text on dark backgrounds.
        static let destructiveText = Color(hex: "#FF6369")    // Radix Red 11

        /// Completed items and granted permissions, distinct from the blue accent.
        static let success = Color(hex: "#34D399")      // Tailwind Emerald 400

        /// Confirmations, pauses and configuration problems.
        static let warning = Color(hex: "#FFB224")            // Radix Amber 9

        /// For amber text on dark backgrounds.
        static let warningText = Color(hex: "#F1A10D")        // Radix Amber 11
    }

    // MARK: - Corner Radii

    enum CornerRadius {
        /// Rows, fields and small controls.
        static let medium: CGFloat = 8
        /// Cards inside a panel.
        static let large: CGFloat = 10
        /// Panels.
        static let extraLarge: CGFloat = 12
    }

    // MARK: - Animation Durations

    enum Animation {
        /// Hover and press feedback.
        static let fast: Double = 0.15
        /// Scrolling to the current item.
        static let normal: Double = 0.25
    }
}

extension Color {
    /// Create a Color from a hex string like "#FF5733" or "FF5733".
    init(hex: String) {
        let hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")

        var rgbValue: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&rgbValue)

        let red = Double((rgbValue & 0xFF0000) >> 16) / 255.0
        let green = Double((rgbValue & 0x00FF00) >> 8) / 255.0
        let blue = Double(rgbValue & 0x0000FF) / 255.0

        self.init(red: red, green: green, blue: blue)
    }

    /// Returns a lighter version of this color by blending toward white.
    /// `fraction` is 0.0 (no change) to 1.0 (pure white).
    func blendedWithWhite(fraction: Double) -> Color {
        guard let nsColor = NSColor(self).usingColorSpace(.sRGB) else { return self }

        let red = nsColor.redComponent + (1.0 - nsColor.redComponent) * fraction
        let green = nsColor.greenComponent + (1.0 - nsColor.greenComponent) * fraction
        let blue = nsColor.blueComponent + (1.0 - nsColor.blueComponent) * fraction

        return Color(red: red, green: green, blue: blue)
    }
}
