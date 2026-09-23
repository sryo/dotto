import SwiftUI

/// Body text that wraps onto as many lines as it needs instead of truncating inside a fixed-width panel.
struct WrappingText: View {
    let text: String
    var size: CGFloat = 12
    var weight: Font.Weight = .regular
    var color: Color = DesignSystem.Colors.textSecondary

    init(_ text: String, size: CGFloat = 12, weight: Font.Weight = .regular, color: Color = DesignSystem.Colors.textSecondary) {
        self.text = text
        self.size = size
        self.weight = weight
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: weight))
            .foregroundColor(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}
