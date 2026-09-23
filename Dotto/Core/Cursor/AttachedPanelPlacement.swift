import Foundation
import CoreGraphics

/// What a panel that belongs to the cursor (the checklist) hangs from. Every frame is in top-left global points
/// (the primary display's top-left corner is the origin and y grows downward).
enum AttachedPanelAnchor: Equatable, Sendable {
    /// Beside the cursor: the panel's tail aims at `anchorPoint` (the cursor's tip), and the panel never covers
    /// `keepClearFrame` (the tip, its ring and its pill).
    case besideCursor(anchorPoint: CGPoint, keepClearFrame: CGRect)
    /// Beside another panel (the live view while the target window is covered), aimed at its middle.
    case besidePanel(panelFrame: CGRect)
    /// Without a cursor or a summon point: tucked into the top-right corner inside this frame (the target window, or
    /// the screen when there is no window), with no tail.
    case insideTopRightCorner(containerFrame: CGRect)
}

enum AttachedPanelVerticalDirection: Equatable, Sendable {
    /// The panel's top edge stays put while its height changes.
    case below
    /// The panel's bottom edge stays put while its height changes.
    case above
}

enum AttachedPanelHorizontalDirection: Equatable, Sendable { case rightward, leftward }

struct AttachedPanelTail: Equatable, Sendable {
    enum Edge: Equatable, Sendable { case top, bottom }
    var edge: Edge
    /// From the panel's left edge to the tail's middle.
    var centerOffsetFromLeftEdge: CGFloat
}

struct AttachedPanelPlacement: Equatable, Sendable {
    /// The panel's card, without its tail. The tail sticks out of `tail.edge` by `AttachedPanelPlacementCalculator.tailLength`.
    var panelFrame: CGRect
    var verticalDirection: AttachedPanelVerticalDirection
    var horizontalDirection: AttachedPanelHorizontalDirection
    /// nil when the panel couldn't sit next to its anchor (it was pushed back on screen) or has no anchor to aim at.
    var tail: AttachedPanelTail?
}

/// Popover-style placement for panels that belong to the cursor: below and to the right of the anchor, flipped up
/// or left when that would leave the visible frame of the anchor's screen, and clamped inside it as a last resort.
/// Passing the previous placement back keeps its directions while they still fit, so a panel whose height changes
/// keeps its anchored edge where it was.
struct AttachedPanelPlacementCalculator: Sendable {
    /// Room between the keep-clear frame and the panel's card; the tail points across it.
    var gapFromKeepClearFrame: CGFloat = 12
    /// The card never comes closer than this to the visible frame's edges (the menu bar and the Dock are already
    /// outside the visible frame).
    var visibleFrameInset: CGFloat = 8
    /// How far the card reaches back past the anchor on the side it opens away from, so the tail sits a little in
    /// from the card's corner rather than on it.
    var cardOverhangPastAnchor: CGFloat = 26
    /// The tail stays this far from the card's side edges, clear of its rounded corners.
    var tailClearanceFromCardSideEdge: CGFloat = 18
    /// For `insideTopRightCorner`: the card's distance from the container's top and right edges.
    var insideCornerInset: CGFloat = 16

    static let tailLength: CGFloat = 7
    static let tailWidth: CGFloat = 14

    func placement(forPanelSize panelSize: CGSize, anchor: AttachedPanelAnchor, visibleFrame: CGRect,
                   previousPlacement: AttachedPanelPlacement? = nil) -> AttachedPanelPlacement {
        switch anchor {
        case .besideCursor(let anchorPoint, let keepClearFrame):
            return placementBeside(anchorPoint: anchorPoint, keepClearFrame: keepClearFrame, panelSize: panelSize,
                                   visibleFrame: visibleFrame, previousPlacement: previousPlacement)
        case .besidePanel(let panelFrame):
            return placementBeside(anchorPoint: CGPoint(x: panelFrame.midX, y: panelFrame.midY), keepClearFrame: panelFrame,
                                   panelSize: panelSize, visibleFrame: visibleFrame, previousPlacement: previousPlacement)
        case .insideTopRightCorner(let containerFrame):
            let preferredFrame = CGRect(x: containerFrame.maxX - insideCornerInset - panelSize.width,
                                        y: containerFrame.minY + insideCornerInset,
                                        width: panelSize.width, height: panelSize.height)
            return AttachedPanelPlacement(panelFrame: clamped(preferredFrame, into: insetVisibleFrame(visibleFrame)),
                                          verticalDirection: .below, horizontalDirection: .leftward, tail: nil)
        }
    }

    /// The tallest card that still fits on screen beside this anchor: the room on the roomier side (below or above
    /// the keep-clear frame, which `placement` then picks for a card this tall), or the whole inset visible frame
    /// for a card tucked into a corner. The card's content scrolls inside anything taller.
    func maximumPanelHeight(anchor: AttachedPanelAnchor, visibleFrame: CGRect) -> CGFloat {
        let allowedFrame = insetVisibleFrame(visibleFrame)
        let keepClearFrame: CGRect
        switch anchor {
        case .besideCursor(_, let cursorKeepClearFrame): keepClearFrame = cursorKeepClearFrame
        case .besidePanel(let panelFrame): keepClearFrame = panelFrame
        case .insideTopRightCorner: return max(0, allowedFrame.height)
        }
        let roomBelow = allowedFrame.maxY - (keepClearFrame.maxY + gapFromKeepClearFrame)
        let roomAbove = (keepClearFrame.minY - gapFromKeepClearFrame) - allowedFrame.minY
        return max(0, roomBelow, roomAbove)
    }

