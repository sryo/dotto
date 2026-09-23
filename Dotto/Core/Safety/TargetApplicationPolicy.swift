import Foundation

/// Apps and system shortcuts Dotto never operates, whatever the checklist says. Enforced by the action backend
/// before it activates a target app or posts a key press.
enum TargetApplicationPolicy {
    /// Apps where a mistaken keystroke can run commands, change security settings or expose secrets.
    private static let blockedTargetBundleIdentifiers: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
        "com.apple.systempreferences", "com.apple.Settings",
        "com.apple.keychainaccess", "com.apple.SecurityAgent", "com.apple.loginwindow",
        "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx",
        "com.agilebits.onepassword4", "com.bitwarden.desktop", "com.apple.Passwords",
    ]
    // Warp ships as dev.warp.Warp-Stable, dev.warp.Warp-Preview and dev.warp.Warp.
    private static let blockedTargetBundleIdentifierPrefixes = ["dev.warp.Warp"]

    /// App switching, hiding, quitting, Spotlight, Force Quit and lock/log-out shortcuts. A press is blocked when it
    /// includes all of an entry's modifiers, so cmd+shift+tab and ctrl+cmd+q are caught by cmd+tab and cmd+q.
    private static let blockedSystemShortcuts: [(keyName: String, modifiers: Set<AgentKeyModifier>)] = [
        ("space", [.command]), ("tab", [.command]), ("`", [.command]), ("h", [.command]), ("q", [.command]),
        ("escape", [.command, .option]),
    ]

    static func isBlockedTargetApplication(_ application: TargetApplicationReference) -> Bool {
        guard let bundleIdentifier = application.bundleIdentifier else { return false }
        return blockedTargetBundleIdentifiers.contains(bundleIdentifier)
            || blockedTargetBundleIdentifierPrefixes.contains { bundleIdentifier.hasPrefix($0) }
    }

    static func isBlockedSystemShortcut(keyName: String, modifiers: [AgentKeyModifier]) -> Bool {
        var normalizedKeyName = keyName.lowercased()
        if normalizedKeyName == "esc" { normalizedKeyName = "escape" }
        if normalizedKeyName == " " { normalizedKeyName = "space" }
        let pressedModifiers = Set(modifiers)
        return blockedSystemShortcuts.contains { blockedShortcut in
            blockedShortcut.keyName == normalizedKeyName && blockedShortcut.modifiers.isSubset(of: pressedModifiers)
        }
    }
}
