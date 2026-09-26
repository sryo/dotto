import AppKit

/// Screen and window-server lookups shared by the panels. Window bounds from the window server need no permission
/// (only titles do), so nothing here touches Accessibility.
@MainActor
enum ScreenGeometry {
    /// Used when no screen is known at all, which only happens while displays are reconfiguring.
    private static let fallbackVisibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)

    static var screenUnderMouse: NSScreen? {
        // NSScreen.main is the key window's screen, which says nothing for an app that is never key; the first screen
        // is the one with the menu bar.
        screen(containingAppKitPoint: NSEvent.mouseLocation) ?? NSScreen.screens.first
    }

    /// Edges included: the pointer can rest on a screen's top row, where AppKit's y equals `maxY`, which
    /// `CGRect.contains` leaves out.
    static func screen(containingAppKitPoint appKitPoint: CGPoint) -> NSScreen? {
        let screens = NSScreen.screens
        return SummonGestureDisplayGeometry.indexOfDisplay(containing: appKitPoint, displayFrames: screens.map(\.frame))
            .map { screenIndex in screens[screenIndex] }
    }

    static func visibleFrame(of screen: NSScreen?) -> CGRect {
        screen?.visibleFrame ?? fallbackVisibleFrame
    }

    /// Never 0 (`PrimaryDisplayHeightResolution`): while displays reconfigure, the last settled height, which the
    /// Platform display observer records. Before any display was ever seen, the fallback frame's height.
    static var primaryDisplayHeightInPoints: CGFloat {
        let cache = PrimaryDisplayHeightCache.shared
        return PrimaryDisplayHeightResolution.resolve(
            coreGraphicsMainDisplayHeight: CGDisplayBounds(CGMainDisplayID()).height,
            appKitPrimaryScreenHeight: NSScreen.screens.first?.frame.height,
            lastKnownHeight: cache.lastKnownHeight, displaysAreReconfiguring: cache.displaysAreReconfiguring)
            ?? fallbackVisibleFrame.height
    }

    /// Converts a window-server rectangle (top-left origin of the primary display, y down) to AppKit's global
    /// coordinates (bottom-left origin, y up).
    static func appKitFrame(fromTopLeftGlobalFrame topLeftGlobalFrame: CGRect) -> CGRect {
        return CGRect(x: topLeftGlobalFrame.minX, y: primaryDisplayHeightInPoints - topLeftGlobalFrame.maxY,
                      width: topLeftGlobalFrame.width, height: topLeftGlobalFrame.height)
    }

    /// The inverse of `appKitFrame(fromTopLeftGlobalFrame:)`: flipping y against the primary display is its own inverse.
    static func topLeftGlobalFrame(fromAppKitFrame appKitFrame: CGRect) -> CGRect {
        Self.appKitFrame(fromTopLeftGlobalFrame: appKitFrame)
    }

    static func topLeftGlobalPoint(fromAppKitPoint appKitPoint: CGPoint) -> CGPoint {
        topLeftGlobalFrame(fromAppKitFrame: CGRect(origin: appKitPoint, size: .zero)).origin
    }

    static func appKitPoint(fromTopLeftGlobalPoint topLeftGlobalPoint: CGPoint) -> CGPoint {
        appKitFrame(fromTopLeftGlobalFrame: CGRect(origin: topLeftGlobalPoint, size: .zero)).origin
    }

    /// The pointer, in the window server's top-left global points.
    static var mouseLocationInTopLeftGlobalPoints: CGPoint {
        topLeftGlobalPoint(fromAppKitPoint: NSEvent.mouseLocation)
    }

    /// The visible frame (without the menu bar and the Dock) of the screen that shows this point, in top-left global
    /// points; the screen under the mouse when no screen shows it.
    static func visibleFrameInTopLeftGlobalPoints(ofScreenContainingTopLeftGlobalPoint topLeftGlobalPoint: CGPoint) -> CGRect {
        let containingScreen = screen(containingAppKitPoint: appKitPoint(fromTopLeftGlobalPoint: topLeftGlobalPoint)) ?? screenUnderMouse
        return topLeftGlobalFrame(fromAppKitFrame: visibleFrame(of: containingScreen))
    }

    /// Every screen's visible frame, in top-left global points.
    static var visibleFramesInTopLeftGlobalPoints: [CGRect] {
        NSScreen.screens.map { screen in topLeftGlobalFrame(fromAppKitFrame: screen.visibleFrame) }
    }

    /// The visible frame of the screen showing this point, or the nearest one when the point is in a menu bar, the
    /// Dock or between displays, in top-left global points.
    static func visibleFrameInTopLeftGlobalPoints(nearestToTopLeftGlobalPoint topLeftGlobalPoint: CGPoint) -> CGRect {
        PillPlacementCalculator.visibleFrame(nearestTo: topLeftGlobalPoint, amongVisibleFrames: visibleFramesInTopLeftGlobalPoints)
            ?? topLeftGlobalFrame(fromAppKitFrame: fallbackVisibleFrame)
    }

    static func screen(containingCenterOfTopLeftGlobalFrame topLeftGlobalFrame: CGRect) -> NSScreen? {
        let appKitFrame = appKitFrame(fromTopLeftGlobalFrame: topLeftGlobalFrame)
        let appKitCenter = CGPoint(x: appKitFrame.midX, y: appKitFrame.midY)
        return NSScreen.screens.first { $0.frame.contains(appKitCenter) }
    }

    /// Lets the overlay follow a window Dotto itself moved (the user moving it pauses the run instead).
    static func frameInTopLeftGlobalPoints(ofWindowIdentifier windowIdentifier: UInt32) -> CGRect? {
        let windowInfoList = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(windowIdentifier)) as? [[String: Any]]
        return windowInfoList?.first.flatMap(frameInTopLeftGlobalPoints(ofWindowInfo:))
    }

    /// The frontmost on-screen window of the app at the normal window layer, skipping its panels and menus.
    static func frontmostNormalWindowFrameInTopLeftGlobalPoints(ownedByProcessIdentifier processIdentifier: pid_t) -> CGRect? {
        guard let windowInfoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let normalWindowLayer = 0
        let frontmostNormalWindowInfo = windowInfoList.first { windowInfo in
            (windowInfo[kCGWindowOwnerPID as String] as? Int32) == processIdentifier
                && (windowInfo[kCGWindowLayer as String] as? Int) == normalWindowLayer
        }
        return frontmostNormalWindowInfo.flatMap(frameInTopLeftGlobalPoints(ofWindowInfo:))
    }

    private static func frameInTopLeftGlobalPoints(ofWindowInfo windowInfo: [String: Any]) -> CGRect? {
        guard let windowBoundsDictionary = windowInfo[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: windowBoundsDictionary as CFDictionary)
    }
}
