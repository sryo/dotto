import SwiftUI

/// The small capitalized heading above a group of menu bar panel rows ("PERMISSIONS", "ROUTINES").
struct MenuBarSectionLabel: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundColor(DesignSystem.Colors.textTertiary)
            .padding(.bottom, 4)
    }
}

/// A setting's name with a one-line explanation under it. The name brightens while its row is hovered.
struct MenuBarSettingText: View {
    let title: String
    let explanation: String
    var isHighlighted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isHighlighted ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textSecondary)
            WrappingText(explanation, size: 10, color: DesignSystem.Colors.textTertiary)
        }
    }
}
