import Foundation
import CoreGraphics

// Replays the owner's task "rename these by file dimensions" (audit log 20260923-033546-09af79), where Finder was
// the target and Dotto paused itself five times: "you moved or resized the window" at 207.2 s, 273.9 s and 300.7 s,
// "the window was closed or minimized" at 402.8 s and "you clicked in the app" at 407.7 s. Times are seconds since
// the task started, taken from the log's tool calls, tool results, assist starts and finishes, confirmations and
// resumes. Each window event is replayed in the forms it could have taken (on the Get Info window Dotto opened, or on
// the pinned Finder window with its frame unchanged), since the log doesn't say which window the notification was for.

private let finderProcessIdentifier: Int32 = 4_242
private let robinProcessIdentifier: Int32 = 777
private let pinnedFinderWindowFrame = CGRect(x: 200, y: 120, width: 642, height: 1_280)

private enum LoggedTaskReplayEvent {
    case automatedActivity(AutomatedTargetActivity)
    case userAnsweredThisAppPanel
    case targetWindowEvent(ObservedTargetWindowEvent)
    case userInput(ObservedUserInputEvent)
}

private struct LoggedTaskReplayOutcome {
    var takeoverKinds: [UserTakeoverInputKind] = []
    var repinCount = 0
}

private let clickElement = AgentAction.clickElement(elementIdentifier: "e1", clickType: .single)
private let clickScreenshotPoint = AgentAction.clickScreenshotPoint(screenshotPixelPoint: CGPoint(x: 450, y: 63), clickType: .single)
private let commandI = AgentAction.pressKey(keyName: "i", modifiers: [.command])
private let commandW = AgentAction.pressKey(keyName: "w", modifiers: [.command])
private let typeNameAndReturn = AgentAction.typeText(elementIdentifier: "e2", text: "635x1331 Captura", replaceExistingText: true,
                                                     pressReturnAfter: true)

/// A background attempt: the action starts and returns at once (delivered, or not delivered and retried in an assist).
private func backgroundAction(_ agentAction: AgentAction, startingAt startSeconds: TimeInterval,
                              finishingAt finishSeconds: TimeInterval) -> [(TimeInterval, LoggedTaskReplayEvent)] {
    [(startSeconds, .automatedActivity(.actionStarted(agentAction))), (finishSeconds, .automatedActivity(.actionFinished))]
}

/// ForegroundAssistSession reports the assist around the bring-forward, the action and the restore.
private func assistedAction(_ agentAction: AgentAction, assistStartingAt assistStartSeconds: TimeInterval,
                            assistFinishingAt assistFinishSeconds: TimeInterval) -> [(TimeInterval, LoggedTaskReplayEvent)] {
    [(assistStartSeconds, .automatedActivity(.foregroundAssistStarted)),
     (assistStartSeconds + 0.3, .automatedActivity(.actionStarted(agentAction))),
     (assistFinishSeconds - 0.3, .automatedActivity(.actionFinished)),
     (assistFinishSeconds, .automatedActivity(.foregroundAssistFinished))]
}

private func windowEvent(_ kind: ObservedTargetWindowEventKind, at timestampSeconds: TimeInterval,
                         onPinnedWindow isOnPinnedTargetWindow: Bool) -> (TimeInterval, LoggedTaskReplayEvent) {
    let reportedFrame = (isOnPinnedTargetWindow && kind == .movedOrResized) ? pinnedFinderWindowFrame : nil
    return (timestampSeconds, .targetWindowEvent(ObservedTargetWindowEvent(
        kind: kind, timestampSeconds: timestampSeconds, isOnPinnedTargetWindow: isOnPinnedTargetWindow,
        pinnedTargetWindowFrameInTopLeftGlobalPoints: reportedFrame)))
}

