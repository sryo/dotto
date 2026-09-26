import AppKit
import CoreGraphics

/// The primary display's height for Platform's coordinate flips, never 0 (`PrimaryDisplayHeightResolution`).
enum PrimaryDisplayHeightReader {
    static var primaryDisplayHeightInPoints: CGFloat? {
        let cache = PrimaryDisplayHeightCache.shared
        return PrimaryDisplayHeightResolution.resolve(
            coreGraphicsMainDisplayHeight: CGDisplayBounds(CGMainDisplayID()).height,
            appKitPrimaryScreenHeight: NSScreen.screens.first?.frame.height,
            lastKnownHeight: cache.lastKnownHeight, displaysAreReconfiguring: cache.displaysAreReconfiguring)
    }
}
