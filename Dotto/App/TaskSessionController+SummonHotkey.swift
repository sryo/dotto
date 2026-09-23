import AppKit

/// The command bar's shortcut: ⌃⌥Space by default, rebindable from the menu bar panel and kept in UserDefaults.
/// While the recorder listens, the hotkey is unregistered so pressing the current shortcut reaches the recorder.
extension TaskSessionController {
    private static let summonHotkeyDefaultsKey = "dottoSummonHotkey"

    func loadSummonHotkey() {
        if let storedHotkeyData = UserDefaults.standard.data(forKey: Self.summonHotkeyDefaultsKey),
           let storedHotkey = try? JSONDecoder().decode(SummonHotkey.self, from: storedHotkeyData),
           storedHotkey.validationProblem == nil {
            summonHotkey = storedHotkey
        }
    }

    func beginRecordingSummonHotkey() {
        summonHotkeyRecordingProblem = nil
        keyboardMonitor.stop()
    }

    func cancelRecordingSummonHotkey() {
        startKeyboardMonitor()
    }

    /// Uses the recorded shortcut when it registers; when the system refuses it (another app holds it), keeps the
    /// previous one and says why.
    func finishRecordingSummonHotkey(_ recordedHotkey: SummonHotkey) {
        if let validationProblem = recordedHotkey.validationProblem {
            summonHotkeyRecordingProblem = validationProblem
            startKeyboardMonitor()
            return
        }
        let previousHotkey = summonHotkey
        summonHotkey = recordedHotkey
        startKeyboardMonitor()
        guard summonHotkeyIsRegistered else {
            summonHotkeyRecordingProblem = "macOS didn't accept \(recordedHotkey.displayText); another app may already use it. Kept \(previousHotkey.displayText)."
            summonHotkey = previousHotkey
            startKeyboardMonitor()
            return
        }
        summonHotkeyRecordingProblem = nil
        persistSummonHotkey()
    }

    func resetSummonHotkeyToStandard() {
        finishRecordingSummonHotkey(.standard)
    }

    private func persistSummonHotkey() {
        if let encodedHotkey = try? JSONEncoder().encode(summonHotkey) {
            UserDefaults.standard.set(encodedHotkey, forKey: Self.summonHotkeyDefaultsKey)
        }
    }
}
