import CoreGraphics
import Foundation

/// Which display the pointer is on, and whether the frontmost app fills that display.
enum SummonGestureDisplayGeometry {
    /// The display frame holding the point, counting its right and bottom edges: the pointer can rest exactly on a
    /// display's far edge (the bottom row flips to `maxY`), which `CGRect.contains` leaves out. A frame that holds the
    /// point strictly inside wins over one that only touches it, so a shared edge between two displays is decided by
    /// the one the point is actually on. Works in any one coordinate space, top-left or AppKit's bottom-left.
    static func indexOfDisplay(containing point: CGPoint, displayFrames: [CGRect]) -> Int? {
        if let interiorDisplayIndex = displayFrames.firstIndex(where: { displayFrame in displayFrame.contains(point) }) {
            return interiorDisplayIndex
        }
        return displayFrames.firstIndex { displayFrame in
            point.x >= displayFrame.minX && point.x <= displayFrame.maxX
                && point.y >= displayFrame.minY && point.y <= displayFrame.maxY
        }
    }

    /// Whether the app is full screen on this display: its largest window there (by area on the display) covers the
    /// whole display, menu bar included. Taking the largest rather than the frontmost window means a small palette
    /// or inspector in front of a windowed document doesn't decide it, and a window on another display (a
    /// full-screen video there) has no area here and is ignored.
    static func largestWindowCoversDisplay(displayFrame: CGRect, applicationWindowFrames: [CGRect]) -> Bool {
        let windowFramesWithAreaOnDisplay = applicationWindowFrames.map { windowFrame -> (windowFrame: CGRect, areaOnDisplay: CGFloat) in
            let overlap = windowFrame.intersection(displayFrame)
            return (windowFrame, overlap.isNull ? 0 : overlap.width * overlap.height)
        }
        guard let largestWindow = windowFramesWithAreaOnDisplay.max(by: { first, second in first.areaOnDisplay < second.areaOnDisplay }),
              largestWindow.areaOnDisplay > 0 else { return false }
        return largestWindow.windowFrame.integral.contains(displayFrame.integral)
    }
}
