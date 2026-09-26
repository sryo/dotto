import AppKit

/// Whether a pointer event lands on something Dotto drew. Dotto's panels are transparent windows with room around
/// their card for its shadow; the window server passes clicks on transparent pixels to the window behind, so a click
/// in that margin reaches the user's app and must count as theirs. The frame alone can't tell, so the pixel under the
/// point is rendered from the window's own view and its opacity decides (about a millisecond per sample).
@MainActor enum DottoWindowPointerHitTest {
    /// Shadows fade from about 0.3 next to the card to nothing, and cards are drawn opaque.
    private static let minimumContentOpacity: CGFloat = 0.5

    static func isTopLeftGlobalPointOverThisAppWindowContent(_ topLeftGlobalPoint: CGPoint) -> Bool {
        // Unknown only before any display was seen; then the point can't be placed, and a click that might be on
        // Dotto's own button must never count as the user taking over.
        guard let primaryDisplayHeightInPoints = PrimaryDisplayHeightReader.primaryDisplayHeightInPoints else { return true }
        let appKitGlobalPoint = ScreenCoordinateConversion.appKitGlobalPoint(
            fromTopLeftGlobalPoint: topLeftGlobalPoint, primaryDisplayHeightInPoints: primaryDisplayHeightInPoints)
        return NSApp.windows.contains { thisAppWindow in
            thisAppWindow.isVisible && !thisAppWindow.ignoresMouseEvents && thisAppWindow.frame.contains(appKitGlobalPoint)
                && windowDrawsContent(thisAppWindow, atAppKitGlobalPoint: appKitGlobalPoint)
        }
    }

    /// When the pixel can't be rendered, the whole frame counts, as before: a click on Dotto's own button must never
    /// be mistaken for the user taking over.
    private static func windowDrawsContent(_ thisAppWindow: NSWindow, atAppKitGlobalPoint appKitGlobalPoint: CGPoint) -> Bool {
        guard !thisAppWindow.isOpaque, let contentView = thisAppWindow.contentView else { return true }
        let pointInWindow = thisAppWindow.convertPoint(fromScreen: appKitGlobalPoint)
        let pointInContentView = contentView.convert(pointInWindow, from: nil)
        let sampledPixelRect = NSRect(x: pointInContentView.x.rounded(.down), y: pointInContentView.y.rounded(.down), width: 1, height: 1)
        guard contentView.bounds.intersects(sampledPixelRect),
              let sampledPixelBitmap = contentView.bitmapImageRepForCachingDisplay(in: sampledPixelRect) else { return true }
        contentView.cacheDisplay(in: sampledPixelRect, to: sampledPixelBitmap)
        guard let sampledPixelColor = sampledPixelBitmap.colorAt(x: 0, y: 0) else { return true }
        return sampledPixelColor.alphaComponent >= minimumContentOpacity
    }
}
