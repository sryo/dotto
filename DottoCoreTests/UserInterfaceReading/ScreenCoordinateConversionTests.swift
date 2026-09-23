import Foundation
import CoreGraphics

private func makeWindowCapture(windowFrame: CGRect, pixelWidth: Int, pixelHeight: Int) -> ScreenshotCapture {
    ScreenshotCapture(jpegData: Data(), pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                      capturedWindow: TargetWindowReference(processIdentifier: 500, windowIdentifier: 7, frameInTopLeftGlobalPoints: windowFrame),
                      capturedAt: Date(timeIntervalSince1970: 0))
}

let screenCoordinateConversionTestSuite = CoreTestSuite(name: "ScreenCoordinateConversion", testCases: [
    CoreTestCase(name: "screenshot pixels map to window-relative points on a 1280×800 capture of a 1440×900 window") {
        let capture = makeWindowCapture(windowFrame: CGRect(x: 200, y: 100, width: 1440, height: 900), pixelWidth: 1280, pixelHeight: 800)
        try expectEqual(ScreenCoordinateConversion.windowRelativePoint(fromScreenshotPixel: .zero, in: capture), .zero)
        try expectEqual(ScreenCoordinateConversion.windowRelativePoint(fromScreenshotPixel: CGPoint(x: 640, y: 400), in: capture),
                        CGPoint(x: 720, y: 450))
        try expectEqual(ScreenCoordinateConversion.windowRelativePoint(fromScreenshotPixel: CGPoint(x: 1280, y: 800), in: capture),
                        CGPoint(x: 1440, y: 900))
    },
    CoreTestCase(name: "a moved window changes the global point but not the window-relative one") {
        let capture = makeWindowCapture(windowFrame: CGRect(x: 200, y: 100, width: 1440, height: 900), pixelWidth: 1280, pixelHeight: 800)
        let windowRelativePoint = ScreenCoordinateConversion.windowRelativePoint(fromScreenshotPixel: CGPoint(x: 640, y: 400), in: capture)
        try expectEqual(ScreenCoordinateConversion.topLeftGlobalPoint(fromWindowRelativePoint: windowRelativePoint,
                                                                      windowFrameInTopLeftGlobalPoints: CGRect(x: 200, y: 100, width: 1440, height: 900)),
                        CGPoint(x: 920, y: 550))
        let movedWindowFrame = CGRect(x: -1500, y: 300, width: 1440, height: 900)
        let movedGlobalPoint = ScreenCoordinateConversion.topLeftGlobalPoint(fromWindowRelativePoint: windowRelativePoint,
                                                                             windowFrameInTopLeftGlobalPoints: movedWindowFrame)
        try expectEqual(movedGlobalPoint, CGPoint(x: -780, y: 750))
        try expectEqual(ScreenCoordinateConversion.windowRelativePoint(fromTopLeftGlobalPoint: movedGlobalPoint,
                                                                       windowFrameInTopLeftGlobalPoints: movedWindowFrame),
                        windowRelativePoint)
    },
    CoreTestCase(name: "top-left and AppKit global points convert with the primary display height") {
        try expectEqual(ScreenCoordinateConversion.appKitGlobalPoint(fromTopLeftGlobalPoint: CGPoint(x: 10, y: 100), primaryDisplayHeightInPoints: 982),
                        CGPoint(x: 10, y: 882))
    },
    CoreTestCase(name: "pixel sizing obeys the long-edge and total-pixel caps, never upscales and rounds down") {
        try expectEqual(ScreenCoordinateConversion.screenshotPixelSize(fittingWindowSizeInPoints: CGSize(width: 1440, height: 900),
                                                                       maximumLongEdgePixels: 1280, maximumTotalPixelCount: 1_150_000),
                        CGSize(width: 1280, height: 800))
        // 1280×1280 would be 1.64 MP, so the pixel cap wins: √(1_150_000 / 2_560_000) × 1600 = 1072.4…
        try expectEqual(ScreenCoordinateConversion.screenshotPixelSize(fittingWindowSizeInPoints: CGSize(width: 1600, height: 1600),
                                                                       maximumLongEdgePixels: 1280, maximumTotalPixelCount: 1_150_000),
                        CGSize(width: 1072, height: 1072))
        try expectEqual(ScreenCoordinateConversion.screenshotPixelSize(fittingWindowSizeInPoints: CGSize(width: 2000, height: 667),
                                                                       maximumLongEdgePixels: 1000, maximumTotalPixelCount: 10_000_000),
                        CGSize(width: 1000, height: 333))
        try expectEqual(ScreenCoordinateConversion.screenshotPixelSize(fittingWindowSizeInPoints: CGSize(width: 800, height: 600),
                                                                       maximumLongEdgePixels: 1280, maximumTotalPixelCount: 1_150_000),
                        CGSize(width: 800, height: 600))
        try expectEqual(ScreenCoordinateConversion.screenshotPixelSize(fittingWindowSizeInPoints: .zero,
                                                                       maximumLongEdgePixels: 1280, maximumTotalPixelCount: 1_150_000), .zero)
    },
])
