import Foundation
import CoreGraphics

private let targetProcessIdentifier: Int32 = 500
private let otherProcessIdentifier: Int32 = 600

private func observedEvent(_ kind: ObservedUserInputEvent.Kind, frontmost frontmostProcessIdentifier: Int32? = otherProcessIdentifier,
                           windowOwner windowOwnerProcessIdentifier: Int32? = nil,
                           isSynthesized: Bool = false, at timestampSeconds: TimeInterval = 10) -> ObservedUserInputEvent {
    ObservedUserInputEvent(kind: kind, topLeftGlobalLocation: CGPoint(x: 10, y: 10), timestampSeconds: timestampSeconds,
                           isSynthesizedByThisApp: isSynthesized, frontmostProcessIdentifier: frontmostProcessIdentifier,
                           windowOwnerProcessIdentifier: windowOwnerProcessIdentifier)
}

private let leftClick = ObservedUserInputEvent.Kind.mouseDown(isRightButton: false, clickCount: 1)
private let letterKey = ObservedUserInputEvent.Kind.keyDown(virtualKeyCode: 0, modifiers: [], characters: "a")
private let commandW = AgentAction.pressKey(keyName: "w", modifiers: [.command])
private let pinnedWindowFrame = CGRect(x: 100, y: 80, width: 900, height: 600)

private func pinnedWindowEvent(_ kind: ObservedTargetWindowEventKind, at timestampSeconds: TimeInterval,
                               frame pinnedTargetWindowFrame: CGRect? = nil) -> ObservedTargetWindowEvent {
    ObservedTargetWindowEvent(kind: kind, timestampSeconds: timestampSeconds, isOnPinnedTargetWindow: true,
                              pinnedTargetWindowFrameInTopLeftGlobalPoints: pinnedTargetWindowFrame)
}