    private func placementBeside(anchorPoint: CGPoint, keepClearFrame: CGRect, panelSize: CGSize, visibleFrame: CGRect,
                                 previousPlacement: AttachedPanelPlacement?) -> AttachedPanelPlacement {
        let allowedFrame = insetVisibleFrame(visibleFrame)

        let belowOriginY = keepClearFrame.maxY + gapFromKeepClearFrame
        let aboveOriginY = keepClearFrame.minY - gapFromKeepClearFrame - panelSize.height
        let roomBelow = allowedFrame.maxY - belowOriginY
        let roomAbove = (keepClearFrame.minY - gapFromKeepClearFrame) - allowedFrame.minY
        let preferredVerticalDirection = previousPlacement?.verticalDirection ?? .below
        let verticalDirection = chosenDirection(
            preferred: preferredVerticalDirection,
            alternative: preferredVerticalDirection == .below ? AttachedPanelVerticalDirection.above : .below,
            roomForPanel: { verticalDirection in verticalDirection == .below ? roomBelow : roomAbove },
            panelExtent: panelSize.height)

        let rightwardOriginX = anchorPoint.x - cardOverhangPastAnchor
        let leftwardOriginX = anchorPoint.x + cardOverhangPastAnchor - panelSize.width
        // Room on the side the card opens toward; the side it reaches back over is short and checked by the clamp.
        let roomRightward = rightwardOriginX >= allowedFrame.minX ? allowedFrame.maxX - rightwardOriginX : -.greatestFiniteMagnitude
        let roomLeftward = leftwardOriginX + panelSize.width <= allowedFrame.maxX
            ? (leftwardOriginX + panelSize.width) - allowedFrame.minX : -.greatestFiniteMagnitude
        let preferredHorizontalDirection = previousPlacement?.horizontalDirection ?? .rightward
        let horizontalDirection = chosenDirection(
            preferred: preferredHorizontalDirection,
            alternative: preferredHorizontalDirection == .rightward ? AttachedPanelHorizontalDirection.leftward : .rightward,
            roomForPanel: { horizontalDirection in horizontalDirection == .rightward ? roomRightward : roomLeftward },
            panelExtent: panelSize.width)

        let unclampedFrame = CGRect(x: horizontalDirection == .rightward ? rightwardOriginX : leftwardOriginX,
                                    y: verticalDirection == .below ? belowOriginY : aboveOriginY,
                                    width: panelSize.width, height: panelSize.height)
        let panelFrame = clamped(unclampedFrame, into: allowedFrame)

        // The tail only tells the truth while the card still sits right next to what it points at.
        let cardStayedBesideAnchor = abs(panelFrame.minY - unclampedFrame.minY) < 0.5
        let tailCenterOffset = anchorPoint.x - panelFrame.minX
        let tailFitsAlongEdge = tailCenterOffset >= tailClearanceFromCardSideEdge
            && tailCenterOffset <= panelFrame.width - tailClearanceFromCardSideEdge
        let tail = cardStayedBesideAnchor && tailFitsAlongEdge
            ? AttachedPanelTail(edge: verticalDirection == .below ? .top : .bottom, centerOffsetFromLeftEdge: tailCenterOffset)
            : nil
        return AttachedPanelPlacement(panelFrame: panelFrame, verticalDirection: verticalDirection,
                                      horizontalDirection: horizontalDirection, tail: tail)
    }

    /// Keeps the preferred side while the panel fits there; otherwise the other side if it fits; when neither fits,
    /// the roomier one.
    private func chosenDirection<Direction>(preferred: Direction, alternative: Direction,
                                            roomForPanel: (Direction) -> CGFloat, panelExtent: CGFloat) -> Direction {
        if roomForPanel(preferred) >= panelExtent { return preferred }
        if roomForPanel(alternative) >= panelExtent { return alternative }
        return roomForPanel(alternative) > roomForPanel(preferred) ? alternative : preferred
    }

    private func insetVisibleFrame(_ visibleFrame: CGRect) -> CGRect {
        visibleFrame.insetBy(dx: visibleFrameInset, dy: visibleFrameInset)
    }

    /// Moves the frame inside `allowedFrame` without resizing it; a frame larger than `allowedFrame` keeps its
    /// top-left corner inside.
    private func clamped(_ frame: CGRect, into allowedFrame: CGRect) -> CGRect {
        let clampedOriginX = min(max(frame.minX, allowedFrame.minX), max(allowedFrame.minX, allowedFrame.maxX - frame.width))
        let clampedOriginY = min(max(frame.minY, allowedFrame.minY), max(allowedFrame.minY, allowedFrame.maxY - frame.height))
        return CGRect(x: clampedOriginX, y: clampedOriginY, width: frame.width, height: frame.height)
    }
}
