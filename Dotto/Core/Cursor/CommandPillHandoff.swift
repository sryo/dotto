import Foundation
import CoreGraphics

/// The command pill's capsule at the moment a command is submitted from it, and the sides of the pointer it hung on,
/// in top-left global points. The cursor's status pill takes the capsule's place, so the user sees one bar change
/// instead of one bar vanishing and another appearing elsewhere: the two share the edge that faces the tip (the left
/// edge while the capsule is right of the tip, the right edge once it flipped left of it) and their vertical center
/// (the capsule is taller than the status pill). The pointer the command pill hung from is the cursor's tip.
struct CommandPillHandoff: Equatable, Sendable {
    var capsuleFrame: CGRect
    var horizontalSide: PillHorizontalSide
    var verticalSide: PillVerticalSide

    /// Where a status pill of this size sits when it takes the capsule's place.
    func statusPillFrame(forStatusPillSize statusPillSize: CGSize) -> CGRect {
        let originX = horizontalSide == .rightOfTip ? capsuleFrame.minX : capsuleFrame.maxX - statusPillSize.width
        return CGRect(x: originX, y: capsuleFrame.midY - statusPillSize.height / 2,
                      width: statusPillSize.width, height: statusPillSize.height)
    }

    /// Where the status pill sits once its size changed from that of `heldStatusPillFrame` (its text changed while the
    /// command pill morphed into it): the shift the placement gave the held frame (none, unless it was pushed back
    /// inside the screen) applies to the new size too.
    func statusPillFrame(forStatusPillSize statusPillSize: CGSize, heldStatusPillFrame: CGRect) -> CGRect {
        let unshiftedHeldFrame = statusPillFrame(forStatusPillSize: heldStatusPillFrame.size)
        return statusPillFrame(forStatusPillSize: statusPillSize)
            .offsetBy(dx: heldStatusPillFrame.minX - unshiftedHeldFrame.minX, dy: heldStatusPillFrame.minY - unshiftedHeldFrame.minY)
    }

    /// The offset to hand `PillPlacementCalculator` (with `sidesPlacement` as the previous placement) so that it puts
    /// the status pill at `statusPillFrame(forStatusPillSize:)`. The calculator mirrors the offset on a flipped side,
    /// so it is measured from the tip to the pill's tip-facing edges.
    func preferredOffsetFromTip(forStatusPillSize statusPillSize: CGSize, tipPoint: CGPoint) -> CGSize {
        let alignedStatusPillFrame = statusPillFrame(forStatusPillSize: statusPillSize)
        let horizontalOffset = horizontalSide == .rightOfTip
            ? alignedStatusPillFrame.minX - tipPoint.x
            : tipPoint.x - alignedStatusPillFrame.maxX
        let verticalOffset = verticalSide == .belowTip
            ? alignedStatusPillFrame.minY - tipPoint.y
            : tipPoint.y - alignedStatusPillFrame.maxY
        return CGSize(width: horizontalOffset, height: verticalOffset)
    }

    /// Keeps the status pill on the sides the command pill flipped to.
    var sidesPlacement: PillPlacement {
        PillPlacement(pillFrame: capsuleFrame, horizontalSide: horizontalSide, verticalSide: verticalSide)
    }

    /// The command pill's offset from the pointer that puts its capsule where the status pill hangs from the cursor's
    /// tip (right of and below it, vertically centered on it), so the handoff barely moves the status pill from its
    /// usual place and the cursor's reading ring stays clear of both.
    static func commandPillOffsetFromPointer(statusPillOffsetFromTip: CGSize, statusPillHeight: CGFloat,
                                             capsuleHeight: CGFloat) -> CGSize {
        CGSize(width: statusPillOffsetFromTip.width,
               height: statusPillOffsetFromTip.height + (statusPillHeight - capsuleHeight) / 2)
    }

    /// The area the morph from capsule to status pill is drawn in: the command pill's whole content (the capsule and
    /// the hint under it) and the status pill it becomes, with room for their shadows.
    static func morphCanvasFrame(commandPillContentFrame: CGRect, statusPillFrame: CGRect, shadowMargin: CGFloat) -> CGRect {
        commandPillContentFrame.union(statusPillFrame).insetBy(dx: -shadowMargin, dy: -shadowMargin)
    }
}