let userTakeoverDetectorTestSuite = CoreTestSuite(name: "UserTakeoverDetector", testCases: [
    CoreTestCase(name: "a click or scroll on a target window takes over, even while another app is frontmost") {
        let detector = UserTakeoverDetector()
        try expectEqual(detector.takeoverKind(for: observedEvent(leftClick, windowOwner: targetProcessIdentifier),
                                              targetProcessIdentifier: targetProcessIdentifier), .mouseClicked)
        try expectEqual(detector.takeoverKind(for: observedEvent(.scrollWheel, windowOwner: targetProcessIdentifier),
                                              targetProcessIdentifier: targetProcessIdentifier), .scrolled)
    },
    CoreTestCase(name: "a click or scroll in another app doesn't, even while the target is frontmost") {
        let detector = UserTakeoverDetector()
        try expectEqual(detector.takeoverKind(for: observedEvent(leftClick, frontmost: targetProcessIdentifier, windowOwner: otherProcessIdentifier),
                                              targetProcessIdentifier: targetProcessIdentifier), nil)
        try expectEqual(detector.takeoverKind(for: observedEvent(.scrollWheel, windowOwner: otherProcessIdentifier),
                                              targetProcessIdentifier: targetProcessIdentifier), nil)
    },
    CoreTestCase(name: "with no known window owner, a click counts only when the target is frontmost") {
        let detector = UserTakeoverDetector()
        try expectEqual(detector.takeoverKind(for: observedEvent(leftClick, frontmost: targetProcessIdentifier),
                                              targetProcessIdentifier: targetProcessIdentifier), .mouseClicked)
        try expectEqual(detector.takeoverKind(for: observedEvent(leftClick, frontmost: otherProcessIdentifier),
                                              targetProcessIdentifier: targetProcessIdentifier), nil)
    },
    CoreTestCase(name: "a key counts only while the target is frontmost") {
        let detector = UserTakeoverDetector()
        try expectEqual(detector.takeoverKind(for: observedEvent(letterKey, frontmost: otherProcessIdentifier),
                                              targetProcessIdentifier: targetProcessIdentifier), nil)
        try expectEqual(detector.takeoverKind(for: observedEvent(letterKey, frontmost: targetProcessIdentifier),
                                              targetProcessIdentifier: targetProcessIdentifier), .keyPressed)
    },
    CoreTestCase(name: "Esc is an ordinary key: it takes over only while the target is frontmost") {
        let escapeVirtualKeyCode: Int64 = 53
        let escapeKey = ObservedUserInputEvent.Kind.keyDown(virtualKeyCode: escapeVirtualKeyCode, modifiers: [], characters: nil)
        try expectEqual(UserTakeoverDetector().takeoverKind(for: observedEvent(escapeKey, frontmost: targetProcessIdentifier),
                                                            targetProcessIdentifier: targetProcessIdentifier), .keyPressed)
        try expectEqual(UserTakeoverDetector().takeoverKind(for: observedEvent(escapeKey, frontmost: otherProcessIdentifier),
                                                            targetProcessIdentifier: targetProcessIdentifier), nil)
    },
    CoreTestCase(name: "pointer moves never take over, even over the target") {
        try expectEqual(UserTakeoverDetector().takeoverKind(for: observedEvent(.mouseMoved, frontmost: targetProcessIdentifier,
                                                                               windowOwner: targetProcessIdentifier),
                                                            targetProcessIdentifier: targetProcessIdentifier), nil)
    },
    CoreTestCase(name: "synthetic events are ignored") {
        try expectEqual(UserTakeoverDetector().takeoverKind(for: observedEvent(leftClick, frontmost: targetProcessIdentifier,
                                                                               windowOwner: targetProcessIdentifier, isSynthesized: true),
                                                            targetProcessIdentifier: targetProcessIdentifier), nil)
    },
    CoreTestCase(name: "a real move, resize, close or minimize of the pinned window pauses when Dotto isn't acting") {
        var detector = UserTakeoverDetector()
        detector.rebaselinePinnedTargetWindowFrame(pinnedWindowFrame)
        try expectEqual(detector.decision(for: pinnedWindowEvent(.movedOrResized, at: 5, frame: pinnedWindowFrame.offsetBy(dx: 40, dy: 0))),
                        .takeover(.windowMovedOrResized))
        try expectEqual(detector.decision(for: pinnedWindowEvent(.closedOrMinimized, at: 6)), .takeover(.windowClosed))
    },
    CoreTestCase(name: "moves, resizes and closes of the target's other windows never pause") {
        var detector = UserTakeoverDetector()
        detector.rebaselinePinnedTargetWindowFrame(pinnedWindowFrame)
        try expectEqual(detector.decision(for: ObservedTargetWindowEvent(kind: .movedOrResized, timestampSeconds: 5,
                                                                         isOnPinnedTargetWindow: false)), .ignore)
        try expectEqual(detector.decision(for: ObservedTargetWindowEvent(kind: .closedOrMinimized, timestampSeconds: 6,
                                                                         isOnPinnedTargetWindow: false)), .ignore)
    },
    CoreTestCase(name: "a moved or resized notification that left the pinned frame as it was doesn't pause") {
        var detector = UserTakeoverDetector()
        detector.rebaselinePinnedTargetWindowFrame(pinnedWindowFrame)
        try expectEqual(detector.decision(for: pinnedWindowEvent(.movedOrResized, at: 5, frame: pinnedWindowFrame.offsetBy(dx: 0.4, dy: 0))),
                        .ignore)
    },
    CoreTestCase(name: "a first move report with no baseline becomes the baseline; a later real move pauses") {
        var detector = UserTakeoverDetector()
        try expectEqual(detector.decision(for: pinnedWindowEvent(.movedOrResized, at: 5, frame: pinnedWindowFrame)), .ignore)
        try expectEqual(detector.decision(for: pinnedWindowEvent(.movedOrResized, at: 9, frame: pinnedWindowFrame.offsetBy(dx: 40, dy: 0))),
                        .takeover(.windowMovedOrResized))
    },
    CoreTestCase(name: "a pinned move whose frame can't be read still pauses (fails toward the user)") {
        var detector = UserTakeoverDetector()
        detector.rebaselinePinnedTargetWindowFrame(pinnedWindowFrame)
        try expectEqual(detector.decision(for: ObservedTargetWindowEvent(kind: .movedOrResized, timestampSeconds: 5,
                                                                         isOnPinnedTargetWindow: true,
                                                                         pinnedTargetWindowFrameInTopLeftGlobalPoints: nil)),
                        .takeover(.windowMovedOrResized))
    },
    CoreTestCase(name: "pinned window changes during Dotto's action or assist, and for 1.5 s after, are Dotto's") {
        var detector = UserTakeoverDetector()
        detector.rebaselinePinnedTargetWindowFrame(pinnedWindowFrame)
        detector.noteAutomatedActivity(.foregroundAssistStarted, atTimestampSeconds: 10)
        detector.noteAutomatedActivity(.actionStarted(.scroll(elementIdentifier: nil, direction: .down, pages: 1)), atTimestampSeconds: 10.1)
        // A long assist: well past the grace since it started, but still under way.
        try expectEqual(detector.decision(for: pinnedWindowEvent(.movedOrResized, at: 14, frame: pinnedWindowFrame.offsetBy(dx: 0, dy: 30))),
                        .ignore)
        detector.noteAutomatedActivity(.actionFinished, atTimestampSeconds: 14.5)
        detector.noteAutomatedActivity(.foregroundAssistFinished, atTimestampSeconds: 15)
        try expectEqual(detector.decision(for: pinnedWindowEvent(.movedOrResized, at: 16.4, frame: pinnedWindowFrame)), .ignore)
        // Dotto's own move became the baseline, so the user's later drag is compared with where Dotto left it.
        try expectEqual(detector.decision(for: pinnedWindowEvent(.movedOrResized, at: 17, frame: pinnedWindowFrame.offsetBy(dx: 90, dy: 0))),
                        .takeover(.windowMovedOrResized))
    },
    CoreTestCase(name: "Dotto's own ⌘W closing the pinned window re-pins instead of pausing, even after the grace") {
        var detector = UserTakeoverDetector()
        detector.noteAutomatedActivity(.actionStarted(commandW), atTimestampSeconds: 10)
        detector.noteAutomatedActivity(.actionFinished, atTimestampSeconds: 10.1)
        try expectEqual(detector.decision(for: pinnedWindowEvent(.closedOrMinimized, at: 13)), .repinTargetWindowToFrontWindow)
        try expectEqual(detector.decision(for: pinnedWindowEvent(.closedOrMinimized, at: 16)), .takeover(.windowClosed))
    },
    CoreTestCase(name: "a close long after a scroll (which can't close anything) is the user's") {
        var detector = UserTakeoverDetector()
        detector.noteAutomatedActivity(.actionStarted(.scroll(elementIdentifier: nil, direction: .down, pages: 1)), atTimestampSeconds: 10)
        detector.noteAutomatedActivity(.actionFinished, atTimestampSeconds: 10.2)
        try expectEqual(detector.decision(for: pinnedWindowEvent(.closedOrMinimized, at: 12)), .takeover(.windowClosed))
    },
    CoreTestCase(name: "the actions that may close a window: clicks, ⌘W, ⌘M, Esc, Return, typing with Return") {
        try expectTrue(UserTakeoverDetector.automatedActionMayCloseWindow(commandW))
        try expectTrue(UserTakeoverDetector.automatedActionMayCloseWindow(.pressKey(keyName: "M", modifiers: [.command])))
        try expectTrue(UserTakeoverDetector.automatedActionMayCloseWindow(.pressKey(keyName: "esc", modifiers: [])))
        try expectTrue(UserTakeoverDetector.automatedActionMayCloseWindow(.pressKey(keyName: "enter", modifiers: [])))
        try expectTrue(UserTakeoverDetector.automatedActionMayCloseWindow(.clickElement(elementIdentifier: "e1", clickType: .single)))
        try expectTrue(UserTakeoverDetector.automatedActionMayCloseWindow(
            .typeText(elementIdentifier: "e2", text: "x", replaceExistingText: true, pressReturnAfter: true)))
        try expectEqual(UserTakeoverDetector.automatedActionMayCloseWindow(.pressKey(keyName: "w", modifiers: [])), false)
        try expectEqual(UserTakeoverDetector.automatedActionMayCloseWindow(.pressKey(keyName: "i", modifiers: [.command])), false)
        try expectEqual(UserTakeoverDetector.automatedActionMayCloseWindow(
            .typeText(elementIdentifier: "e2", text: "x", replaceExistingText: true, pressReturnAfter: false)), false)
    },
    CoreTestCase(name: "a click on the target within 0.75 s of Resume or a pill answer is that answer, not a takeover") {
        var detector = UserTakeoverDetector()
        detector.noteUserAnsweredThisAppPanel(atTimestampSeconds: 10)
        try expectEqual(detector.takeoverKind(for: observedEvent(leftClick, windowOwner: targetProcessIdentifier, at: 10.2),
                                              targetProcessIdentifier: targetProcessIdentifier), nil)
        try expectEqual(detector.takeoverKind(for: observedEvent(leftClick, windowOwner: targetProcessIdentifier, at: 10.9),
                                              targetProcessIdentifier: targetProcessIdentifier), .mouseClicked)
        // Keys are never mistaken for a click on Dotto's panel.
        try expectEqual(detector.takeoverKind(for: observedEvent(letterKey, frontmost: targetProcessIdentifier, at: 10.2),
                                              targetProcessIdentifier: targetProcessIdentifier), .keyPressed)
    },
    CoreTestCase(name: "reset forgets Dotto's activity, answers and the baseline") {
        var detector = UserTakeoverDetector()
        detector.rebaselinePinnedTargetWindowFrame(pinnedWindowFrame)
        detector.noteAutomatedActivity(.actionStarted(commandW), atTimestampSeconds: 10)
        detector.noteUserAnsweredThisAppPanel(atTimestampSeconds: 10)
        detector.reset()
        try expectEqual(detector.decision(for: pinnedWindowEvent(.closedOrMinimized, at: 10.5)), .takeover(.windowClosed))
        try expectEqual(detector.takeoverKind(for: observedEvent(leftClick, windowOwner: targetProcessIdentifier, at: 10.5),
                                              targetProcessIdentifier: targetProcessIdentifier), .mouseClicked)
    },
])
