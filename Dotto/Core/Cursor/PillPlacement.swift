import Foundation
import CoreGraphics

enum PillHorizontalSide: Equatable, Sendable { case rightOfTip, leftOfTip }
enum PillVerticalSide: Equatable, Sendable { case belowTip, aboveTip }

struct PillPlacement: Equatable, Sendable {
    var pillFrame: CGRect
    var horizontalSide: PillHorizontalSide
    var verticalSide: PillVerticalSide

    /// From the tip to the pill's top-left corner, for views that draw the pill at an offset from the tip.
    func offsetFromTip(_ tipPoint: CGPoint) -> CGSize {
        CGSize(width: pillFrame.minX - tipPoint.x, height: pillFrame.minY - tipPoint.y)
    }
}

/// Places a pill that hangs from a point (the cursor's tip, the pointer): below and to the right of it by default,
/// flipped to the left of or above the point when it wouldn't fit inside the visible frame of the point's screen, and
/// clamped inside that frame as a last resort. Flipping mirrors the offset, so the pill never covers the point it
/// hangs from while it fits on either side. Works in any one coordinate space whose y grows downward (top-left global
/// points, or a view's own coordinates).
struct PillPlacementCalculator: Sendable {
    /// The pill never comes closer than this to the visible frame's edges (the menu bar and the Dock are already
    /// outside the visible frame).
    var visibleFrameInset: CGFloat = 8

    /// `preferredOffsetFromTip` goes from the tip to the pill's top-left corner when it sits right of and below the
    /// tip. Passing the previous placement back keeps its sides while the pill still fits there, so a pill whose text
    /// grows or shrinks by a few points near an edge doesn't flip back and forth.
    func placement(forPillSize pillSize: CGSize, tipPoint: CGPoint, preferredOffsetFromTip: CGSize, visibleFrame: CGRect,
                   previousPlacement: PillPlacement? = nil) -> PillPlacement {
        let allowedFrame = visibleFrame.insetBy(dx: visibleFrameInset, dy: visibleFrameInset)

        let rightOfTipOriginX = tipPoint.x + preferredOffsetFromTip.width
        let leftOfTipOriginX = tipPoint.x - preferredOffsetFromTip.width - pillSize.width
        let roomRightOfTip = allowedFrame.maxX - rightOfTipOriginX
        let roomLeftOfTip = (tipPoint.x - preferredOffsetFromTip.width) - allowedFrame.minX
        let preferredHorizontalSide = previousPlacement?.horizontalSide ?? .rightOfTip
        let horizontalSide = chosenSide(
            preferred: preferredHorizontalSide,
            alternative: preferredHorizontalSide == .rightOfTip ? PillHorizontalSide.leftOfTip : .rightOfTip,
            roomForPill: { horizontalSide in horizontalSide == .rightOfTip ? roomRightOfTip : roomLeftOfTip },
            pillExtent: pillSize.width)

        let belowTipOriginY = tipPoint.y + preferredOffsetFromTip.height
        let aboveTipOriginY = tipPoint.y - preferredOffsetFromTip.height - pillSize.height
        let roomBelowTip = allowedFrame.maxY - belowTipOriginY
        let roomAboveTip = (tipPoint.y - preferredOffsetFromTip.height) - allowedFrame.minY
        let preferredVerticalSide = previousPlacement?.verticalSide ?? .belowTip
        let verticalSide = chosenSide(
            preferred: preferredVerticalSide,
            alternative: preferredVerticalSide == .belowTip ? PillVerticalSide.aboveTip : .belowTip,
            roomForPill: { verticalSide in verticalSide == .belowTip ? roomBelowTip : roomAboveTip },
            pillExtent: pillSize.height)

        let unclampedFrame = CGRect(x: horizontalSide == .rightOfTip ? rightOfTipOriginX : leftOfTipOriginX,
                                    y: verticalSide == .belowTip ? belowTipOriginY : aboveTipOriginY,
                                    width: pillSize.width, height: pillSize.height)
        return PillPlacement(pillFrame: Self.clamped(unclampedFrame, into: allowedFrame),
                             horizontalSide: horizontalSide, verticalSide: verticalSide)
    }

    /// The same frame moved inside the inset visible frame, for panels that keep a corner where the user put them
    /// (the live view) but must not grow off screen.
    func frameKeptInside(visibleFrame: CGRect, frame: CGRect) -> CGRect {
        Self.clamped(frame, into: visibleFrame.insetBy(dx: visibleFrameInset, dy: visibleFrameInset))
    }

    /// The visible frame of the screen showing `point`, edges included; when no visible frame holds it (the point is
    /// in a menu bar or the Dock, or between displays), the nearest one. nil only when there are no screens.
    static func visibleFrame(nearestTo point: CGPoint, amongVisibleFrames visibleFrames: [CGRect]) -> CGRect? {
        if let containingVisibleFrame = visibleFrames.first(where: { visibleFrame in
            point.x >= visibleFrame.minX && point.x <= visibleFrame.maxX
                && point.y >= visibleFrame.minY && point.y <= visibleFrame.maxY
        }) {
            return containingVisibleFrame
        }
        return visibleFrames.min { first, second in
            squaredDistance(from: point, to: first) < squaredDistance(from: point, to: second)
        }
    }

    private static func squaredDistance(from point: CGPoint, to frame: CGRect) -> CGFloat {
        let horizontalDistance = max(frame.minX - point.x, 0, point.x - frame.maxX)
        let verticalDistance = max(frame.minY - point.y, 0, point.y - frame.maxY)
        return horizontalDistance * horizontalDistance + verticalDistance * verticalDistance
    }

    /// Keeps the preferred side while the pill fits there; otherwise the other side if it fits; when neither fits,
    /// the roomier one.
    private func chosenSide<Side>(preferred: Side, alternative: Side, roomForPill: (Side) -> CGFloat, pillExtent: CGFloat) -> Side {
        if roomForPill(preferred) >= pillExtent { return preferred }
        if roomForPill(alternative) >= pillExtent { return alternative }
        return roomForPill(alternative) > roomForPill(preferred) ? alternative : preferred
    }

    /// Moves the frame inside `allowedFrame` without resizing it; a frame larger than `allowedFrame` keeps its
    /// top-left corner inside, so the start of the pill's text and its first buttons stay readable.
    private static func clamped(_ frame: CGRect, into allowedFrame: CGRect) -> CGRect {
        let clampedOriginX = min(max(frame.minX, allowedFrame.minX), max(allowedFrame.minX, allowedFrame.maxX - frame.width))
        let clampedOriginY = min(max(frame.minY, allowedFrame.minY), max(allowedFrame.minY, allowedFrame.maxY - frame.height))
        return CGRect(x: clampedOriginX, y: clampedOriginY, width: frame.width, height: frame.height)
    }
}