private func loggedTaskEvents(windowEventsAreOnPinnedWindow: Bool,
                              getInfoCloseIsOnPinnedWindow: Bool) -> [(TimeInterval, LoggedTaskReplayEvent)] {
    var timeline: [(TimeInterval, LoggedTaskReplayEvent)] = []
    // Item 1: click_point needs an assist; ⌘I opens Get Info in an assist; the rename; ⌘W closes Get Info.
    timeline += [(190.9, .userAnsweredThisAppPanel)]
    timeline += backgroundAction(clickScreenshotPoint, startingAt: 190.95, finishingAt: 191.0)
    timeline += [(193.6, .userAnsweredThisAppPanel)]
    timeline += assistedAction(clickScreenshotPoint, assistStartingAt: 196.2, assistFinishingAt: 199.9)
    timeline += backgroundAction(commandI, startingAt: 204.0, finishingAt: 204.05)
    timeline += assistedAction(commandI, assistStartingAt: 206.4, assistFinishingAt: 208.8)
    timeline += [windowEvent(.movedOrResized, at: 207.2, onPinnedWindow: windowEventsAreOnPinnedWindow)]
    timeline += [(222.7, .userAnsweredThisAppPanel)]
    timeline += backgroundAction(clickElement, startingAt: 227.6, finishingAt: 228.2)
    timeline += backgroundAction(clickElement, startingAt: 232.7, finishingAt: 232.75)
    timeline += assistedAction(clickElement, assistStartingAt: 233.9, assistFinishingAt: 235.1)
    timeline += backgroundAction(commandI, startingAt: 245.7, finishingAt: 246.1)
    timeline += backgroundAction(clickElement, startingAt: 252.7, finishingAt: 252.75)
    timeline += assistedAction(clickElement, assistStartingAt: 254.0, assistFinishingAt: 254.9)
    timeline += [(263.3, .userAnsweredThisAppPanel)]
    timeline += backgroundAction(typeNameAndReturn, startingAt: 263.3, finishingAt: 263.4)
    timeline += [(270.6, .userAnsweredThisAppPanel)]
    timeline += backgroundAction(commandW, startingAt: 270.6, finishingAt: 271.4)
    timeline += [windowEvent(.movedOrResized, at: 273.9, onPinnedWindow: windowEventsAreOnPinnedWindow)]
    // Item 2.
    timeline += [(277.6, .userAnsweredThisAppPanel)]
    timeline += backgroundAction(clickElement, startingAt: 281.8, finishingAt: 281.85)
    timeline += assistedAction(clickElement, assistStartingAt: 283.0, assistFinishingAt: 284.2)
    timeline += backgroundAction(commandI, startingAt: 287.6, finishingAt: 288.0)
    timeline += backgroundAction(clickElement, startingAt: 292.9, finishingAt: 292.95)
    timeline += assistedAction(clickElement, assistStartingAt: 294.1, assistFinishingAt: 295.1)
    timeline += [windowEvent(.movedOrResized, at: 300.7, onPinnedWindow: windowEventsAreOnPinnedWindow)]
    timeline += [(388.5, .userAnsweredThisAppPanel)]
    timeline += [(395.0, .userAnsweredThisAppPanel)]
    timeline += backgroundAction(typeNameAndReturn, startingAt: 395.0, finishingAt: 395.3)
    timeline += backgroundAction(commandW, startingAt: 398.9, finishingAt: 398.95)
    timeline += assistedAction(commandW, assistStartingAt: 401.3, assistFinishingAt: 402.9)
    timeline += [windowEvent(.closedOrMinimized, at: 402.8, onPinnedWindow: getInfoCloseIsOnPinnedWindow)]
    // The user's click on Resume: by the time the tap's copy of the mouse-down is handled, the pill has lost its
    // Resume button, so the point resolves to the Finder window behind it.
    timeline += [(407.5, .userAnsweredThisAppPanel)]
    timeline += [(407.7, .userInput(ObservedUserInputEvent(
        kind: .mouseDown(isRightButton: false, clickCount: 1), topLeftGlobalLocation: CGPoint(x: 640, y: 300),
        timestampSeconds: 407.7, isSynthesizedByThisApp: false, frontmostProcessIdentifier: robinProcessIdentifier,
        windowOwnerProcessIdentifier: finderProcessIdentifier)))]
    // Item 3, stopped by the user at 426.3.
    timeline += [(409.5, .userAnsweredThisAppPanel)]
    timeline += backgroundAction(clickElement, startingAt: 414.0, finishingAt: 414.05)
    timeline += assistedAction(clickElement, assistStartingAt: 416.2, assistFinishingAt: 417.5)
    timeline += backgroundAction(commandI, startingAt: 424.6, finishingAt: 424.9)
    return timeline.enumerated().sorted { first, second in
        first.element.0 == second.element.0 ? first.offset < second.offset : first.element.0 < second.element.0
    }.map(\.element)
}

