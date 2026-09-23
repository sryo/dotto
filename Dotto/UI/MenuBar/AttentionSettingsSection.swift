import SwiftUI

/// The menu bar panel's settings for how Dotto calls the user over without taking focus, and where the live view
/// (with its docked decision pill) sits on screen.
struct AttentionSettingsSection: View {
    @ObservedObject var taskSessionController: TaskSessionController

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            MenuBarSectionLabel(title: "When Dotto needs you")

            MenuBarSettingToggleRow(
                title: "Play a sound",
                explanation: "A soft chime when Dotto asks or gets stuck",
                isOn: taskSessionController.attentionPreferences.soundEnabled,
                onChange: { isOn in taskSessionController.updateAttentionPreferences { $0.soundEnabled = isOn } })
            MenuBarSettingToggleRow(
                title: "Pulse the menu bar icon",
                explanation: "Until you answer",
                isOn: taskSessionController.attentionPreferences.menuBarPulseEnabled,
                onChange: { isOn in taskSessionController.updateAttentionPreferences { $0.menuBarPulseEnabled = isOn } })
            MenuBarSettingToggleRow(
                title: "System notifications",
                explanation: "With Allow and Skip buttons; only while you're in another app",
                isOn: taskSessionController.attentionPreferences.notificationsEnabled,
                onChange: { isOn in taskSessionController.updateAttentionPreferences { $0.notificationsEnabled = isOn } })

            HStack(spacing: 8) {
                MenuBarSettingText(title: "Live view corner", explanation: "Where Dotto shows its work when the app is covered")
                Spacer(minLength: 4)
                HStack(spacing: 4) {
                    ForEach(ScreenCorner.allCases, id: \.self) { screenCorner in
                        LiveViewCornerButton(
                            screenCorner: screenCorner,
                            isSelected: taskSessionController.liveViewCorner == screenCorner,
                            accentColor: taskSessionController.cursorStyleConfiguration.taskAccentColor,
                            onSelect: { taskSessionController.updateLiveViewCorner(screenCorner) })
                    }
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 6)
        }
    }
}

/// A setting row that toggles when clicked anywhere, with the switch mirroring its state.
struct MenuBarSettingToggleRow: View {
    let title: String
    let explanation: String
    let isOn: Bool
    let onChange: (Bool) -> Void

    var body: some View {
        HoverAwarePlainButton(action: { onChange(!isOn) }) { isHovered in
            HStack(spacing: 8) {
                MenuBarSettingText(title: title, explanation: explanation, isHighlighted: isHovered)
                Spacer(minLength: 4)
                Toggle("", isOn: Binding(get: { isOn }, set: { onChange($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .allowsHitTesting(false)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.medium, style: .continuous)
                    .fill(isHovered ? DesignSystem.Colors.surface3 : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isButton)
    }
}

/// A tiny screen with a dot in one corner, like the cursor lab's corner picker.
private struct LiveViewCornerButton: View {
    let screenCorner: ScreenCorner
    let isSelected: Bool
    let accentColor: Color
    let onSelect: () -> Void

    var body: some View {
        HoverAwarePlainButton(action: onSelect) { isHovered in
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isHovered ? DesignSystem.Colors.surface3 : DesignSystem.Colors.surface2)
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(isSelected ? accentColor : DesignSystem.Colors.borderSubtle, lineWidth: isSelected ? 2 : 1)
                )
                .overlay(alignment: screenCorner.alignment) {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(isSelected ? accentColor : DesignSystem.Colors.textTertiary)
                        .frame(width: 7, height: 5)
                        .padding(4)
                }
                .frame(width: 28, height: 22)
        }
        .nativeTooltip(screenCorner.userFacingName)
        .accessibilityLabel("Live view in the \(screenCorner.userFacingName.lowercased()) corner")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
