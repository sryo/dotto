import Foundation
import CoreGraphics

/// A 1440 × 875 visible frame below a 25-point menu bar, in top-left global points.
private let handoffVisibleFrame = CGRect(x: 0, y: 25, width: 1440, height: 875)
private let statusPillSize = CGSize(width: 190, height: 33)

private func handoff(capsuleFrame: CGRect, horizontalSide: PillHorizontalSide, verticalSide: PillVerticalSide) -> CommandPillHandoff {
    CommandPillHandoff(capsuleFrame: capsuleFrame, horizontalSide: horizontalSide, verticalSide: verticalSide)
}

/// What the cursor's pill panel does with a handoff: the calculator, fed the handoff's offset and sides.
private func placedStatusPill(for commandPillHandoff: CommandPillHandoff, tipPoint: CGPoint) -> PillPlacement {
    PillPlacementCalculator().placement(
        forPillSize: statusPillSize, tipPoint: tipPoint,
        preferredOffsetFromTip: commandPillHandoff.preferredOffsetFromTip(forStatusPillSize: statusPillSize, tipPoint: tipPoint),
        visibleFrame: handoffVisibleFrame, previousPlacement: commandPillHandoff.sidesPlacement)
}

let commandPillHandoffTestSuite = CoreTestSuite(name: "CommandPillHandoff", testCases: [
    CoreTestCase(name: "right of the tip, the status pill keeps the capsule's left edge and vertical center") {
        let commandPillHandoff = handoff(capsuleFrame: CGRect(x: 440, y: 326, width: 320, height: 40),
                                         horizontalSide: .rightOfTip, verticalSide: .belowTip)
        let statusPillFrame = commandPillHandoff.statusPillFrame(forStatusPillSize: statusPillSize)
        try expectEqual(statusPillFrame.minX, 440)
        try expectEqual(statusPillFrame.midY, 346)
        try expectEqual(statusPillFrame.size, statusPillSize)
    },
    CoreTestCase(name: "flipped left of the tip, the status pill keeps the capsule's right edge, the one facing the tip") {
        let commandPillHandoff = handoff(capsuleFrame: CGRect(x: 900, y: 326, width: 320, height: 40),
                                         horizontalSide: .leftOfTip, verticalSide: .belowTip)
        let statusPillFrame = commandPillHandoff.statusPillFrame(forStatusPillSize: statusPillSize)
        try expectEqual(statusPillFrame.maxX, 1220)
        try expectEqual(statusPillFrame.midY, 346)
    },
    CoreTestCase(name: "the placement calculator puts the status pill on the capsule on every side of the tip") {
        let tipPoint = CGPoint(x: 700, y: 450)
        let capsuleFramesAndSides: [(CGRect, PillHorizontalSide, PillVerticalSide)] = [
            (CGRect(x: 740, y: 476, width: 320, height: 40), .rightOfTip, .belowTip),
            (CGRect(x: 340, y: 476, width: 320, height: 40), .leftOfTip, .belowTip),
            (CGRect(x: 740, y: 360, width: 320, height: 40), .rightOfTip, .aboveTip),
            (CGRect(x: 340, y: 360, width: 320, height: 40), .leftOfTip, .aboveTip),
        ]
        for (capsuleFrame, horizontalSide, verticalSide) in capsuleFramesAndSides {
            let commandPillHandoff = handoff(capsuleFrame: capsuleFrame, horizontalSide: horizontalSide, verticalSide: verticalSide)
            let placement = placedStatusPill(for: commandPillHandoff, tipPoint: tipPoint)
            try expectEqual(placement.horizontalSide, horizontalSide)
            try expectEqual(placement.verticalSide, verticalSide)
            try expectEqual(placement.pillFrame, commandPillHandoff.statusPillFrame(forStatusPillSize: statusPillSize))
        }
    },
    CoreTestCase(name: "near the bottom right corner the status pill flips the way the command pill did") {
        // The command pill flipped left of and above a pointer near the Dock and the right edge.
        let tipPoint = CGPoint(x: 1400, y: 880)
        let commandPillHandoff = handoff(capsuleFrame: CGRect(x: 1040, y: 790, width: 320, height: 40),
                                         horizontalSide: .leftOfTip, verticalSide: .aboveTip)
        let placement = placedStatusPill(for: commandPillHandoff, tipPoint: tipPoint)
        try expectEqual(placement.horizontalSide, .leftOfTip)
        try expectEqual(placement.verticalSide, .aboveTip)
        try expectEqual(placement.pillFrame.maxX, 1360)
        try expectEqual(placement.pillFrame.midY, 810)
    },
    CoreTestCase(name: "a status pill that wraps stays centered on the capsule") {
        let commandPillHandoff = handoff(capsuleFrame: CGRect(x: 440, y: 326, width: 320, height: 40),
                                         horizontalSide: .rightOfTip, verticalSide: .belowTip)
        let tipPoint = CGPoint(x: 400, y: 300)
        let wrappedStatusPillSize = CGSize(width: 420, height: 64)
        let placement = PillPlacementCalculator().placement(
            forPillSize: wrappedStatusPillSize, tipPoint: tipPoint,
            preferredOffsetFromTip: commandPillHandoff.preferredOffsetFromTip(forStatusPillSize: wrappedStatusPillSize, tipPoint: tipPoint),
            visibleFrame: handoffVisibleFrame, previousPlacement: commandPillHandoff.sidesPlacement)
        try expectEqual(placement.pillFrame.minX, 440)
        try expectEqual(placement.pillFrame.midY, 346)
    },
    CoreTestCase(name: "the command pill's capsule opens where the status pill hangs from the tip") {
        let commandPillOffset = CommandPillHandoff.commandPillOffsetFromPointer(
            statusPillOffsetFromTip: CGSize(width: 40, height: 30), statusPillHeight: 33, capsuleHeight: 40)
        try expectEqual(commandPillOffset, CGSize(width: 40, height: 26.5))
        // The status pill's usual frame below the tip and the capsule share their left edge and vertical center.
        let tipPoint = CGPoint(x: 400, y: 300)
        let usualStatusPillFrame = CGRect(x: 440, y: 330, width: 190, height: 33)
        let capsuleFrame = CGRect(x: tipPoint.x + commandPillOffset.width, y: tipPoint.y + commandPillOffset.height,
                                  width: 320, height: 40)
        try expectEqual(capsuleFrame.minX, usualStatusPillFrame.minX)
        try expectEqual(capsuleFrame.midY, usualStatusPillFrame.midY)
    },
    CoreTestCase(name: "a status pill whose text changed during the morph keeps the held pill's tip-facing edge") {
        let commandPillHandoff = handoff(capsuleFrame: CGRect(x: 900, y: 326, width: 320, height: 40),
                                         horizontalSide: .leftOfTip, verticalSide: .belowTip)
        let heldStatusPillFrame = commandPillHandoff.statusPillFrame(forStatusPillSize: statusPillSize)
        let grownStatusPillFrame = commandPillHandoff.statusPillFrame(forStatusPillSize: CGSize(width: 250, height: 33),
                                                                      heldStatusPillFrame: heldStatusPillFrame)
        try expectEqual(grownStatusPillFrame.maxX, 1220)
        try expectEqual(grownStatusPillFrame.midY, 346)
        try expectEqual(grownStatusPillFrame.width, 250)
    },
    CoreTestCase(name: "a held status pill pushed back inside the screen stays pushed back by as much when it resizes") {
        let commandPillHandoff = handoff(capsuleFrame: CGRect(x: 440, y: 326, width: 320, height: 40),
                                         horizontalSide: .rightOfTip, verticalSide: .belowTip)
        let heldStatusPillFrame = commandPillHandoff.statusPillFrame(forStatusPillSize: statusPillSize).offsetBy(dx: -12, dy: 0)
        let grownStatusPillFrame = commandPillHandoff.statusPillFrame(forStatusPillSize: CGSize(width: 250, height: 33),
                                                                      heldStatusPillFrame: heldStatusPillFrame)
        try expectEqual(grownStatusPillFrame.minX, 428)
        try expectEqual(grownStatusPillFrame.midY, 346)
    },
    CoreTestCase(name: "the morph canvas holds the command pill and the status pill it becomes, with shadow room") {
        let commandPillHandoff = handoff(capsuleFrame: CGRect(x: 900, y: 326, width: 320, height: 40),
                                         horizontalSide: .leftOfTip, verticalSide: .belowTip)
        let commandPillContentFrame = CGRect(x: 900, y: 326, width: 320, height: 66)
        // Wider than the capsule: it reaches past the capsule's far edge.
        let statusPillFrame = commandPillHandoff.statusPillFrame(forStatusPillSize: CGSize(width: 420, height: 64))
        let morphCanvasFrame = CommandPillHandoff.morphCanvasFrame(
            commandPillContentFrame: commandPillContentFrame, statusPillFrame: statusPillFrame, shadowMargin: 24)
        try expectTrue(morphCanvasFrame.contains(commandPillContentFrame.insetBy(dx: -24, dy: -24)))
        try expectTrue(morphCanvasFrame.contains(statusPillFrame.insetBy(dx: -24, dy: -24)))
        try expectEqual(morphCanvasFrame.minX, 1220 - 420 - 24)
        try expectEqual(morphCanvasFrame.maxX, 1220 + 24)
        try expectEqual(morphCanvasFrame.minY, 346 - 32 - 24)
    },
])
