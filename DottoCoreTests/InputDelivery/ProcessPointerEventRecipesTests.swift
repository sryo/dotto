import Foundation
import CoreGraphics

private let targetPoint = CGPoint(x: 300, y: 200)

let processPointerEventRecipesTestSuite = CoreTestSuite(name: "ProcessPointerEventRecipes", testCases: [
    CoreTestCase(name: "a single click is a move, then one down and up with click state 1, all at the target") {
        let steps = ProcessPointerEventRecipes.clickSteps(clickType: .single, targetPointInTopLeftGlobalPoints: targetPoint)
        try expectEqual(steps.map(\.kind), [.mouseMoved, .leftMouseDown, .leftMouseUp])
        try expectEqual(steps.map(\.clickState), [0, 1, 1])
        try expectEqual(steps.map(\.delayAfterMilliseconds), [15, 1, 0])
        try expectTrue(steps.allSatisfy { $0.locationInTopLeftGlobalPoints == targetPoint })
    },
    CoreTestCase(name: "a double click has click states 1,1,2,2 with 80 ms between the pairs") {
        let steps = ProcessPointerEventRecipes.clickSteps(clickType: .double, targetPointInTopLeftGlobalPoints: targetPoint)
        try expectEqual(steps.map(\.kind), [.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDown, .leftMouseUp])
        try expectEqual(steps.map(\.clickState), [0, 1, 1, 2, 2])
        try expectEqual(steps.map(\.delayAfterMilliseconds), [15, 1, 80, 1, 0])
    },
    CoreTestCase(name: "a right click uses right-button events") {
        let steps = ProcessPointerEventRecipes.clickSteps(clickType: .right, targetPointInTopLeftGlobalPoints: targetPoint)
        try expectEqual(steps.map(\.kind), [.mouseMoved, .rightMouseDown, .rightMouseUp])
    },
    CoreTestCase(name: "scrolls send 8-line wheel ticks, signed by direction, clamped to 1…10 pages") {
        let downSteps = ProcessPointerEventRecipes.scrollSteps(direction: .down, pages: 2, targetPointInTopLeftGlobalPoints: targetPoint)
        try expectEqual(downSteps.map(\.kind), [.mouseMoved, .scrollWheel(verticalLines: -8, horizontalLines: 0),
                                                .scrollWheel(verticalLines: -8, horizontalLines: 0)])
        try expectEqual(downSteps.map(\.delayAfterMilliseconds), [15, 30, 0])
        try expectEqual(ProcessPointerEventRecipes.scrollSteps(direction: .up, pages: 1, targetPointInTopLeftGlobalPoints: targetPoint).last?.kind,
                        .scrollWheel(verticalLines: 8, horizontalLines: 0))
        try expectEqual(ProcessPointerEventRecipes.scrollSteps(direction: .right, pages: 1, targetPointInTopLeftGlobalPoints: targetPoint).last?.kind,
                        .scrollWheel(verticalLines: 0, horizontalLines: -8))
        try expectEqual(ProcessPointerEventRecipes.scrollSteps(direction: .left, pages: 1, targetPointInTopLeftGlobalPoints: targetPoint).last?.kind,
                        .scrollWheel(verticalLines: 0, horizontalLines: 8))
        try expectEqual(ProcessPointerEventRecipes.scrollSteps(direction: .down, pages: 50, targetPointInTopLeftGlobalPoints: targetPoint).count, 11)
        try expectEqual(ProcessPointerEventRecipes.scrollSteps(direction: .down, pages: 0, targetPointInTopLeftGlobalPoints: targetPoint).count, 2)
    },
])
