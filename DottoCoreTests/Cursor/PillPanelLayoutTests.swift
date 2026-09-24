import Foundation
import CoreGraphics

private let pillPanelLayout = PillPanelLayout(maximumPillSize: CGSize(width: 440, height: 120), shadowPadding: 14)
private let motionVisibleFrame = CGRect(x: 0, y: 25, width: 1440, height: 875)

private func placedPill(size pillSize: CGSize, tipPoint: CGPoint, previousPlacement: PillPlacement? = nil) -> PillPlacement {
    PillPlacementCalculator().placement(forPillSize: pillSize, tipPoint: tipPoint,
                                        preferredOffsetFromTip: CGSize(width: 40, height: 30),
                                        visibleFrame: motionVisibleFrame, previousPlacement: previousPlacement)
}

let pillPanelLayoutTestSuite = CoreTestSuite(name: "PillPanelLayout", testCases: [
    CoreTestCase(name: "the panel keeps one size while the pill fits the maximum") {
        try expectEqual(pillPanelLayout.panelSize(forPillSize: CGSize(width: 120, height: 33)), CGSize(width: 468, height: 148))
        try expectEqual(pillPanelLayout.panelSize(forPillSize: CGSize(width: 420, height: 96)), CGSize(width: 468, height: 148))
    },
    CoreTestCase(name: "a pill larger than the maximum still fits its panel") {
        try expectEqual(pillPanelLayout.panelSize(forPillSize: CGSize(width: 470, height: 130)), CGSize(width: 498, height: 158))
    },
    CoreTestCase(name: "on every side of the tip, the pill drawn in the panel lands on its placed frame") {
        let pillSize = CGSize(width: 190, height: 33)
        let tipPoints = [CGPoint(x: 700, y: 450), CGPoint(x: 1400, y: 450), CGPoint(x: 700, y: 880), CGPoint(x: 1400, y: 880)]
        var seenSides: [String] = []
        for tipPoint in tipPoints {
            let pillPlacement = placedPill(size: pillSize, tipPoint: tipPoint)
            let panelFrame = pillPanelLayout.panelFrame(for: pillPlacement)
            let pillFrameInPanel = pillPanelLayout.pillFrameInPanel(
                pillSize: pillSize, horizontalSide: pillPlacement.horizontalSide, verticalSide: pillPlacement.verticalSide,
                panelSize: panelFrame.size)
            try expectEqual(pillFrameInPanel.offsetBy(dx: panelFrame.minX, dy: panelFrame.minY), pillPlacement.pillFrame)
            seenSides.append("\(pillPlacement.horizontalSide)-\(pillPlacement.verticalSide)")
        }
        try expectEqual(Set(seenSides).count, 4, "every combination of sides is covered")
    },
    CoreTestCase(name: "right of the tip, a pill that grows keeps the panel where it is") {
        let tipPoint = CGPoint(x: 400, y: 300)
        let readingPlacement = placedPill(size: CGSize(width: 120, height: 33), tipPoint: tipPoint)
        let planningPlacement = placedPill(size: CGSize(width: 260, height: 33), tipPoint: tipPoint, previousPlacement: readingPlacement)
        try expectEqual(pillPanelLayout.panelFrame(for: readingPlacement), pillPanelLayout.panelFrame(for: planningPlacement))
    },
    CoreTestCase(name: "left of the tip, a pill that grows keeps the panel where it is and grows away from the tip") {
        let tipPoint = CGPoint(x: 1400, y: 300)
        let readingPlacement = placedPill(size: CGSize(width: 120, height: 33), tipPoint: tipPoint)
        let planningPlacement = placedPill(size: CGSize(width: 260, height: 33), tipPoint: tipPoint, previousPlacement: readingPlacement)
        try expectEqual(readingPlacement.horizontalSide, .leftOfTip)
        try expectEqual(pillPanelLayout.panelFrame(for: readingPlacement), pillPanelLayout.panelFrame(for: planningPlacement))
        try expectEqual(readingPlacement.pillFrame.maxX, planningPlacement.pillFrame.maxX)
    },
    CoreTestCase(name: "above the tip, a pill that wraps to two lines keeps its bottom edge") {
        let tipPoint = CGPoint(x: 700, y: 880)
        let singleLinePlacement = placedPill(size: CGSize(width: 300, height: 33), tipPoint: tipPoint)
        let wrappedPlacement = placedPill(size: CGSize(width: 420, height: 64), tipPoint: tipPoint, previousPlacement: singleLinePlacement)
        try expectEqual(singleLinePlacement.verticalSide, .aboveTip)
        try expectEqual(pillPanelLayout.panelFrame(for: singleLinePlacement), pillPanelLayout.panelFrame(for: wrappedPlacement))
    },
])
