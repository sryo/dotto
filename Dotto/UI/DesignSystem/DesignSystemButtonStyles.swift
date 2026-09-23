import SwiftUI

/// The hover, press, pointer-cursor and disabled treatment every design-system button shares. The style reads
/// `isEnabled` itself, so a disabled button dims and keeps the arrow cursor without any modifier at the call site.
private struct DSButtonInteraction<StyledLabel: View>: View {
    let configuration: ButtonStyleConfiguration
    var pressedScale: CGFloat = 0.97
    @ViewBuilder let styledLabel: (_ isHovered: Bool, _ isPressed: Bool) -> StyledLabel

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        styledLabel(isHovered && isEnabled, configuration.isPressed)
            .scaleEffect(configuration.isPressed ? pressedScale : 1)
            .opacity(isEnabled ? 1 : 0.5)
            .animation(.easeOut(duration: DesignSystem.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DesignSystem.Animation.fast), value: isHovered)
            .onHover { isHovering in isHovered = isHovering }
            .pointerCursor(isEnabled: isEnabled)
    }
}

/// The main call to action, one per view: an accent capsule that darkens and glows softly on hover.
struct DSPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        DSButtonInteraction(configuration: configuration) { isHovered, isPressed in
            configuration.label
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(DesignSystem.Colors.textOnAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Capsule().fill(Self.fillColor(isHovered: isHovered, isPressed: isPressed)))
                .shadow(color: DesignSystem.Colors.accent.opacity(isHovered ? 0.25 : 0), radius: isHovered ? 12 : 0)
        }
    }

    private static func fillColor(isHovered: Bool, isPressed: Bool) -> Color {
        if isPressed { return DesignSystem.Colors.accentHover.blendedWithWhite(fraction: 0.12) }
        return isHovered ? DesignSystem.Colors.accentHover : DesignSystem.Colors.accent
    }
}

/// The capsule buttons below the primary one. Secondary and outlined fill the row's width; destructive (Stop) stays
/// compact so it sits beside them.
struct DSCapsuleButtonStyle: ButtonStyle {
    enum Palette { case secondary, outlined, destructive }

    let palette: Palette

    func makeBody(configuration: Configuration) -> some View {
        DSButtonInteraction(configuration: configuration) { isHovered, isPressed in
            let isHighlighted = isHovered || isPressed
            configuration.label
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(textColor(isHighlighted: isHighlighted))
                .frame(maxWidth: palette == .destructive ? nil : .infinity)
                .padding(.vertical, palette == .destructive ? 10 : 12)
                .padding(.horizontal, palette == .destructive ? 16 : 0)
                .background(Capsule().fill(fillColor(isHovered: isHovered, isPressed: isPressed)))
                .overlay(Capsule().stroke(borderColor(isHighlighted: isHighlighted), lineWidth: 1))
        }
    }

    private func textColor(isHighlighted: Bool) -> Color {
        guard palette == .destructive else { return DesignSystem.Colors.textPrimary }
        return isHighlighted ? .white : DesignSystem.Colors.destructiveText
    }

    private func fillColor(isHovered: Bool, isPressed: Bool) -> Color {
        switch palette {
        case .secondary:
            return isPressed ? DesignSystem.Colors.surface4 : (isHovered ? DesignSystem.Colors.surface3 : DesignSystem.Colors.surface2)
        case .outlined:
            return isPressed ? DesignSystem.Colors.surface3 : (isHovered ? DesignSystem.Colors.surface2 : DesignSystem.Colors.surface1)
        case .destructive:
            return DesignSystem.Colors.destructive.opacity(isPressed ? 0.40 : (isHovered ? 0.30 : 0.10))
        }
    }

    private func borderColor(isHighlighted: Bool) -> Color {
        switch palette {
        case .secondary:
            return .clear
        case .outlined:
            return isHighlighted ? DesignSystem.Colors.borderStrong : DesignSystem.Colors.borderSubtle
        case .destructive:
            return DesignSystem.Colors.destructive.opacity(isHighlighted ? 0.40 : 0.15)
        }
    }
}

/// The lowest-emphasis button: small text, no background in any state, only the color changes.
struct DSTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        DSButtonInteraction(configuration: configuration, pressedScale: 1) { isHovered, isPressed in
            configuration.label
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isHovered || isPressed ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textTertiary)
        }
    }
}

/// A compact circular icon button for a destructive action (delete): quiet at rest, red on hover.
struct DSDestructiveIconButtonStyle: ButtonStyle {
    let size: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        DSButtonInteraction(configuration: configuration, pressedScale: 0.93) { isHovered, isPressed in
            let isHighlighted = isHovered || isPressed
            configuration.label
                .font(.system(size: size * 0.43, weight: .semibold))
                .foregroundColor(isHighlighted ? .white : DesignSystem.Colors.textSecondary)
                .frame(width: size, height: size)
                .background(Circle().fill(isPressed ? DesignSystem.Colors.destructive.opacity(0.40)
                                          : (isHovered ? DesignSystem.Colors.destructive.opacity(0.30) : DesignSystem.Colors.surface2)))
                .overlay(Circle().stroke(isHighlighted ? DesignSystem.Colors.destructive.opacity(0.30)
                                         : DesignSystem.Colors.borderSubtle.opacity(0.5), lineWidth: 1))
                .contentShape(Circle())
        }
    }
}

extension View {
    func dsPrimaryButtonStyle() -> some View {
        buttonStyle(DSPrimaryButtonStyle())
    }

    func dsSecondaryButtonStyle() -> some View {
        buttonStyle(DSCapsuleButtonStyle(palette: .secondary))
    }

    func dsOutlinedButtonStyle() -> some View {
        buttonStyle(DSCapsuleButtonStyle(palette: .outlined))
    }

    func dsDestructiveButtonStyle() -> some View {
        buttonStyle(DSCapsuleButtonStyle(palette: .destructive))
    }

    func dsTextButtonStyle() -> some View {
        buttonStyle(DSTextButtonStyle())
    }

    func dsDestructiveIconButtonStyle(size: CGFloat) -> some View {
        buttonStyle(DSDestructiveIconButtonStyle(size: size))
    }
}