/// What TaskSessionController+Pause does with each event while the run is executing.
private func replay(_ timeline: [(TimeInterval, LoggedTaskReplayEvent)]) -> LoggedTaskReplayOutcome {
    var detector = UserTakeoverDetector()
    detector.rebaselinePinnedTargetWindowFrame(pinnedFinderWindowFrame)
    var outcome = LoggedTaskReplayOutcome()
    for (timestampSeconds, replayEvent) in timeline {
        switch replayEvent {
        case .automatedActivity(let automatedActivity):
            detector.noteAutomatedActivity(automatedActivity, atTimestampSeconds: timestampSeconds)
        case .userAnsweredThisAppPanel:
            detector.noteUserAnsweredThisAppPanel(atTimestampSeconds: timestampSeconds)
        case .targetWindowEvent(let targetWindowEvent):
            switch detector.decision(for: targetWindowEvent) {
            case .ignore: break
            case .takeover(let takeoverInputKind): outcome.takeoverKinds.append(takeoverInputKind)
            case .repinTargetWindowToFrontWindow:
                outcome.repinCount += 1
                detector.rebaselinePinnedTargetWindowFrame(pinnedFinderWindowFrame)
            }
        case .userInput(let observedEvent):
            if let takeoverInputKind = detector.takeoverKind(for: observedEvent, targetProcessIdentifier: finderProcessIdentifier) {
                outcome.takeoverKinds.append(takeoverInputKind)
            }
        }
    }
    return outcome
}

let userTakeoverLogReplayTestSuite = CoreTestSuite(name: "UserTakeoverDetector replaying the Get Info rename task", testCases: [
    CoreTestCase(name: "window events on the Get Info windows Dotto opened: zero pauses") {
        let outcome = replay(loggedTaskEvents(windowEventsAreOnPinnedWindow: false, getInfoCloseIsOnPinnedWindow: false))
        try expectEqual(outcome.takeoverKinds, [])
        try expectEqual(outcome.repinCount, 0)
    },
    CoreTestCase(name: "the same notifications on the pinned Finder window with its frame unchanged: zero pauses") {
        let outcome = replay(loggedTaskEvents(windowEventsAreOnPinnedWindow: true, getInfoCloseIsOnPinnedWindow: false))
        try expectEqual(outcome.takeoverKinds, [])
    },
    CoreTestCase(name: "if Dotto's ⌘W had closed the pinned window itself, the run re-pins instead of pausing") {
        let outcome = replay(loggedTaskEvents(windowEventsAreOnPinnedWindow: true, getInfoCloseIsOnPinnedWindow: true))
        try expectEqual(outcome.takeoverKinds, [])
        try expectEqual(outcome.repinCount, 1)
    },
    CoreTestCase(name: "the user really dragging the Finder window between Dotto's steps still pauses once") {
        var timeline = loggedTaskEvents(windowEventsAreOnPinnedWindow: false, getInfoCloseIsOnPinnedWindow: false)
        let userDragSeconds: TimeInterval = 380
        timeline.append((userDragSeconds, .targetWindowEvent(ObservedTargetWindowEvent(
            kind: .movedOrResized, timestampSeconds: userDragSeconds, isOnPinnedTargetWindow: true,
            pinnedTargetWindowFrameInTopLeftGlobalPoints: pinnedFinderWindowFrame.offsetBy(dx: -150, dy: 40)))))
        timeline.sort { $0.0 < $1.0 }
        try expectEqual(replay(timeline).takeoverKinds, [.windowMovedOrResized])
    },
    CoreTestCase(name: "a real click in Finder a second after Resume still pauses") {
        var timeline = loggedTaskEvents(windowEventsAreOnPinnedWindow: false, getInfoCloseIsOnPinnedWindow: false)
        let userClickSeconds: TimeInterval = 408.4
        timeline.append((userClickSeconds, .userInput(ObservedUserInputEvent(
            kind: .mouseDown(isRightButton: false, clickCount: 1), topLeftGlobalLocation: CGPoint(x: 500, y: 500),
            timestampSeconds: userClickSeconds, isSynthesizedByThisApp: false, frontmostProcessIdentifier: finderProcessIdentifier,
            windowOwnerProcessIdentifier: finderProcessIdentifier))))
        timeline.sort { $0.0 < $1.0 }
        try expectEqual(replay(timeline).takeoverKinds, [.mouseClicked])
    },
])

