import Foundation
import CoreGraphics

/// `parkedAtSummonOrigin` is the cursor before its run has a target window: planning and approval happen where the
/// user summoned Dotto. The placement policy never picks it; the presenter parks and unparks the cursor itself.
enum CursorSurface: Equatable, Sendable { case overlayOnTargetWindow, liveViewPanel, parkedAtSummonOrigin, hidden }

struct TargetWindowVisibility: Equatable, Sendable {
    /// On the active Space and not minimized.
    var isOnScreen: Bool
    /// 0…1 of the window's area not covered by windows above it.
    var visibleFraction: Double
    /// nil when there is no target point.
    var targetPointIsUnoccluded: Bool?
    var observedAtUptimeSeconds: TimeInterval
}

/// The cursor draws over the target window while enough of it is visible, and moves into the live-view panel
/// when other windows cover it. Three guards keep it from flapping while a window is dragged across the target:
/// - hysteresis: the overlay is left only below `visibleFractionToLeaveOverlay` and re-entered only above
///   `visibleFractionToEnterOverlay`, so a fraction hovering around one threshold never switches back and forth;
/// - stability: a switch applies only after the new surface has been preferred for `stabilitySeconds`;
/// - dwell: a surface stays at least `minimumDwellSeconds` once shown, unless the window left the screen
///   (then the overlay would show nothing at all).
struct CursorSurfacePlacementPolicy: Sendable {
    var visibleFractionToLeaveOverlay: Double = 0.45
    var visibleFractionToEnterOverlay: Double = 0.65
    var stabilitySeconds: TimeInterval = 0.4
    var minimumDwellSeconds: TimeInterval = 1.5
    private(set) var currentSurface: CursorSurface = .hidden
    private var pendingSurface: CursorSurface?
    private var pendingSurfaceFirstSeenAtUptimeSeconds: TimeInterval = 0
    private var currentSurfaceShownAtUptimeSeconds: TimeInterval = 0

    mutating func surface(for visibility: TargetWindowVisibility, cursorIsActive: Bool) -> CursorSurface {
        let preferredSurface = preferredSurface(for: visibility, cursorIsActive: cursorIsActive)
        // Showing or hiding the cursor is never delayed; only switching between the two visible surfaces is.
        if currentSurface == .hidden || preferredSurface == .hidden || preferredSurface == currentSurface {
            if preferredSurface != currentSurface { currentSurfaceShownAtUptimeSeconds = visibility.observedAtUptimeSeconds }
            currentSurface = preferredSurface
            pendingSurface = nil
            return currentSurface
        }
        if pendingSurface != preferredSurface {
            pendingSurface = preferredSurface
            pendingSurfaceFirstSeenAtUptimeSeconds = visibility.observedAtUptimeSeconds
            return currentSurface
        }
        let pendingSwitchIsStable = visibility.observedAtUptimeSeconds - pendingSurfaceFirstSeenAtUptimeSeconds >= stabilitySeconds
        let currentSurfaceHasDwelt = visibility.observedAtUptimeSeconds - currentSurfaceShownAtUptimeSeconds >= minimumDwellSeconds
            || !visibility.isOnScreen
        if pendingSwitchIsStable && currentSurfaceHasDwelt {
            currentSurface = preferredSurface
            currentSurfaceShownAtUptimeSeconds = visibility.observedAtUptimeSeconds
            pendingSurface = nil
        }
        return currentSurface
    }

    private func preferredSurface(for visibility: TargetWindowVisibility, cursorIsActive: Bool) -> CursorSurface {
        guard cursorIsActive else { return .hidden }
        guard visibility.isOnScreen, visibility.targetPointIsUnoccluded != false else { return .liveViewPanel }
        if currentSurface == .overlayOnTargetWindow {
            return visibility.visibleFraction < visibleFractionToLeaveOverlay ? .liveViewPanel : .overlayOnTargetWindow
        }
        return visibility.visibleFraction > visibleFractionToEnterOverlay ? .overlayOnTargetWindow : .liveViewPanel
    }

    /// Fraction of `windowFrame` not covered by the union of `occludingFrames`, sampled on a grid of cell centers.
    static func visibleFraction(of windowFrame: CGRect, occludingFrames: [CGRect], samplesPerAxis: Int = 16) -> Double {
        guard windowFrame.width > 0, windowFrame.height > 0, samplesPerAxis > 0 else { return 0 }
        let cellWidth = windowFrame.width / CGFloat(samplesPerAxis)
        let cellHeight = windowFrame.height / CGFloat(samplesPerAxis)
        var visibleSampleCount = 0
        for rowIndex in 0..<samplesPerAxis {
            for columnIndex in 0..<samplesPerAxis {
                let samplePoint = CGPoint(x: windowFrame.minX + (CGFloat(columnIndex) + 0.5) * cellWidth,
                                          y: windowFrame.minY + (CGFloat(rowIndex) + 0.5) * cellHeight)
                if !occludingFrames.contains(where: { $0.contains(samplePoint) }) { visibleSampleCount += 1 }
            }
        }
        return Double(visibleSampleCount) / Double(samplesPerAxis * samplesPerAxis)
    }
}
