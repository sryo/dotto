import Foundation
import CoreGraphics

/// A 1440 × 875 visible frame below a 25-point menu bar, in top-left global points; inset by 8 it is x 8...1432,
/// y 33...892.
private let primaryVisibleFrame = CGRect(x: 0, y: 25, width: 1440, height: 875)
private let pillSize = CGSize(width: 240, height: 30)
private let offsetFromTip = CGSize(width: 18, height: 21)
private let calculator = PillPlacementCalculator()

private func expectInside(_ frame: CGRect, _ visibleFrame: CGRect) throws {
    try expectTrue(visibleFrame.insetBy(dx: 8, dy: 8).contains(frame), "\(frame) should be inside \(visibleFrame)")
}

let pillPlacementTestSuite = CoreTestSuite(name: "PillPlacement", testCases: [
    CoreTestCase(name: "sits below and to the right of the tip when it fits") {
        let placement = calculator.placement(forPillSize: pillSize, tipPoint: CGPoint(x: 400, y: 300),
                                             preferredOffsetFromTip: offsetFromTip, visibleFrame: primaryVisibleFrame)
        try expectEqual(placement.horizontalSide, .rightOfTip)
        try expectEqual(placement.verticalSide, .belowTip)
        try expectEqual(placement.pillFrame, CGRect(x: 418, y: 321, width: 240, height: 30))
        try expectEqual(placement.offsetFromTip(CGPoint(x: 400, y: 300)), offsetFromTip)
    },
    CoreTestCase(name: "near the right edge it flips to the left of the tip instead of covering it") {
        let tipPoint = CGPoint(x: 1300, y: 300)
        let placement = calculator.placement(forPillSize: pillSize, tipPoint: tipPoint,
                                             preferredOffsetFromTip: offsetFromTip, visibleFrame: primaryVisibleFrame)
        try expectEqual(placement.horizontalSide, .leftOfTip)
        try expectEqual(placement.pillFrame.maxX, tipPoint.x - offsetFromTip.width)
        try expectEqual(placement.verticalSide, .belowTip)
        try expectInside(placement.pillFrame, primaryVisibleFrame)
    },
    CoreTestCase(name: "near the bottom edge (above the Dock) it flips above the tip") {
        let tipPoint = CGPoint(x: 400, y: 880)
        let placement = calculator.placement(forPillSize: pillSize, tipPoint: tipPoint,
                                             preferredOffsetFromTip: offsetFromTip, visibleFrame: primaryVisibleFrame)
        try expectEqual(placement.verticalSide, .aboveTip)
        try expectEqual(placement.pillFrame.maxY, tipPoint.y - offsetFromTip.height)
        try expectEqual(placement.horizontalSide, .rightOfTip)
        try expectInside(placement.pillFrame, primaryVisibleFrame)
    },
    CoreTestCase(name: "near the top edge a pill that was above the tip goes back below it, clear of the menu bar") {
        let previousPlacement = PillPlacement(pillFrame: .zero, horizontalSide: .rightOfTip, verticalSide: .aboveTip)
        let placement = calculator.placement(forPillSize: pillSize, tipPoint: CGPoint(x: 400, y: 40),
                                             preferredOffsetFromTip: offsetFromTip, visibleFrame: primaryVisibleFrame,
                                             previousPlacement: previousPlacement)
        try expectEqual(placement.verticalSide, .belowTip)
        try expectEqual(placement.pillFrame.minY, 61)
        // A tip resting in the menu bar still gets a pill below the menu bar.
        let tipInMenuBar = calculator.placement(forPillSize: pillSize, tipPoint: CGPoint(x: 400, y: 2),
                                                preferredOffsetFromTip: CGSize(width: 18, height: 4),
                                                visibleFrame: primaryVisibleFrame)
        try expectInside(tipInMenuBar.pillFrame, primaryVisibleFrame)
    },
    CoreTestCase(name: "near the left edge a pill that was left of the tip goes back to its right") {
        let previousPlacement = PillPlacement(pillFrame: .zero, horizontalSide: .leftOfTip, verticalSide: .belowTip)
        let placement = calculator.placement(forPillSize: pillSize, tipPoint: CGPoint(x: 60, y: 300),
                                             preferredOffsetFromTip: offsetFromTip, visibleFrame: primaryVisibleFrame,
                                             previousPlacement: previousPlacement)
        try expectEqual(placement.horizontalSide, .rightOfTip)
        try expectEqual(placement.pillFrame.minX, 78)
        try expectInside(placement.pillFrame, primaryVisibleFrame)
    },
    CoreTestCase(name: "in the bottom-right corner it flips both ways") {
        let tipPoint = CGPoint(x: 1420, y: 890)
        let placement = calculator.placement(forPillSize: pillSize, tipPoint: tipPoint,
                                             preferredOffsetFromTip: offsetFromTip, visibleFrame: primaryVisibleFrame)
        try expectEqual(placement.horizontalSide, .leftOfTip)
        try expectEqual(placement.verticalSide, .aboveTip)
        try expectEqual(placement.pillFrame, CGRect(x: 1162, y: 839, width: 240, height: 30))
        try expectInside(placement.pillFrame, primaryVisibleFrame)
    },
    CoreTestCase(name: "a pill that grows after it was placed flips once it no longer fits, and keeps its side while it does") {
        let tipPoint = CGPoint(x: 1100, y: 300)
        let shortPlacement = calculator.placement(forPillSize: pillSize, tipPoint: tipPoint,
                                                  preferredOffsetFromTip: offsetFromTip, visibleFrame: primaryVisibleFrame)
        try expectEqual(shortPlacement.horizontalSide, .rightOfTip)
        let wrappedPillSize = CGSize(width: 420, height: 62)
        let grownPlacement = calculator.placement(forPillSize: wrappedPillSize, tipPoint: tipPoint,
                                                  preferredOffsetFromTip: offsetFromTip, visibleFrame: primaryVisibleFrame,
                                                  previousPlacement: shortPlacement)
        try expectEqual(grownPlacement.horizontalSide, .leftOfTip)
        try expectInside(grownPlacement.pillFrame, primaryVisibleFrame)
        // Shrinking back a little still fits on the left, so it stays there rather than jumping.
        let shrunkPlacement = calculator.placement(forPillSize: CGSize(width: 380, height: 30), tipPoint: tipPoint,
                                                   preferredOffsetFromTip: offsetFromTip, visibleFrame: primaryVisibleFrame,
                                                   previousPlacement: grownPlacement)
        try expectEqual(shrunkPlacement.horizontalSide, .leftOfTip)
    },
    CoreTestCase(name: "on a second display left of and above the primary, it stays on that display") {
        // A 1920 × 1055 visible frame at x -1920...0, y -300...755, left of the primary display.
        let secondVisibleFrame = CGRect(x: -1920, y: -300, width: 1920, height: 1055)
        let tipPoint = CGPoint(x: -20, y: 740)
        let chosenVisibleFrame = try unwrapOrFail(PillPlacementCalculator.visibleFrame(
            nearestTo: tipPoint, amongVisibleFrames: [primaryVisibleFrame, secondVisibleFrame]))
        try expectEqual(chosenVisibleFrame, secondVisibleFrame)
        let placement = calculator.placement(forPillSize: pillSize, tipPoint: tipPoint,
                                             preferredOffsetFromTip: offsetFromTip, visibleFrame: chosenVisibleFrame)
        try expectEqual(placement.horizontalSide, .leftOfTip)
        try expectEqual(placement.verticalSide, .aboveTip)
        try expectInside(placement.pillFrame, secondVisibleFrame)
        try expectTrue(placement.pillFrame.maxX <= -8)
    },
    CoreTestCase(name: "a point in no visible frame (a menu bar, a gap between displays) takes the nearest one") {
        let secondVisibleFrame = CGRect(x: -1920, y: -300, width: 1920, height: 1055)
        try expectEqual(PillPlacementCalculator.visibleFrame(nearestTo: CGPoint(x: 700, y: 5),
                                                             amongVisibleFrames: [secondVisibleFrame, primaryVisibleFrame]),
                        primaryVisibleFrame)
        try expectEqual(PillPlacementCalculator.visibleFrame(nearestTo: CGPoint(x: -500, y: 900),
                                                             amongVisibleFrames: [primaryVisibleFrame, secondVisibleFrame]),
                        secondVisibleFrame)
        try expectEqual(PillPlacementCalculator.visibleFrame(nearestTo: .zero, amongVisibleFrames: []), nil)
    },
    CoreTestCase(name: "a pill wider than the screen keeps its left edge on screen") {
        let narrowVisibleFrame = CGRect(x: 0, y: 25, width: 400, height: 600)
        let placement = calculator.placement(forPillSize: CGSize(width: 420, height: 62), tipPoint: CGPoint(x: 200, y: 200),
                                             preferredOffsetFromTip: offsetFromTip, visibleFrame: narrowVisibleFrame)
        try expectEqual(placement.pillFrame.minX, 8)
        // Still below the tip, so the tip stays uncovered.
        try expectEqual(placement.pillFrame.minY, 221)
    },
    CoreTestCase(name: "a panel kept where the user put it is only moved back inside when it grows past an edge") {
        let insideFrame = CGRect(x: 100, y: 100, width: 360, height: 240)
        try expectEqual(calculator.frameKeptInside(visibleFrame: primaryVisibleFrame, frame: insideFrame), insideFrame)
        let grownPastTop = CGRect(x: 100, y: -20, width: 360, height: 300)
        try expectEqual(calculator.frameKeptInside(visibleFrame: primaryVisibleFrame, frame: grownPastTop),
                        CGRect(x: 100, y: 33, width: 360, height: 300))
    },
])
