import AppKit

typealias WindowListEntry = [String: Any]

/// One rule for reading the window list, shared by the user-input hit test, the target-window visibility monitor and
/// the action backend's window lookups. Window bounds and owners need no Screen Recording permission (only titles do).
/// The window list can't tell whether a window lets clicks through, so a window above the normal level that covers at
/// least half of its display counts as an overlay (screen tools and window managers draw these).
/// System shields (the lock screen, screen savers, the fade during a display change) sit at or above the shielding
/// level and are never a window the user works in.
enum WindowListEntryClassification {
    static var normalWindowLayer: Int { Int(CGWindowLevelForKey(.normalWindow)) }
    static var floatingWindowLayer: Int { Int(CGWindowLevelForKey(.floatingWindow)) }
    static var menuBarWindowLayer: Int { Int(CGWindowLevelForKey(.mainMenuWindow)) }
    static var shieldingWindowLayer: Int { Int(CGShieldingWindowLevel()) }

    // MARK: - Reading the list

    /// Front to back.
    static func onScreenWindowList() -> [WindowListEntry] {
        windowList(options: [.optionOnScreenOnly, .excludeDesktopElements], relativeToWindow: kCGNullWindowID)
    }

    static func onScreenWindowList(above windowIdentifier: CGWindowID) -> [WindowListEntry] {
        windowList(options: [.optionOnScreenAboveWindow], relativeToWindow: windowIdentifier)
    }

    static func windowListEntry(ofWindowWithIdentifier windowIdentifier: CGWindowID) -> WindowListEntry? {
        windowList(options: [.optionIncludingWindow], relativeToWindow: windowIdentifier).first
    }

    private static func windowList(options: CGWindowListOption, relativeToWindow windowIdentifier: CGWindowID) -> [WindowListEntry] {
        (CGWindowListCopyWindowInfo(options, windowIdentifier) as? [WindowListEntry]) ?? []
    }

    // MARK: - Lookups

    /// Without the private window lookup, the window list still gives the id: same owner, same frame (on screen or not).
    static func windowIdentifier(ownedBy processIdentifier: pid_t, matchingFrame windowFrame: CGRect) -> CGWindowID? {
        let windowListEntries = windowList(options: [.excludeDesktopElements], relativeToWindow: kCGNullWindowID)
        let matchingEntry = windowListEntries.first { windowInfo in
            guard ownerProcessIdentifier(of: windowInfo) == processIdentifier,
                  let listedFrame = frameInTopLeftGlobalPoints(of: windowInfo) else { return false }
            return listedFrame.integral == windowFrame.integral
        }
        return matchingEntry.flatMap(windowIdentifier(of:))
    }

    /// Front to back, the first on-screen, visible window of this process that contains the point. Only the process's
    /// own windows are considered, so Dotto's windows, other apps' overlays and shields can never be picked.
    static func frontmostWindow(ownedBy processIdentifier: pid_t, containingTopLeftGlobalPoint topLeftGlobalPoint: CGPoint)
        -> (windowIdentifier: CGWindowID, frameInTopLeftGlobalPoints: CGRect)? {
        for windowInfo in onScreenWindowList() {
            guard ownerProcessIdentifier(of: windowInfo) == processIdentifier,
                  !isFullyTransparent(windowInfo),
                  let windowIdentifier = windowIdentifier(of: windowInfo),
                  let windowFrame = frameInTopLeftGlobalPoints(of: windowInfo),
                  windowFrame.contains(topLeftGlobalPoint) else { continue }
            return (windowIdentifier, windowFrame)
        }
        return nil
    }

