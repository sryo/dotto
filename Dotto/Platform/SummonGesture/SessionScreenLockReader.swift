import CoreGraphics
import Foundation

/// Reads, from the window server's session dictionary, whether the screen is locked or this login session is
/// switched out (fast user switching). Notifications keep the circle summon's own flags current; this is the
/// authoritative read at start and when a circle is recognized.
enum SessionScreenLockReader {
    static func screenIsLockedOrSessionIsInactive() -> Bool {
        guard let sessionDictionary = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        // "CGSSessionScreenIsLocked" is undocumented but long-standing; it is absent while the screen is unlocked.
        let screenIsLocked = (sessionDictionary["CGSSessionScreenIsLocked"] as? Bool) == true
        let sessionIsOnConsole = (sessionDictionary[kCGSessionOnConsoleKey as String] as? Bool) ?? true
        return screenIsLocked || !sessionIsOnConsole
    }
}
