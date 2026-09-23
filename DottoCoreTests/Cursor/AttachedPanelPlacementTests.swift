import Foundation
import CoreGraphics

/// A 1440 × 875 visible frame below a 25-point menu bar, in top-left global points.
private let primaryVisibleFrame = CGRect(x: 0, y: 25, width: 1440, height: 875)
private let checklistSize = CGSize(width: 380, height: 300)
private let calculator = AttachedPanelPlacementCalculator()

/// The cursor's tip with its ring and pill: 16 points around the tip, the pill ending 60 right and 50 below it.
private func cursorAnchor(atTip tipPoint: CGPoint) -> AttachedPanelAnchor {
    .besideCursor(anchorPoint: tipPoint, keepClearFrame: CGRect(x: tipPoint.x - 16, y: tipPoint.y - 16, width: 76, height: 66))
}

let attachedPanelPlacementTestSuite = CoreTestSuite(name: "AttachedPanelPlacement", testCases: [
    CoreTestCase(name: "the tallest card that fits is the room on the roomier side of the cursor") {
        // Inset visible frame: y 33...892. Keep-clear frame of a tip at y 300: 284...350.
        try expectEqual(calculator.maximumPanelHeight(anchor: cursorAnchor(atTip: CGPoint(x: 400, y: 300)), visibleFrame: primaryVisibleFrame),
                        892 - 362)
        // Near the bottom there is more room above: 784 - 12 - 33.
        let lowAnchor = cursorAnchor(atTip: CGPoint(x: 400, y: 800))
        let maximumHeightNearBottom = calculator.maximumPanelHeight(anchor: lowAnchor, visibleFrame: primaryVisibleFrame)
        try expectEqual(maximumHeightNearBottom, 739)
        try expectEqual(calculator.maximumPanelHeight(anchor: .insideTopRightCorner(containerFrame: primaryVisibleFrame),
                                                      visibleFrame: primaryVisibleFrame), 859)
    },
    CoreTestCase(name: "a card as tall as the maximum flips above the cursor and stays on screen, tail and all") {
        let lowAnchor = cursorAnchor(atTip: CGPoint(x: 400, y: 800))
        let maximumHeight = calculator.maximumPanelHeight(anchor: lowAnchor, visibleFrame: primaryVisibleFrame)
        let placement = calculator.placement(forPanelSize: CGSize(width: 380, height: maximumHeight), anchor: lowAnchor,
                                             visibleFrame: primaryVisibleFrame)
        try expectEqual(placement.verticalDirection, .above)
        try expectEqual(placement.panelFrame, CGRect(x: 374, y: 33, width: 380, height: 739))
        try expectEqual(placement.tail?.edge, .bottom)
        // The tail sticks out below the card, into the 12-point gap above the keep-clear frame.
        try expectTrue(placement.panelFrame.maxY + AttachedPanelPlacementCalculator.tailLength <= 784)
    },
    CoreTestCase(name: "opens below and to the right of the cursor, clear of its pill, with the tail aimed at the tip") {
        let placement = calculator.placement(forPanelSize: checklistSize, anchor: cursorAnchor(atTip: CGPoint(x: 400, y: 300)),
                                             visibleFrame: primaryVisibleFrame)
        try expectEqual(placement.verticalDirection, .below)
        try expectEqual(placement.horizontalDirection, .rightward)
        // Keep-clear frame ends at y = 350; the card starts 12 points below it and 26 points left of the tip.
        try expectEqual(placement.panelFrame, CGRect(x: 374, y: 362, width: 380, height: 300))
        try expectEqual(placement.tail, AttachedPanelTail(edge: .top, centerOffsetFromLeftEdge: 26))
    },
    CoreTestCase(name: "flips left near the right edge of the visible frame") {
        let placement = calculator.placement(forPanelSize: checklistSize, anchor: cursorAnchor(atTip: CGPoint(x: 1300, y: 300)),
                                             visibleFrame: primaryVisibleFrame)
        try expectEqual(placement.horizontalDirection, .leftward)
        try expectEqual(placement.panelFrame.maxX, 1326)
        try expectEqual(placement.tail, AttachedPanelTail(edge: .top, centerOffsetFromLeftEdge: 354))
    },
    CoreTestCase(name: "flips up near the bottom, keeping the whole cursor and pill uncovered") {
        let placement = calculator.placement(forPanelSize: checklistSize, anchor: cursorAnchor(atTip: CGPoint(x: 400, y: 700)),
                                             visibleFrame: primaryVisibleFrame)
        try expectEqual(placement.verticalDirection, .above)
        // Keep-clear frame starts at y = 684; the card ends 12 points above it.
        try expectEqual(placement.panelFrame.maxY, 672)
        try expectEqual(placement.tail?.edge, .bottom)
    },
    CoreTestCase(name: "flips both ways in the bottom-right corner") {
        let placement = calculator.placement(forPanelSize: checklistSize, anchor: cursorAnchor(atTip: CGPoint(x: 1380, y: 850)),
                                             visibleFrame: primaryVisibleFrame)
        try expectEqual(placement.verticalDirection, .above)
        try expectEqual(placement.horizontalDirection, .leftward)
        try expectTrue(primaryVisibleFrame.contains(placement.panelFrame))
    },
    CoreTestCase(name: "when neither side fits, takes the roomier side, stays on screen and drops the tail") {
        let tallChecklistSize = CGSize(width: 380, height: 700)
        let placement = calculator.placement(forPanelSize: tallChecklistSize, anchor: cursorAnchor(atTip: CGPoint(x: 400, y: 380)),
                                             visibleFrame: primaryVisibleFrame)
        // 319 points above the cursor against 450 below: below is roomier, and the card is pushed up to fit.
        try expectEqual(placement.verticalDirection, .below)
        try expectEqual(placement.panelFrame.maxY, primaryVisibleFrame.maxY - 8)
        try expectEqual(placement.tail, nil)
    },
    CoreTestCase(name: "a height change keeps the anchored edge: the top edge below the cursor, the bottom edge above it") {
        let belowAnchor = cursorAnchor(atTip: CGPoint(x: 400, y: 300))
        let firstBelow = calculator.placement(forPanelSize: checklistSize, anchor: belowAnchor, visibleFrame: primaryVisibleFrame)
        let tallerBelow = calculator.placement(forPanelSize: CGSize(width: 380, height: 420), anchor: belowAnchor,
                                               visibleFrame: primaryVisibleFrame, previousPlacement: firstBelow)
        try expectEqual(tallerBelow.panelFrame.minY, firstBelow.panelFrame.minY)

        let aboveAnchor = cursorAnchor(atTip: CGPoint(x: 400, y: 700))
        let firstAbove = calculator.placement(forPanelSize: checklistSize, anchor: aboveAnchor, visibleFrame: primaryVisibleFrame)
        // 120 points tall would fit below this anchor now, but the panel keeps opening upward.
        let shorterAbove = calculator.placement(forPanelSize: CGSize(width: 380, height: 120), anchor: aboveAnchor,
                                                visibleFrame: primaryVisibleFrame, previousPlacement: firstAbove)
        try expectEqual(shorterAbove.verticalDirection, .above)
        try expectEqual(shorterAbove.panelFrame.maxY, firstAbove.panelFrame.maxY)
    },
    CoreTestCase(name: "a previous direction that no longer fits flips") {
        let anchor = cursorAnchor(atTip: CGPoint(x: 400, y: 500))
        let shortBelow = calculator.placement(forPanelSize: CGSize(width: 380, height: 200), anchor: anchor,
                                              visibleFrame: primaryVisibleFrame)
        try expectEqual(shortBelow.verticalDirection, .below)
        let tallerPlacement = calculator.placement(forPanelSize: CGSize(width: 380, height: 420), anchor: anchor,
                                                   visibleFrame: primaryVisibleFrame, previousPlacement: shortBelow)
        try expectEqual(tallerPlacement.verticalDirection, .above)
    },
    CoreTestCase(name: "works on a display left of the primary one, in negative coordinates") {
        let leftDisplayVisibleFrame = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let placement = calculator.placement(forPanelSize: checklistSize, anchor: cursorAnchor(atTip: CGPoint(x: -100, y: 200)),
                                             visibleFrame: leftDisplayVisibleFrame)
        try expectEqual(placement.horizontalDirection, .leftward)
        try expectTrue(leftDisplayVisibleFrame.contains(placement.panelFrame))
    },
    CoreTestCase(name: "beside the live view in the bottom-right corner: above it, aimed at its middle") {
        let liveViewFrame = CGRect(x: 1064, y: 628, width: 360, height: 256)
        let placement = calculator.placement(forPanelSize: checklistSize, anchor: .besidePanel(panelFrame: liveViewFrame),
                                             visibleFrame: primaryVisibleFrame)
        try expectEqual(placement.verticalDirection, .above)
        try expectEqual(placement.horizontalDirection, .leftward)
        try expectEqual(placement.panelFrame.maxY, liveViewFrame.minY - 12)
        let tail = try unwrapOrFail(placement.tail)
        try expectEqual(tail.edge, .bottom)
        try expectEqual(placement.panelFrame.minX + tail.centerOffsetFromLeftEdge, liveViewFrame.midX)
    },
    CoreTestCase(name: "without a cursor: inside the target window's top-right corner, kept on screen, no tail") {
        let windowFrame = CGRect(x: 200, y: 100, width: 900, height: 600)
        let placement = calculator.placement(forPanelSize: checklistSize, anchor: .insideTopRightCorner(containerFrame: windowFrame),
                                             visibleFrame: primaryVisibleFrame)
        try expectEqual(placement.panelFrame, CGRect(x: 704, y: 116, width: 380, height: 300))
        try expectEqual(placement.tail, nil)

        let windowPastTheRightEdge = CGRect(x: 1200, y: 100, width: 900, height: 600)
        let clampedPlacement = calculator.placement(forPanelSize: checklistSize,
                                                    anchor: .insideTopRightCorner(containerFrame: windowPastTheRightEdge),
                                                    visibleFrame: primaryVisibleFrame)
        try expectEqual(clampedPlacement.panelFrame.maxX, primaryVisibleFrame.maxX - 8)
    },
])