    /// The owner of the topmost window the user could have meant at a point. Skipped: Dotto's own windows (the
    /// click-through overlays), the system menu bar, which the window server owns while it shows the frontmost app's
    /// menus, and other apps' overlays and system shields. Menus, palettes and the Dock are smaller and still count.
    static func topmostWindowOwnerProcessIdentifier(atTopLeftGlobalPoint topLeftGlobalPoint: CGPoint) -> pid_t? {
        let ownProcessIdentifier = getpid()
        for windowInfo in onScreenWindowList() {
            guard let windowOwnerProcessIdentifier = ownerProcessIdentifier(of: windowInfo),
                  windowOwnerProcessIdentifier != ownProcessIdentifier,
                  layer(of: windowInfo) != menuBarWindowLayer,
                  !isFullyTransparent(windowInfo),
                  let windowFrame = frameInTopLeftGlobalPoints(of: windowInfo),
                  windowFrame.contains(topLeftGlobalPoint) else { continue }
            if isOverlayLike(windowInfo) || isSystemShield(windowInfo) {
                continue
            }
            return windowOwnerProcessIdentifier
        }
        return nil
    }

    // MARK: - Entry fields

    static func layer(of windowInfo: WindowListEntry) -> Int? {
        windowInfo[kCGWindowLayer as String] as? Int
    }

    static func ownerProcessIdentifier(of windowInfo: WindowListEntry) -> pid_t? {
        windowInfo[kCGWindowOwnerPID as String] as? Int32
    }

    static func windowIdentifier(of windowInfo: WindowListEntry) -> CGWindowID? {
        windowInfo[kCGWindowNumber as String] as? CGWindowID
    }

    static func frameInTopLeftGlobalPoints(of windowInfo: WindowListEntry) -> CGRect? {
        guard let windowBoundsDictionary = windowInfo[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: windowBoundsDictionary as CFDictionary)
    }

    static func isOnScreen(_ windowInfo: WindowListEntry) -> Bool {
        (windowInfo[kCGWindowIsOnscreen as String] as? Bool) == true
    }

    // MARK: - Classification

    static func isFullyTransparent(_ windowInfo: WindowListEntry) -> Bool {
        ((windowInfo[kCGWindowAlpha as String] as? Double) ?? 1) <= 0
    }

    static func isSystemShield(_ windowInfo: WindowListEntry) -> Bool {
        guard let windowLayer = layer(of: windowInfo) else { return false }
        return windowLayer >= shieldingWindowLayer
    }

    /// Above the normal level and covering at least half of the display it sits on.
    static func isOverlayLike(_ windowInfo: WindowListEntry) -> Bool {
        guard let windowLayer = layer(of: windowInfo), windowLayer != normalWindowLayer,
              let windowFrame = frameInTopLeftGlobalPoints(of: windowInfo) else { return false }
        let displayCenterPoint = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
        guard let displayFrame = displayBounds(containingTopLeftGlobalPoint: displayCenterPoint) else { return false }
        let displayArea = displayFrame.width * displayFrame.height
        let windowAreaOnDisplay = windowFrame.intersection(displayFrame).width * windowFrame.intersection(displayFrame).height
        return displayArea > 0 && windowAreaOnDisplay >= displayArea / 2
    }

    /// Windows the user can have covering another app's window: ordinary app windows and floating palettes. Menus,
    /// the Dock, overlays, shields and fully transparent windows are left out.
    static func isNormalOrFloatingAppWindow(_ windowInfo: WindowListEntry) -> Bool {
        guard let windowLayer = layer(of: windowInfo),
              windowLayer == normalWindowLayer || windowLayer == floatingWindowLayer,
              !isFullyTransparent(windowInfo), !isSystemShield(windowInfo), !isOverlayLike(windowInfo) else { return false }
        return true
    }

    static func displayBounds(containingTopLeftGlobalPoint topLeftGlobalPoint: CGPoint) -> CGRect? {
        var displayIdentifier: CGDirectDisplayID = 0
        var displayCount: UInt32 = 0
        guard CGGetDisplaysWithPoint(topLeftGlobalPoint, 1, &displayIdentifier, &displayCount) == .success, displayCount > 0 else {
            return nil
        }
        return CGDisplayBounds(displayIdentifier)
    }
}
