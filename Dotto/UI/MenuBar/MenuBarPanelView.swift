import SwiftUI

/// The menu bar panel: status, the Anthropic API key, permission setup, the entry point for a new task, saved
/// routines and settings.
struct MenuBarPanelView: View {
    @ObservedObject var taskSessionController: TaskSessionController
    /// The panel only measures itself when shown, so content that grows while open reports its height.
    let onContentHeightChange: (CGFloat) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader

            Divider()
                .background(DesignSystem.Colors.borderSubtle)
                .padding(.horizontal, 16)

            VStack(alignment: .leading, spacing: 12) {
                if !taskSessionController.hasAnthropicAPIKey {
                    AnthropicAPIKeySection(taskSessionController: taskSessionController)
                }

                if !taskSessionController.permissionStatus.allRequiredPermissionsGranted {
                    permissionsSection
                }

                newTaskButton

                if taskSessionController.sessionState.isBusy {
                    Button("Stop Dotto") { taskSessionController.stopTask() }
                        .dsDestructiveButtonStyle()
                }

                if taskSessionController.sessionState.currentChecklist != nil || taskSessionController.sessionState.isBusy {
                    Button("Show checklist") {
                        NotificationCenter.default.post(name: .dismissMenuBarPanel, object: nil)
                        taskSessionController.showChecklist()
                    }
                    .dsSecondaryButtonStyle()
                }

                UndoLastTaskRow(taskSessionController: taskSessionController,
                                directRouteSessionState: taskSessionController.directRouteSessionState)

                if !taskSessionController.savedRoutines.isEmpty || !taskSessionController.skippedRoutineFiles.isEmpty {
                    routinesSection
                }

                if taskSessionController.hasAnthropicAPIKey {
                    AnthropicAPIKeySection(taskSessionController: taskSessionController)
                }

                SummonHotkeyRecorderRow(taskSessionController: taskSessionController)

                SummonGestureSettingsSection(taskSessionController: taskSessionController)

                MenuBarSettingToggleRow(
                    title: "Avoid foreground assists",
                    explanation: "Leave steps needing the target in front undone",
                    isOn: taskSessionController.taskFocusPolicy == .backgroundOnly,
                    onChange: { isOn in
                        taskSessionController.updateTaskFocusPolicy(isOn ? .backgroundOnly : .allowApprovedAssist)
                    })
                .disabled(!taskSessionController.canChangeTaskFocusPolicy)

                AttentionSettingsSection(taskSessionController: taskSessionController)
            }
            .padding(16)

            Divider()
                .background(DesignSystem.Colors.borderSubtle)
                .padding(.horizontal, 16)

