import Foundation

/// The shortcut that opens the command bar from anywhere. The user can rebind it in the menu bar panel.
struct SummonHotkey: Codable, Equatable, Sendable {
    /// macOS virtual key code (the `kVK_…` constants): layout-independent, which is what hot key registration takes.
    var keyCode: UInt32
    var usesCommand: Bool
    var usesOption: Bool
    var usesControl: Bool
    var usesShift: Bool
    /// What the key is called on the user's keyboard when it was recorded ("Space", "K", "F5").
    var keyDisplayName: String

    static let spaceKeyCode: UInt32 = 49
    /// ⌃⌥Space: ⌥Space alone types a non-breaking space in many apps, and ⌃Space switches input sources.
    static let standard = SummonHotkey(keyCode: spaceKeyCode, usesCommand: false, usesOption: true, usesControl: true,
                                       usesShift: false, keyDisplayName: "Space")

    /// In the order macOS menus print modifiers: ⌃⌥⇧⌘.
    var displayText: String {
        (usesControl ? "⌃" : "") + (usesOption ? "⌥" : "") + (usesShift ? "⇧" : "") + (usesCommand ? "⌘" : "") + keyDisplayName
    }

    /// Key codes of the modifier keys themselves (⌘, ⇧, ⇪, ⌥, ⌃ on both sides, fn): pressing one alone isn't a shortcut.
    static let modifierOnlyKeyCodes: Set<UInt32> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
    /// Keys that already mean something in every app or panel (Esc closes Dotto's panels, Return submits, Tab moves).
    static let reservedKeyCodes: Set<UInt32> = [53, 36, 76, 48]

    /// nil when the shortcut can be used; otherwise one sentence for the recorder.
    var validationProblem: String? {
        if Self.modifierOnlyKeyCodes.contains(keyCode) { return "Add a key to the modifiers, like ⌃⌥Space." }
        if !(usesCommand || usesOption || usesControl) { return "Use ⌘, ⌥ or ⌃ in the shortcut, so it doesn't type a character." }
        if Self.reservedKeyCodes.contains(keyCode) { return "Esc, Return and Tab can't be part of the shortcut." }
        if usesCommand && !usesOption && !usesControl && ["Q", "W", "H", "M", "Tab"].contains(keyDisplayName) {
            return "\(displayText) already quits, closes or hides apps. Pick another shortcut."
        }
        return nil
    }

    /// Names keys that don't type a character; letters and symbols use what the keyboard layout typed.
    static func keyDisplayName(forKeyCode keyCode: UInt32, typedCharacters: String?) -> String {
        let namedKeys: [UInt32: String] = [49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 53: "Esc", 117: "⌦",
                                           123: "←", 124: "→", 125: "↓", 126: "↑", 115: "Home", 119: "End",
                                           116: "Page Up", 121: "Page Down",
                                           122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7",
                                           100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"]
        if let namedKey = namedKeys[keyCode] { return namedKey }
        let visibleCharacters = (typedCharacters ?? "").trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        return visibleCharacters.isEmpty ? "Key \(keyCode)" : visibleCharacters.uppercased()
    }
}
