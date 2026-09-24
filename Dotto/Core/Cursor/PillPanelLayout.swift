import Foundation
import CoreGraphics

/// The clickable panel that draws the cursor's status pill keeps one size, large enough for the largest pill (the
/// maximum width, wrapped to two lines with its buttons below) plus room for its shadow, so the pill can change size
/// inside it with an animation instead of waiting for the window to be resized. The pill sits in the panel's corner
/// that faces the cursor's tip (top-left while it hangs right of and below the tip, top-right once it flipped left
/// of it, and so on), so that corner stays put while the pill grows or shrinks away from the tip.
/// Frames are in top-left global points (y grows downward); frames in the panel are from its top-left corner.
struct PillPanelLayout: Equatable, Sendable {
    /// The largest pill as drawn on screen, after the cursor's scale.
    var maximumPillSize: CGSize
    /// Room around the pill for its shadow and its attention hop.
    var shadowPadding: CGFloat

    /// Fixed while the pill fits the maximum; a pill that is somehow larger still gets a panel that holds it.
    func panelSize(forPillSize pillSize: CGSize) -> CGSize {
        CGSize(width: max(maximumPillSize.width, pillSize.width) + shadowPadding * 2,
               height: max(maximumPillSize.height, pillSize.height) + shadowPadding * 2)
    }

    /// The panel whose tip-facing corner, inset by the shadow padding, is the placed pill's tip-facing corner.
    func panelFrame(for pillPlacement: PillPlacement) -> CGRect {
        let pillFrame = pillPlacement.pillFrame
        let panelSize = panelSize(forPillSize: pillFrame.size)
        let panelOriginX = pillPlacement.horizontalSide == .rightOfTip
            ? pillFrame.minX - shadowPadding
            : pillFrame.maxX + shadowPadding - panelSize.width
        let panelOriginY = pillPlacement.verticalSide == .belowTip
            ? pillFrame.minY - shadowPadding
            : pillFrame.maxY + shadowPadding - panelSize.height
        return CGRect(origin: CGPoint(x: panelOriginX, y: panelOriginY), size: panelSize)
    }

    /// Where a pill of `pillSize` is drawn inside a panel of `panelSize`: in the corner that faces the tip.
    func pillFrameInPanel(pillSize: CGSize, horizontalSide: PillHorizontalSide, verticalSide: PillVerticalSide,
                          panelSize: CGSize) -> CGRect {
        let pillOriginX = horizontalSide == .rightOfTip ? shadowPadding : panelSize.width - shadowPadding - pillSize.width
        let pillOriginY = verticalSide == .belowTip ? shadowPadding : panelSize.height - shadowPadding - pillSize.height
        return CGRect(origin: CGPoint(x: pillOriginX, y: pillOriginY), size: pillSize)
    }
}