            quitButton
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .frame(width: 320)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.extraLarge, style: .continuous)
                .fill(DesignSystem.Colors.background)
                .shadow(color: Color.black.opacity(0.5), radius: 20, x: 0, y: 10)
                .shadow(color: Color.black.opacity(0.3), radius: 4, x: 0, y: 2)
        )
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { geometryProxy in geometryProxy.size.height } action: { contentHeight in
            onContentHeightChange(contentHeight)
        }
    }

    // MARK: - Header

    private var panelHeader: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusDotColor)
                .frame(width: 8, height: 8)
                .shadow(color: statusDotColor.opacity(0.6), radius: 4)

            Text("Dotto")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(DesignSystem.Colors.textPrimary)

            Spacer()

            Text(taskSessionController.statusLine)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DesignSystem.Colors.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)

            HoverAwarePlainButton(action: {
                NotificationCenter.default.post(name: .dismissMenuBarPanel, object: nil)
            }) { isHovered in
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(isHovered ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textTertiary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.white.opacity(isHovered ? 0.16 : 0.08)))
            }
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var statusDotColor: Color {
        if !taskSessionController.hasAnthropicAPIKey
            || !taskSessionController.permissionStatus.allRequiredPermissionsGranted {
            return DesignSystem.Colors.warning
        }
        return taskSessionController.sessionState.isBusy ? DesignSystem.Colors.accentText : DesignSystem.Colors.success
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            MenuBarSectionLabel(title: "Permissions")

            permissionRow(
                iconSystemName: "hand.raised",
                title: "Accessibility",
                explanation: "Lets Dotto read and operate app controls",
                isGranted: taskSessionController.permissionStatus.hasAccessibilityPermission,
                grantAction: { taskSessionController.requestAccessibilityPermission() }
            )

            permissionRow(
                iconSystemName: "rectangle.dashed.badge.record",
                title: "Screen Recording",
                explanation: taskSessionController.permissionStatus.hasScreenRecordingPermission
                    ? "Used only when an app can't be read directly"
                    : "Quit and reopen after granting",
                isGranted: taskSessionController.permissionStatus.hasScreenRecordingPermission,
                grantAction: { taskSessionController.requestScreenRecordingPermission() }
            )
        }
    }

    private func permissionRow(iconSystemName: String, title: String, explanation: String,
                               isGranted: Bool, grantAction: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: iconSystemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isGranted ? DesignSystem.Colors.textTertiary : DesignSystem.Colors.warning)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DesignSystem.Colors.textSecondary)
                Text(explanation)
                    .font(.system(size: 10))
                    .foregroundColor(DesignSystem.Colors.textTertiary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DesignSystem.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DesignSystem.Colors.success)
                }
            } else {
                HoverAwarePlainButton(action: grantAction) { isHovered in
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DesignSystem.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(isHovered ? DesignSystem.Colors.accentHover : DesignSystem.Colors.accent))
                }
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Actions

    private var newTaskButton: some View {
        Button(action: {
            NotificationCenter.default.post(name: .dismissMenuBarPanel, object: nil)
            taskSessionController.showCommandBar()
        }) {
            HStack(spacing: 8) {
                Text("New task")
                Text(taskSessionController.summonHotkey.displayText)
                    .font(.system(size: 12, weight: .medium))
                    .opacity(0.7)
            }
        }
        .dsPrimaryButtonStyle()
        .disabled(taskSessionController.sessionState.isBusy)
    }

    private var routinesSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            MenuBarSectionLabel(title: "Routines")
            ForEach(taskSessionController.savedRoutines) { savedRoutine in
                SavedRoutineRow(routine: savedRoutine, taskSessionController: taskSessionController)
            }
            if !taskSessionController.skippedRoutineFiles.isEmpty {
                skippedRoutineFilesList
            }
        }
    }

    /// Files Dotto refused to load are listed rather than hidden, so a tampered or damaged routine is noticed.
    private var skippedRoutineFilesList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(DesignSystem.Colors.warningText)
                Text(taskSessionController.skippedRoutineFiles.count == 1
                     ? "1 routine file wasn't loaded" : "\(taskSessionController.skippedRoutineFiles.count) routine files weren't loaded")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DesignSystem.Colors.warningText)
                Spacer(minLength: 4)
                Button("Show in Finder") { taskSessionController.revealRoutineLibraryFolder() }
                    .dsTextButtonStyle()
            }
            ForEach(Array(taskSessionController.skippedRoutineFiles.enumerated()), id: \.offset) { _, skippedRoutineFile in
                VStack(alignment: .leading, spacing: 1) {
                    Text(skippedRoutineFile.fileName)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(DesignSystem.Colors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    WrappingText(skippedRoutineFile.reason, size: 10, color: DesignSystem.Colors.textTertiary)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.medium, style: .continuous).fill(DesignSystem.Colors.warning.opacity(0.08)))
        .padding(.top, 6)
    }

    private var quitButton: some View {
        HoverAwarePlainButton(action: { NSApp.terminate(nil) }) { isHovered in
            HStack(spacing: 6) {
                Image(systemName: "power")
                    .font(.system(size: 11, weight: .medium))
                Text("Quit Dotto")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(isHovered ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textTertiary)
        }
    }
}
