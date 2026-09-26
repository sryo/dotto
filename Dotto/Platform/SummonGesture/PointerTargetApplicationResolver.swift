import AppKit

/// Which app a circle summon is for: the owner of the topmost window under the pointer, not merely the frontmost app,
/// so circling over a background window targets that window's app. Reads window bounds and owners only, which need
/// no Screen Recording permission.
enum PointerTargetApplicationResolver {
    /// The app owning the topmost ordinary or floating window at the point. Dotto's own windows (the ring overlay,
    /// the cursor overlay), other apps' overlays, system shields, menus and the Dock are skipped. nil over the
    /// desktop or when no window is there.
    static func applicationOwningTopmostWindow(atTopLeftGlobalPoint topLeftGlobalPoint: CGPoint) -> TargetApplicationReference? {
        let ownProcessIdentifier = getpid()
        for windowInfo in WindowListEntryClassification.onScreenWindowList() {
            guard let windowOwnerProcessIdentifier = WindowListEntryClassification.ownerProcessIdentifier(of: windowInfo),
                  windowOwnerProcessIdentifier != ownProcessIdentifier,
                  let windowFrame = WindowListEntryClassification.frameInTopLeftGlobalPoints(of: windowInfo),
                  windowFrame.contains(topLeftGlobalPoint) else { continue }
            guard WindowListEntryClassification.isNormalOrFloatingAppWindow(windowInfo) else { continue }
            guard let owningApplication = NSRunningApplication(processIdentifier: windowOwnerProcessIdentifier),
                  !owningApplication.isTerminated else { return nil }
            return TargetApplicationReference(
                processIdentifier: windowOwnerProcessIdentifier,
                applicationName: owningApplication.localizedName ?? "this app",
                bundleIdentifier: owningApplication.bundleIdentifier)
        }
        return nil
    }

    /// Whether the frontmost app fills the display the point is on. The window list has no full-screen flag, so its
    /// largest normal-level window on that display covering the whole display (menu bar included) counts: games,
    /// presentations and full-screen video. A full-screen app on another display doesn't count here, and a small
    /// palette in front of a windowed document doesn't make it full screen (`SummonGestureDisplayGeometry`).
    static func frontmostApplicationIsFullScreen(onDisplayContainingTopLeftGlobalPoint topLeftGlobalPoint: CGPoint) -> Bool {
        guard let frontmostProcessIdentifier = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let displayFrame = displayFrame(containingTopLeftGlobalPoint: topLeftGlobalPoint) else { return false }
        let frontmostApplicationWindowFrames = WindowListEntryClassification.onScreenWindowList().compactMap { windowInfo -> CGRect? in
            guard WindowListEntryClassification.ownerProcessIdentifier(of: windowInfo) == frontmostProcessIdentifier,
                  WindowListEntryClassification.layer(of: windowInfo) == WindowListEntryClassification.normalWindowLayer,
                  !WindowListEntryClassification.isFullyTransparent(windowInfo) else { return nil }
            return WindowListEntryClassification.frameInTopLeftGlobalPoints(of: windowInfo)
        }
        return SummonGestureDisplayGeometry.largestWindowCoversDisplay(displayFrame: displayFrame,
                                                                       applicationWindowFrames: frontmostApplicationWindowFrames)
    }

    /// Where the pointer is now, in top-left global points. Read only when eligibility is re-evaluated, never per move.
    static func currentTopLeftGlobalPointerLocation() -> CGPoint {
        let appKitGlobalLocation = NSEvent.mouseLocation
        // Only unknown before any display was ever seen; then no display can hold the point either way.
        let primaryDisplayHeightInPoints = PrimaryDisplayHeightReader.primaryDisplayHeightInPoints ?? 0
        return CGPoint(x: appKitGlobalLocation.x, y: primaryDisplayHeightInPoints - appKitGlobalLocation.y)
    }

    /// The active display holding the point in top-left global points, edges included.
    private static func displayFrame(containingTopLeftGlobalPoint topLeftGlobalPoint: CGPoint) -> CGRect? {
        var activeDisplayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &activeDisplayCount) == .success, activeDisplayCount > 0 else { return nil }
        var activeDisplayIdentifiers = [CGDirectDisplayID](repeating: 0, count: Int(activeDisplayCount))
        guard CGGetActiveDisplayList(activeDisplayCount, &activeDisplayIdentifiers, &activeDisplayCount) == .success else { return nil }
        let activeDisplayFrames = activeDisplayIdentifiers.prefix(Int(activeDisplayCount)).map(CGDisplayBounds)
        return SummonGestureDisplayGeometry.indexOfDisplay(containing: topLeftGlobalPoint, displayFrames: activeDisplayFrames)
            .map { displayIndex in activeDisplayFrames[displayIndex] }
    }
}