// Replays audit log 20260923-114529-c604dc ("add document size to images file name", Finder), where the run paused
// itself at 110.96 s with "you moved or resized the window Dotto is using": Dotto had pressed ⌘I (a Get Info window
// opened) and then clicked a button in that Get Info window, which ended 2.6 s before the pause, after the grace.
// Times are seconds since the task started.
private let pressReturn = AgentAction.pressKey(keyName: "return", modifiers: [])
private let pressEscape = AgentAction.pressKey(keyName: "escape", modifiers: [])
private let rightClickElement = AgentAction.clickElement(elementIdentifier: "e3", clickType: .right)

private func getInfoButtonTaskEvents(windowEventIsOnPinnedWindow: Bool) -> [(TimeInterval, LoggedTaskReplayEvent)] {
    var timeline: [(TimeInterval, LoggedTaskReplayEvent)] = []
    timeline += backgroundAction(clickElement, startingAt: 67.44, finishingAt: 67.53)
    timeline += [(73.56, .userAnsweredThisAppPanel)]
    timeline += assistedAction(clickElement, assistStartingAt: 76.17, assistFinishingAt: 77.35)
    timeline += backgroundAction(commandI, startingAt: 82.36, finishingAt: 84.41)
    timeline += [(107.70, .userAnsweredThisAppPanel)]
    timeline += backgroundAction(clickElement, startingAt: 107.71, finishingAt: 108.32)
    timeline += [windowEvent(.movedOrResized, at: 110.96, onPinnedWindow: windowEventIsOnPinnedWindow)]
    timeline += [(114.36, .userAnsweredThisAppPanel)]
    timeline += backgroundAction(clickElement, startingAt: 117.47, finishingAt: 117.55)
    timeline += assistedAction(clickElement, assistStartingAt: 118.59, assistFinishingAt: 120.04)
    timeline += [(137.73, .userAnsweredThisAppPanel)]
    timeline += backgroundAction(pressReturn, startingAt: 137.74, finishingAt: 138.05)
    timeline += backgroundAction(typeNameAndReturn, startingAt: 142.49, finishingAt: 142.75)
    timeline += backgroundAction(pressEscape, startingAt: 164.42, finishingAt: 164.72)
    timeline += backgroundAction(clickScreenshotPoint, startingAt: 173.67, finishingAt: 173.75)
    timeline += assistedAction(clickScreenshotPoint, assistStartingAt: 174.80, assistFinishingAt: 177.11)
    timeline += backgroundAction(clickElement, startingAt: 184.50, finishingAt: 184.58)
    timeline += assistedAction(clickElement, assistStartingAt: 185.59, assistFinishingAt: 186.69)
    timeline += backgroundAction(typeNameAndReturn, startingAt: 191.40, finishingAt: 191.75)
    timeline += backgroundAction(pressReturn, startingAt: 198.77, finishingAt: 199.11)
    timeline += backgroundAction(clickScreenshotPoint, startingAt: 224.43, finishingAt: 224.50)
    timeline += assistedAction(clickScreenshotPoint, assistStartingAt: 225.56, assistFinishingAt: 227.88)
    timeline += backgroundAction(rightClickElement, startingAt: 240.48, finishingAt: 240.55)
    timeline += assistedAction(rightClickElement, assistStartingAt: 241.58, assistFinishingAt: 243.75)
    timeline += backgroundAction(pressEscape, startingAt: 256.19, finishingAt: 256.68)
    timeline += backgroundAction(clickElement, startingAt: 261.12, finishingAt: 261.20)
    timeline += assistedAction(clickElement, assistStartingAt: 262.22, assistFinishingAt: 263.02)
    timeline += backgroundAction(typeNameAndReturn, startingAt: 270.28, finishingAt: 270.53)
    return timeline.enumerated().sorted { first, second in
        first.element.0 == second.element.0 ? first.offset < second.offset : first.element.0 < second.element.0
    }.map(\.element)
}

let userTakeoverGetInfoButtonLogReplayTestSuite = CoreTestSuite(name: "UserTakeoverDetector replaying the Get Info button click", testCases: [
    CoreTestCase(name: "the Get Info window resizing after Dotto's click in it: zero pauses") {
        let outcome = replay(getInfoButtonTaskEvents(windowEventIsOnPinnedWindow: false))
        try expectEqual(outcome.takeoverKinds, [])
        try expectEqual(outcome.repinCount, 0)
    },
    CoreTestCase(name: "the same notification on the pinned Finder window with its frame unchanged: zero pauses") {
        let outcome = replay(getInfoButtonTaskEvents(windowEventIsOnPinnedWindow: true))
        try expectEqual(outcome.takeoverKinds, [])
        try expectEqual(outcome.repinCount, 0)
    },
])
