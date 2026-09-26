import Foundation
import CoreGraphics

/// The primary display's height flips window-server (top-left, y down) coordinates into AppKit's (bottom-left, y up)
/// ones. A height of 0 would silently put every converted point off screen, so the height is never guessed as 0: while
/// displays are reconfiguring, or when no display answers, the last height known to be right is used instead.
enum PrimaryDisplayHeightResolution {
    static func resolve(coreGraphicsMainDisplayHeight: CGFloat?, appKitPrimaryScreenHeight: CGFloat?,
                        lastKnownHeight: CGFloat?, displaysAreReconfiguring: Bool) -> CGFloat? {
        let usableLastKnownHeight = lastKnownHeight.flatMap(positiveHeight)
        // Mid-reconfiguration both live answers can describe a half-applied layout.
        if displaysAreReconfiguring, let usableLastKnownHeight { return usableLastKnownHeight }
        return coreGraphicsMainDisplayHeight.flatMap(positiveHeight)
            ?? appKitPrimaryScreenHeight.flatMap(positiveHeight)
            ?? usableLastKnownHeight
    }

    private static func positiveHeight(_ height: CGFloat) -> CGFloat? {
        height.isFinite && height > 0 ? height : nil
    }
}

/// What the display reconfiguration observer last learned, shared by every reader of the primary display height.
/// Readers live in Platform and UI, which can't see each other, so the value lives here.
final class PrimaryDisplayHeightCache: @unchecked Sendable {
    static let shared = PrimaryDisplayHeightCache()

    private let lock = NSLock()
    private var storedLastKnownHeight: CGFloat?
    private var storedDisplaysAreReconfiguring = false

    var lastKnownHeight: CGFloat? { lock.withLock { storedLastKnownHeight } }
    var displaysAreReconfiguring: Bool { lock.withLock { storedDisplaysAreReconfiguring } }

    /// Heights of 0 or less are ignored: they are what a display that is going away reports.
    func recordSettledHeight(_ height: CGFloat) {
        guard height.isFinite, height > 0 else { return }
        lock.withLock { storedLastKnownHeight = height }
    }

    func setDisplaysAreReconfiguring(_ displaysAreReconfiguring: Bool) {
        lock.withLock { storedDisplaysAreReconfiguring = displaysAreReconfiguring }
    }
}
