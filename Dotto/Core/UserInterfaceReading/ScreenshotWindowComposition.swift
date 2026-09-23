import Foundation
import CoreGraphics

/// One window as the capture code sees it, in top-left global points.
struct ScreenshotCandidateWindow: Equatable, Sendable {
    var windowIdentifier: UInt32
    var ownerProcessIdentifier: Int32?
    var windowLayer: Int
    var frameInTopLeftGlobalPoints: CGRect
    var isOnScreen: Bool
}

enum ScreenshotWindowComposition {
    /// The target's own windows that cover the task window (its sheets, popovers and open menus) are drawn over it, so
    /// the model sees what a click at a pixel will hit. Only windows really in front of it count: a Get Info window or
    /// a second document window behind it would otherwise be painted on top, and a click aimed at it lands on the task
    /// window's content instead.
    static func windowsToDrawOverTaskWindow(_ candidateWindows: [ScreenshotCandidateWindow], taskWindow: ScreenshotCandidateWindow,
                                            windowIdentifiersInFrontOfTaskWindow: Set<UInt32>) -> [ScreenshotCandidateWindow] {
        candidateWindows.filter { candidateWindow in
            candidateWindow.windowIdentifier != taskWindow.windowIdentifier
                && candidateWindow.ownerProcessIdentifier == taskWindow.ownerProcessIdentifier
                && candidateWindow.isOnScreen
                && candidateWindow.windowLayer >= taskWindow.windowLayer
                && candidateWindow.frameInTopLeftGlobalPoints.intersects(taskWindow.frameInTopLeftGlobalPoints)
                && windowIdentifiersInFrontOfTaskWindow.contains(candidateWindow.windowIdentifier)
        }
    }
}
