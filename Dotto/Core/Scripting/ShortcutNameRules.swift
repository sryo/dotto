import Foundation

/// A shortcut runs only under the exact name `shortcuts list` printed, and never under a name that could be read as
/// an option of the `shortcuts` command.
enum ShortcutNameRules {
    static let maximumNameLength = 255

    /// Returns nil when the name may be passed to `/usr/bin/shortcuts run`, else the reason.
    static func validate(_ shortcutName: String) -> String? {
        if shortcutName.isEmpty { return "The shortcut name is empty." }
        if shortcutName.hasPrefix("-") { return "Shortcut names starting with “-” can't be run by Dotto." }
        if shortcutName.unicodeScalars.contains(where: FileOperationPathRules.isControlScalar) {
            return "The shortcut name contains a control character."
        }
        if shortcutName.count > maximumNameLength { return "The shortcut name is longer than \(maximumNameLength) characters." }
        return nil
    }

    /// Exact, case-sensitive equality with one listed name; nothing is trimmed or matched loosely.
    static func isListed(_ shortcutName: String, inListedNames listedShortcutNames: [String]) -> Bool {
        listedShortcutNames.contains { $0 == shortcutName }
    }
}
