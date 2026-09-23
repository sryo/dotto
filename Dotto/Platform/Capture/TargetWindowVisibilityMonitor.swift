import AppKit

/// Tells the cursor controller how much of the target window the user can see, so the cursor is drawn over the
/// window while it is visible and moves into the live view when it isn't. Window bounds and owners need no Screen
/// Recording permission.
@MainActor final class TargetWindowVisibilityMonitor {
    private static let pollIntervalSeconds: TimeInterval = 0.25

    var onVisibilityChanged: ((TargetWindowVisibility) -> Void)?

    private var pollTimer: Timer?
    private var lastReportedVisibility: TargetWindowVisibility?

    func startMonitoring(_ targetWindow: TargetWindowReference, targetPointInWindow: @escaping () -> CGPoint?) {
        stopMonitoring()
        let visibilityPollTimer = Timer(timeInterval: Self.pollIntervalSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reportVisibilityIfChanged(of: targetWindow.windowIdentifier, targetPointInWindow: targetPointInWindow())
            }
        }
        RunLoop.main.add(visibilityPollTimer, forMode: .common)
        pollTimer = visibilityPollTimer
        reportVisibilityIfChanged(of: targetWindow.windowIdentifier, targetPointInWindow: targetPointInWindow())
    }

    func stopMonitoring() {
        pollTimer?.invalidate()
        pollTimer = nil
        lastReportedVisibility = nil
    }

    private func reportVisibilityIfChanged(of windowIdentifier: UInt32, targetPointInWindow: CGPoint?) {
        let visibility = Self.currentVisibility(of: windowIdentifier, targetPointInWindow: targetPointInWindow)
        var comparableVisibility = visibility
        comparableVisibility.observedAtUptimeSeconds = lastReportedVisibility?.observedAtUptimeSeconds ?? 0
        guard comparableVisibility != lastReportedVisibility else { return }
        lastReportedVisibility = visibility
        onVisibilityChanged?(visibility)
    }

    private static func currentVisibility(of windowIdentifier: UInt32, targetPointInWindow: CGPoint?) -> TargetWindowVisibility {
        let observedAtUptimeSeconds = ProcessInfo.processInfo.systemUptime
        guard let targetWindowInfo = WindowListEntryClassification.windowListEntry(ofWindowWithIdentifier: windowIdentifier),
              WindowListEntryClassification.isOnScreen(targetWindowInfo),
              let targetWindowFrame = WindowListEntryClassification.frameInTopLeftGlobalPoints(of: targetWindowInfo) else {
            return TargetWindowVisibility(isOnScreen: false, visibleFraction: 0,
                                          targetPointIsUnoccluded: targetPointInWindow == nil ? nil : false,
                                          observedAtUptimeSeconds: observedAtUptimeSeconds)
        }
        // Only ordinary app windows and floating palettes hide the target from the user. Click-through overlays that
        // cover the display, system shields, menus and the Dock would otherwise push the cursor into the live view for
        // as long as they are up.
        let ownProcessIdentifier = getpid()
        let windowsAboveTarget = WindowListEntryClassification.onScreenWindowList(above: windowIdentifier)
        let occludingFrames = windowsAboveTarget.compactMap { windowInfo -> CGRect? in
            guard WindowListEntryClassification.ownerProcessIdentifier(of: windowInfo) != ownProcessIdentifier,
                  WindowListEntryClassification.isNormalOrFloatingAppWindow(windowInfo) else { return nil }
            return WindowListEntryClassification.frameInTopLeftGlobalPoints(of: windowInfo)
        }
        let targetPointIsUnoccluded = targetPointInWindow.map { windowRelativePoint in
            let targetPointInTopLeftGlobalPoints = ScreenCoordinateConversion.topLeftGlobalPoint(
                fromWindowRelativePoint: windowRelativePoint, windowFrameInTopLeftGlobalPoints: targetWindowFrame)
            return !occludingFrames.contains { $0.contains(targetPointInTopLeftGlobalPoints) }
        }
        return TargetWindowVisibility(
            isOnScreen: true,
            visibleFraction: CursorSurfacePlacementPolicy.visibleFraction(of: targetWindowFrame, occludingFrames: occludingFrames),
            targetPointIsUnoccluded: targetPointIsUnoccluded, observedAtUptimeSeconds: observedAtUptimeSeconds)
    }
}
