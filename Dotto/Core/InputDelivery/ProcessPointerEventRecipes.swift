import Foundation
import CoreGraphics

enum ProcessPointerEventKind: Equatable, Sendable {
    case mouseMoved, leftMouseDown, leftMouseUp, rightMouseDown, rightMouseUp
    case scrollWheel(verticalLines: Int32, horizontalLines: Int32)
}

struct ProcessPointerEventStep: Equatable, Sendable {
    var kind: ProcessPointerEventKind
    var locationInTopLeftGlobalPoints: CGPoint
    /// CGEventField.mouseEventClickState; 0 for moves and wheel events.
    var clickState: Int64
    var delayAfterMilliseconds: Int
}

/// The pointer sequences the assist posts to the (then frontmost) target pid. Platform checks abort before every
/// down and wheel event, never between a down and its up.
enum ProcessPointerEventRecipes {
    static let delayAfterMoveMilliseconds = 15
    static let delayBetweenDownAndUpMilliseconds = 1
    static let delayBetweenClickPairsMilliseconds = 80
    static let delayBetweenWheelEventsMilliseconds = 30
    static let linesPerWheelEvent: Int32 = 8
    static let maximumWheelEventCount = 10

    static func clickSteps(clickType: AgentClickType, targetPointInTopLeftGlobalPoints: CGPoint) -> [ProcessPointerEventStep] {
        let isRightClick = clickType == .right
        let clickCount = clickType == .double ? 2 : 1
        var steps = [ProcessPointerEventStep(kind: .mouseMoved, locationInTopLeftGlobalPoints: targetPointInTopLeftGlobalPoints,
                                             clickState: 0, delayAfterMilliseconds: delayAfterMoveMilliseconds)]
        for clickNumber in 1...clickCount {
            steps.append(ProcessPointerEventStep(kind: isRightClick ? .rightMouseDown : .leftMouseDown,
                                                 locationInTopLeftGlobalPoints: targetPointInTopLeftGlobalPoints,
                                                 clickState: Int64(clickNumber), delayAfterMilliseconds: delayBetweenDownAndUpMilliseconds))
            steps.append(ProcessPointerEventStep(kind: isRightClick ? .rightMouseUp : .leftMouseUp,
                                                 locationInTopLeftGlobalPoints: targetPointInTopLeftGlobalPoints,
                                                 clickState: Int64(clickNumber),
                                                 delayAfterMilliseconds: clickNumber < clickCount ? delayBetweenClickPairsMilliseconds : 0))
        }
        return steps
    }

    static func scrollSteps(direction: AgentScrollDirection, pages: Int, targetPointInTopLeftGlobalPoints: CGPoint) -> [ProcessPointerEventStep] {
        let wheelEventCount = max(1, min(pages, maximumWheelEventCount))
        // Negative lines scroll the content down or right, matching the direction the model asked for.
        let (verticalLines, horizontalLines): (Int32, Int32) = switch direction {
        case .up: (linesPerWheelEvent, 0)
        case .down: (-linesPerWheelEvent, 0)
        case .left: (0, linesPerWheelEvent)
        case .right: (0, -linesPerWheelEvent)
        }
        let moveStep = ProcessPointerEventStep(kind: .mouseMoved, locationInTopLeftGlobalPoints: targetPointInTopLeftGlobalPoints,
                                               clickState: 0, delayAfterMilliseconds: delayAfterMoveMilliseconds)
        let wheelSteps = (0..<wheelEventCount).map { wheelEventIndex in
            ProcessPointerEventStep(kind: .scrollWheel(verticalLines: verticalLines, horizontalLines: horizontalLines),
                                    locationInTopLeftGlobalPoints: targetPointInTopLeftGlobalPoints, clickState: 0,
                                    delayAfterMilliseconds: wheelEventIndex < wheelEventCount - 1 ? delayBetweenWheelEventsMilliseconds : 0)
        }
        return [moveStep] + wheelSteps
    }
}
