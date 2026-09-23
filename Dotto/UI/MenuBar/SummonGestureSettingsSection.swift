import AppKit
import SwiftUI

/// The menu bar panel's settings for circle to summon: on/off, which way to circle, how many loops, and the apps
/// where circling never summons Dotto.
struct SummonGestureSettingsSection: View {
    @ObservedObject var taskSessionController: TaskSessionController

    @State private var isExclusionListExpanded = false

    private var summonGestureConfiguration: SummonGestureConfiguration {
        taskSessionController.summonGestureConfiguration
    }

    private var accentColor: Color {
        taskSessionController.cursorStyleConfiguration.taskAccentColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            MenuBarSectionLabel(title: "Circle to summon")

            MenuBarSettingToggleRow(
                title: "Circle to summon",
                explanation: "Circle the pointer to open Dotto right there, for the app under it",
                isOn: summonGestureConfiguration.isEnabled,
                onChange: { isOn in taskSessionController.updateSummonGestureConfiguration { $0.isEnabled = isOn } })

            if summonGestureConfiguration.isEnabled {
                directionRow
                loopsNeededRow
                exclusionListRow
            }
        }
    }

    // MARK: - Direction

    private var directionRow: some View {
        HStack(spacing: 8) {
            MenuBarSettingText(title: "Direction", explanation: "Which way to circle")
            Spacer(minLength: 4)
            HStack(spacing: 2) {
                ForEach(Self.directionChoices, id: \.direction) { directionChoice in
                    SummonGestureDirectionButton(
                        title: directionChoice.title,
                        isSelected: summonGestureConfiguration.direction == directionChoice.direction,
                        accentColor: accentColor,
                        onSelect: {
                            taskSessionController.updateSummonGestureConfiguration { $0.direction = directionChoice.direction }
                        })
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.medium, style: .continuous)
                .fill(DesignSystem.Colors.surface2))
            // The segment labels must never wrap mid-word; the setting's title and explanation give way instead.
            .fixedSize()
            .layoutPriority(1)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
    }

    private static let directionChoices: [(direction: SummonGestureDirection, title: String)] = [
        (.clockwise, "Clockwise"), (.either, "Either"), (.counterClockwise, "Counter"),
    ]

    // MARK: - Sensitivity

    private var loopsNeededRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                MenuBarSettingText(title: "Loops needed", explanation: "Fewer is quicker; more avoids summoning by accident")
                Spacer(minLength: 4)
                Text(Self.loopsNeededDisplayText(summonGestureConfiguration.loopsNeeded))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(DesignSystem.Colors.textPrimary)
                    .monospacedDigit()
            }
            Slider(
                value: Binding(
                    get: { summonGestureConfiguration.loopsNeeded },
                    set: { loopsNeeded in taskSessionController.updateSummonGestureConfiguration { $0.loopsNeeded = loopsNeeded } }),
                in: SummonGestureConfiguration.loopsNeededRange,
                step: 0.25)
                .controlSize(.mini)
                .tint(accentColor)
                .pointerCursor()
                .accessibilityLabel("Loops needed")
                .accessibilityValue(Self.loopsNeededDisplayText(summonGestureConfiguration.loopsNeeded))
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
    }

    private static func loopsNeededDisplayText(_ loopsNeeded: Double) -> String {
        let formattedLoops = loopsNeeded.formatted(.number.precision(.fractionLength(0...2)))
        return loopsNeeded == 1 ? "1 loop" : "\(formattedLoops) loops"
    }

    // MARK: - Exclusions

    private var exclusionListRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                HoverAwarePlainButton(action: { isExclusionListExpanded.toggle() }) { isHovered in
                    HStack(spacing: 4) {
                        Image(systemName: isExclusionListExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(DesignSystem.Colors.textTertiary)
                            .frame(width: 10)
                        MenuBarSettingText(
                            title: "Not in these apps",
                            explanation: "\(taskSessionController.summonGestureExcludedBundleIdentifiers.count) apps, such as drawing tools and games",
                            isHighlighted: isHovered)
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityLabel(isExclusionListExpanded ? "Hide excluded apps" : "Show excluded apps")
                Spacer(minLength: 4)
            }

            if isExclusionListExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(taskSessionController.summonGestureExcludedBundleIdentifiers, id: \.self) { excludedBundleIdentifier in
                        ExcludedApplicationRow(
                            bundleIdentifier: excludedBundleIdentifier,
                            onRemove: { taskSessionController.removeSummonGestureExclusion(bundleIdentifier: excludedBundleIdentifier) })
                    }
                }
                .padding(.leading, 14)

                HStack(spacing: 10) {
                    addFrontmostApplicationButton
                    Spacer(minLength: 4)
                    if !taskSessionController.summonGestureExclusionAdjustments.isEmpty {
                        HoverAwarePlainButton(action: { taskSessionController.resetSummonGestureExclusionsToDefaults() }) { isHovered in
                            Text("Reset to defaults")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(isHovered ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textSecondary)
                                .underline(isHovered)
                        }
                    }
                }
                .padding(.leading, 14)
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
    }

    @ViewBuilder
    private var addFrontmostApplicationButton: some View {
        if let exclusionCandidate = taskSessionController.summonGestureExclusionCandidate,
           let candidateBundleIdentifier = exclusionCandidate.bundleIdentifier {
            let isAlreadyExcluded = taskSessionController.summonGestureExcludedBundleIdentifiers
                .contains { $0.caseInsensitiveCompare(candidateBundleIdentifier) == .orderedSame }
            HoverAwarePlainButton(action: {
                taskSessionController.addSummonGestureExclusion(bundleIdentifier: candidateBundleIdentifier)
            }) { isHovered in
                HStack(spacing: 3) {
                    Image(systemName: "plus")
                    Text("Exclude \(exclusionCandidate.localizedName ?? candidateBundleIdentifier)")
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isHovered ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(isHovered ? DesignSystem.Colors.surface3 : DesignSystem.Colors.surface2))
            }
            .disabled(isAlreadyExcluded)
            .opacity(isAlreadyExcluded ? 0.5 : 1)
            .nativeTooltip(isAlreadyExcluded ? "Already excluded" : "Circling in this app won't summon Dotto")
        }
    }
}

private struct SummonGestureDirectionButton: View {
    let title: String
    let isSelected: Bool
    let accentColor: Color
    let onSelect: () -> Void

    var body: some View {
        HoverAwarePlainButton(action: onSelect) { isHovered in
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .foregroundColor(isSelected ? DesignSystem.Colors.textOnAccent
                                 : (isHovered ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textSecondary))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? accentColor : (isHovered ? DesignSystem.Colors.surface3 : Color.clear))
                )
        }
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// One excluded app: its name when it is installed (the bundle id otherwise), and a remove button.
private struct ExcludedApplicationRow: View {
    let bundleIdentifier: String
    let onRemove: () -> Void

    private var displayName: String {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return bundleIdentifier
        }
        return FileManager.default.displayName(atPath: applicationURL.path).replacingOccurrences(of: ".app", with: "")
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(displayName)
                .font(.system(size: 11))
                .foregroundColor(DesignSystem.Colors.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .nativeTooltip(bundleIdentifier)
            Spacer(minLength: 4)
            HoverAwarePlainButton(action: onRemove) { isHovered in
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(isHovered ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textTertiary)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(isHovered ? DesignSystem.Colors.surface3 : Color.clear))
            }
            .accessibilityLabel("Stop excluding \(displayName)")
        }
        .padding(.vertical, 1)
    }
}
