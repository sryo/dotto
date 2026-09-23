import AppKit
import Carbon.HIToolbox

/// Looks for the usual owners of a shortcut: macOS's own keyboard shortcuts (System Settings > Keyboard > Keyboard
/// Shortcuts, stored in the symbolic hotkeys preferences) and launchers known to default to ⌥Space. Other apps'
/// shortcuts can't be read, so finding nothing is reported as nothing, never as "free".
enum SummonHotkeyConflictCheck {
    private struct SymbolicHotkeyDefault {
        var purpose: String
        var keyCode: Int
        var modifierMask: Int
        /// Input-source switching only takes the keys when there is more than one input source to switch between.
        var needsSeveralInputSources: Bool
    }

    private static let symbolicHotkeysDomain = "com.apple.symbolichotkeys"
    private static let symbolicHotkeysKey = "AppleSymbolicHotKeys"
    // NSEvent modifier flags, as the symbolic hotkeys preferences store them.
    private static let shiftModifierFlag = 0x20000
    private static let controlModifierFlag = 0x40000
    private static let optionModifierFlag = 0x80000
    private static let commandModifierFlag = 0x100000
    private static let spaceKeyCode = 49

    /// macOS's shortcuts that overlap the keys people pick for a launcher, with their factory settings, which apply
    /// while the preferences have no entry for them. Keys are the preference's shortcut ids.
    private static let knownSymbolicHotkeyDefaults: [String: SymbolicHotkeyDefault] = [
        "60": SymbolicHotkeyDefault(purpose: "to select the previous input source", keyCode: spaceKeyCode,
                                    modifierMask: controlModifierFlag, needsSeveralInputSources: true),
        "61": SymbolicHotkeyDefault(purpose: "to select the next input source", keyCode: spaceKeyCode,
                                    modifierMask: controlModifierFlag | optionModifierFlag, needsSeveralInputSources: true),
        "64": SymbolicHotkeyDefault(purpose: "for Spotlight", keyCode: spaceKeyCode,
                                    modifierMask: commandModifierFlag, needsSeveralInputSources: false),
        "65": SymbolicHotkeyDefault(purpose: "for a Finder search window", keyCode: spaceKeyCode,
                                    modifierMask: commandModifierFlag | optionModifierFlag, needsSeveralInputSources: false),
    ]

    /// Bundle ids of launchers whose factory shortcut is ⌥Space.
    private static let optionSpaceLauncherBundleIdentifiers: [String: String] = [
        "com.runningwithcrayons.Alfred": "Alfred",
        "com.raycast.macos": "Raycast",
        "com.openai.chat": "ChatGPT",
    ]

    static func conflictDescription(for summonHotkey: SummonHotkey) -> String? {
        let summonModifierMask = (summonHotkey.usesShift ? shiftModifierFlag : 0) | (summonHotkey.usesControl ? controlModifierFlag : 0)
            | (summonHotkey.usesOption ? optionModifierFlag : 0) | (summonHotkey.usesCommand ? commandModifierFlag : 0)
        if let systemShortcut = enabledSystemShortcut(keyCode: Int(summonHotkey.keyCode), modifierMask: summonModifierMask) {
            return systemShortcut.settingsWereReadable
                ? "macOS uses \(summonHotkey.displayText) \(systemShortcut.purpose)."
                : "macOS uses \(summonHotkey.displayText) \(systemShortcut.purpose) unless that shortcut is turned off in "
                    + "System Settings > Keyboard > Keyboard Shortcuts."
        }
        if Int(summonHotkey.keyCode) == spaceKeyCode, summonModifierMask == optionModifierFlag {
            let runningLauncherNames = NSWorkspace.shared.runningApplications
                .compactMap { $0.bundleIdentifier.flatMap { optionSpaceLauncherBundleIdentifiers[$0] } }
            if let runningLauncherName = runningLauncherNames.first {
                return "\(runningLauncherName) is running and uses \(summonHotkey.displayText) unless you changed it."
            }
        }
        return nil
    }

    /// The preferences store every shortcut the user touched as enabled plus (the key's character, key code, modifier
    /// flags); untouched known ones keep their factory setting. The app sandbox may hide the preferences, and then only
    /// the factory settings are known.
    private static func enabledSystemShortcut(keyCode: Int, modifierMask: Int) -> (purpose: String, settingsWereReadable: Bool)? {
        let readableSymbolicHotkeys = CFPreferencesCopyAppValue(symbolicHotkeysKey as CFString, symbolicHotkeysDomain as CFString)
            as? [String: [String: Any]]
        let storedSymbolicHotkeys = readableSymbolicHotkeys ?? [:]
        let settingsWereReadable = readableSymbolicHotkeys != nil
        for (symbolicHotkeyIdentifier, storedEntry) in storedSymbolicHotkeys {
            guard (storedEntry["enabled"] as? Bool) == true || (storedEntry["enabled"] as? Int) == 1,
                  let storedValue = storedEntry["value"] as? [String: Any],
                  let storedParameters = storedValue["parameters"] as? [Int], storedParameters.count >= 3,
                  storedParameters[1] == keyCode, storedParameters[2] == modifierMask else { continue }
            let knownDefault = knownSymbolicHotkeyDefaults[symbolicHotkeyIdentifier]
            if knownDefault?.needsSeveralInputSources == true, !hasSeveralSelectableInputSources() { continue }
            return (knownDefault?.purpose ?? "for one of its keyboard shortcuts", settingsWereReadable)
        }
        for (symbolicHotkeyIdentifier, knownDefault) in knownSymbolicHotkeyDefaults
        where storedSymbolicHotkeys[symbolicHotkeyIdentifier] == nil {
            guard knownDefault.keyCode == keyCode, knownDefault.modifierMask == modifierMask else { continue }
            if knownDefault.needsSeveralInputSources, !hasSeveralSelectableInputSources() { continue }
            return (knownDefault.purpose, settingsWereReadable)
        }
        return nil
    }

    private static func hasSeveralSelectableInputSources() -> Bool {
        let selectableKeyboardSourceFilter = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
            kTISPropertyInputSourceIsSelectCapable as String: true,
            kTISPropertyInputSourceIsEnabled as String: true,
        ] as CFDictionary
        guard let inputSourceList = TISCreateInputSourceList(selectableKeyboardSourceFilter, false)?.takeRetainedValue() else {
            return true
        }
        return CFArrayGetCount(inputSourceList) > 1
    }
}
