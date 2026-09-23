import Foundation
import CoreGraphics

/// A capture of the task window only. Its pixels map onto the window's frame at capture time.
struct ScreenshotCapture: Equatable, Sendable {
    var jpegData: Data
    var pixelWidth: Int
    var pixelHeight: Int
    var capturedWindow: TargetWindowReference
    var capturedAt: Date
}

enum ScreenCoordinateConversion {
    // AppKit global: origin bottom-left of the primary display, y up.
    // Top-left global (CGEvent, AXPosition, SCWindow.frame): origin top-left of the primary display, y down.
    // Window-relative: points from the window's top-left corner, y down. click_point targets stay window-relative
    // until the click, so a window the user moved in the meantime is still hit in the same spot.
    static func windowRelativePoint(fromScreenshotPixel screenshotPixelPoint: CGPoint, in screenshotCapture: ScreenshotCapture) -> CGPoint {
        let windowSize = screenshotCapture.capturedWindow.frameInTopLeftGlobalPoints.size
        guard screenshotCapture.pixelWidth > 0, screenshotCapture.pixelHeight > 0 else { return .zero }
        return CGPoint(x: screenshotPixelPoint.x * windowSize.width / CGFloat(screenshotCapture.pixelWidth),
                       y: screenshotPixelPoint.y * windowSize.height / CGFloat(screenshotCapture.pixelHeight))
    }

    static func topLeftGlobalPoint(fromWindowRelativePoint windowRelativePoint: CGPoint,
                                   windowFrameInTopLeftGlobalPoints: CGRect) -> CGPoint {
        CGPoint(x: windowFrameInTopLeftGlobalPoints.minX + windowRelativePoint.x,
                y: windowFrameInTopLeftGlobalPoints.minY + windowRelativePoint.y)
    }

    static func windowRelativePoint(fromTopLeftGlobalPoint topLeftGlobalPoint: CGPoint,
                                    windowFrameInTopLeftGlobalPoints: CGRect) -> CGPoint {
        CGPoint(x: topLeftGlobalPoint.x - windowFrameInTopLeftGlobalPoints.minX,
                y: topLeftGlobalPoint.y - windowFrameInTopLeftGlobalPoints.minY)
    }

    static func appKitGlobalPoint(fromTopLeftGlobalPoint topLeftGlobalPoint: CGPoint, primaryDisplayHeightInPoints: CGFloat) -> CGPoint {
        CGPoint(x: topLeftGlobalPoint.x, y: primaryDisplayHeightInPoints - topLeftGlobalPoint.y)
    }

    static func centerOfTopLeftGlobalFrame(_ frameInTopLeftGlobalPoints: CGRect) -> CGPoint {
        CGPoint(x: frameInTopLeftGlobalPoints.midX, y: frameInTopLeftGlobalPoints.midY)
    }

    /// Never upscales, and rounds down so neither cap is exceeded: a window smaller than both caps is captured at
    /// its point size.
    static func screenshotPixelSize(fittingWindowSizeInPoints windowSizeInPoints: CGSize, maximumLongEdgePixels: Int,
                                    maximumTotalPixelCount: Int) -> CGSize {
        let longEdge = max(windowSizeInPoints.width, windowSizeInPoints.height)
        let area = windowSizeInPoints.width * windowSizeInPoints.height
        guard longEdge > 0, area > 0 else { return .zero }
        let longEdgeScaleFactor = CGFloat(maximumLongEdgePixels) / longEdge
        let pixelCountScaleFactor = (CGFloat(maximumTotalPixelCount) / area).squareRoot()
        let scaleFactor = min(1, longEdgeScaleFactor, pixelCountScaleFactor)
        return CGSize(width: max(1, (windowSizeInPoints.width * scaleFactor).rounded(.down)),
                      height: max(1, (windowSizeInPoints.height * scaleFactor).rounded(.down)))
    }

    static func isScreenshotPixelInsideImage(_ screenshotPixelPoint: CGPoint, in screenshotCapture: ScreenshotCapture) -> Bool {
        screenshotPixelPoint.x >= 0 && screenshotPixelPoint.y >= 0
            && screenshotPixelPoint.x < CGFloat(screenshotCapture.pixelWidth)
            && screenshotPixelPoint.y < CGFloat(screenshotCapture.pixelHeight)
    }
}
