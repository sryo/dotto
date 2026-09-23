import SwiftUI

/// A borderless button that draws its own label from its hover state, for the one-off controls the design-system
/// styles don't cover (header icons, chips, toggle rows). It brings the pointer cursor while enabled, like every
/// design-system style.
struct HoverAwarePlainButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: (_ isHovered: Bool) -> Label

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            label(isHovered && isEnabled)
        }
        .buttonStyle(.plain)
        .onHover { isHovering in isHovered = isHovering }
        .animation(.easeOut(duration: DesignSystem.Animation.fast), value: isHovered)
        .pointerCursor(isEnabled: isEnabled)
    }
}
