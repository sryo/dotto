import AppKit
import SwiftUI

/// The menu bar panel's setting for the command bar's shortcut. Clicking the shortcut starts listening; the next key
/// pressed with ⌘, ⌥ or ⌃ becomes the shortcut, and Esc cancels. Keys are read with a local monitor, so only while
/// Dotto's panel has the keyboard; nothing is watched globally.
struct SummonHotkeyRecorderRow: View {
    @ObservedObject var taskSessionController: TaskSessionController

    @State private var isRecording = false
    @State private var keyDownMonitor: Any?

    private static let escapeKeyCode: UInt16 = 53

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                MenuBarSettingText(title: "New task shortcut",
                                   explanation: isRecording ? "Press the new shortcut · Esc cancels" : "Opens the command bar from any app")
                Spacer(minLength: 4)
                shortcutButton
            }
            if let recordingProblem = taskSessionController.summonHotkeyRecordingProblem {
                noteText(recordingProblem, isWarning: true)
            } else if !taskSessionController.summonHotkeyIsRegistered {
                noteText("Dotto couldn't turn on \(taskSessionController.summonHotkey.displayText). Pick another shortcut.", isWarning: true)
            } else if let conflictDescription = taskSessionController.summonHotkeyConflictDescription {
                noteText(conflictDescription, isWarning: true)
            }
            HStack(spacing: 6) {
                noteText("If nothing happens when you press it, pick another shortcut.", isWarning: false)
                Spacer(minLength: 4)
                if taskSessionController.summonHotkey != .standard && !isRecording { resetButton }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        .onDisappear { stopRecording(cancelled: true) }
    }

    private var shortcutButton: some View {
        HoverAwarePlainButton(action: { isRecording ? stopRecording(cancelled: true) : startRecording() }) { isHovered in
            Text(isRecording ? "Recording…" : taskSessionController.summonHotkey.displayText)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(isRecording ? DesignSystem.Colors.textOnAccent : DesignSystem.Colors.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.medium, style: .continuous)
                        .fill(isRecording ? DesignSystem.Colors.accent
                              : (isHovered ? DesignSystem.Colors.surface3 : DesignSystem.Colors.surface2))
                )
        }
        .nativeTooltip(isRecording ? "Click to cancel" : "Click, then press a new shortcut")
        .accessibilityLabel("New task shortcut, \(taskSessionController.summonHotkey.displayText)")
        .accessibilityHint(isRecording ? "Press the new shortcut, or Escape to cancel" : "Click to record a new shortcut")
    }

    private var resetButton: some View {
        HoverAwarePlainButton(action: { taskSessionController.resetSummonHotkeyToStandard() }) { isHovered in
            Text("Reset to \(SummonHotkey.standard.displayText)")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(isHovered ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textSecondary)
                .underline(isHovered)
        }
    }

    private func noteText(_ noteText: String, isWarning: Bool) -> some View {
        WrappingText(noteText, size: 10, color: isWarning ? DesignSystem.Colors.warningText : DesignSystem.Colors.textTertiary)
    }

    private func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        taskSessionController.beginRecordingSummonHotkey()
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { keyDownEvent in
            let pressedKeyCode = keyDownEvent.keyCode
            let pressedModifiers = keyDownEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let typedCharacters = keyDownEvent.charactersIgnoringModifiers
            // Local monitors run on the main thread. Every key is swallowed while recording.
            MainActor.assumeIsolated {
                handleRecordedKeyDown(keyCode: pressedKeyCode, pressedModifiers: pressedModifiers, typedCharacters: typedCharacters)
            }
            return nil
        }
    }

    private func handleRecordedKeyDown(keyCode: UInt16, pressedModifiers: NSEvent.ModifierFlags, typedCharacters: String?) {
        if keyCode == Self.escapeKeyCode && pressedModifiers.isDisjoint(with: [.command, .option, .control, .shift]) {
            stopRecording(cancelled: true)
            return
        }
        let recordedHotkey = SummonHotkey(
            keyCode: UInt32(keyCode),
            usesCommand: pressedModifiers.contains(.command), usesOption: pressedModifiers.contains(.option),
            usesControl: pressedModifiers.contains(.control), usesShift: pressedModifiers.contains(.shift),
            keyDisplayName: SummonHotkey.keyDisplayName(forKeyCode: UInt32(keyCode), typedCharacters: typedCharacters))
        if let validationProblem = recordedHotkey.validationProblem {
            // Keep listening: the user can try another combination right away.
            taskSessionController.summonHotkeyRecordingProblem = validationProblem
            return
        }
        stopRecording(cancelled: false)
        taskSessionController.finishRecordingSummonHotkey(recordedHotkey)
    }

    private func stopRecording(cancelled: Bool) {
        guard isRecording else { return }
        isRecording = false
        if let keyDownMonitor { NSEvent.removeMonitor(keyDownMonitor) }
        keyDownMonitor = nil
        if cancelled { taskSessionController.cancelRecordingSummonHotkey() }
    }
}
