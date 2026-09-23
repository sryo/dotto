import Foundation
import CoreGraphics

private func presentationState(_ activity: CursorActivity, statusText: String?,
                               attentionRequest: UserAttentionRequest? = nil,
                               statusTextBeforeInterruption: String? = nil) -> CursorPresentationState {
    var presentationState = CursorPresentationState(activity: activity, statusText: statusText, progress: nil,
                                                    replayStepProgress: nil, targetPointInWindow: nil,
                                                    targetWindowIdentifier: nil)
    presentationState.attentionRequest = attentionRequest
    presentationState.statusTextBeforeInterruption = statusTextBeforeInterruption
    return presentationState
}

private func attentionRequest(_ kind: UserAttentionKind, title: String) -> UserAttentionRequest {
    UserAttentionRequest(requestIdentifier: "attention-1", kind: kind, title: title, bodyText: "", decisionOptions: [])
}

private func pillText(for presentationState: CursorPresentationState, targetApplicationName: String = "Finder",
                      pausedStatusText: String? = nil, itemPosition: Int? = nil, itemCount: Int? = nil) -> String {
    CursorPillText.text(for: presentationState, targetApplicationName: targetApplicationName,
                        pausedStatusText: pausedStatusText, itemPosition: itemPosition, itemCount: itemCount)
}

let cursorPillTextTestSuite = CoreTestSuite(name: "CursorPillText", testCases: [
    CoreTestCase(name: "working states show their status text as is") {
        try expectEqual(pillText(for: presentationState(.clicking, statusText: "Rename IMG_2042")), "Rename IMG_2042")
        try expectEqual(pillText(for: presentationState(.reading, statusText: nil)), "")
    },
    CoreTestCase(name: "paused prefers the takeover wording and falls back to the status text") {
        let pausedState = presentationState(.paused, statusText: "Paused")
        try expectEqual(pillText(for: pausedState, pausedStatusText: "Paused · you clicked in Finder"), "Paused · you clicked in Finder")
        try expectEqual(pillText(for: pausedState), "Paused")
    },
    CoreTestCase(name: "a decision names the item it is about") {
        let decisionState = presentationState(.waiting, statusText: "Dotto needs your OK",
                                              attentionRequest: attentionRequest(.needsDecision, title: "Dotto needs your OK"),
                                              statusTextBeforeInterruption: "Delete “Q3 draft”")
        try expectEqual(pillText(for: decisionState), "Dotto needs your OK · Delete “Q3 draft”")
        let decisionWithoutItemState = presentationState(.waiting, statusText: nil,
                                                         attentionRequest: attentionRequest(.needsDecision, title: "Dotto needs your OK"))
        try expectEqual(pillText(for: decisionWithoutItemState), "Dotto needs your OK")
    },
    CoreTestCase(name: "a bring-forward question names the target app, or keeps the request title without one") {
        let bringForwardState = presentationState(.waiting, statusText: nil,
                                                  attentionRequest: attentionRequest(.needsBringForward, title: "Bring the app forward?"))
        try expectEqual(pillText(for: bringForwardState), "Let Dotto bring Finder forward when it needs to?")
        try expectEqual(pillText(for: bringForwardState, targetApplicationName: ""), "Bring the app forward?")
    },
    CoreTestCase(name: "waiting without a request shows the status text") {
        try expectEqual(pillText(for: presentationState(.waiting, statusText: "Waiting")), "Waiting")
    },
    CoreTestCase(name: "replaying shows the item position once an item has started") {
        let replayingState = presentationState(.replaying, statusText: "Rename IMG_2042")
        try expectEqual(pillText(for: replayingState, itemPosition: 12, itemCount: 49), "Replaying · 12 / 49")
        try expectEqual(pillText(for: replayingState), "Rename IMG_2042")
        try expectEqual(pillText(for: presentationState(.replaying, statusText: nil)), "Replaying")
    },
    CoreTestCase(name: "done adds the summary unless it only repeats Done") {
        try expectEqual(pillText(for: presentationState(.done, statusText: nil)), "Done")
        try expectEqual(pillText(for: presentationState(.done, statusText: "Done")), "Done")
        try expectEqual(pillText(for: presentationState(.done, statusText: "49 items")), "Done · 49 items")
    },
    CoreTestCase(name: "the bring-forward statuses name the target app when it is known") {
        let bringingState = presentationState(.pointing, statusText: CursorPresentationStateMapper.bringingAppForwardStatusText)
        try expectEqual(pillText(for: bringingState), "Bringing Finder forward for a moment")
        try expectEqual(pillText(for: bringingState, targetApplicationName: ""), CursorPresentationStateMapper.bringingAppForwardStatusText)
        let waitingForPauseState = presentationState(
            .pointing, statusText: CursorPresentationStateMapper.waitingForUserBeforeBringingAppForwardStatusText)
        try expectEqual(pillText(for: waitingForPauseState), "Waiting for you to pause before bringing Finder forward")
        let countdownState = presentationState(.pointing, statusText: CursorPresentationStateMapper.bringingAppForwardCountdownStatusText)
        try expectEqual(pillText(for: countdownState), "Bringing Finder forward…")
    },
    CoreTestCase(name: "the text is one line (the pill wraps it) capped at two lines' length") {
        let multilineState = presentationState(.clicking, statusText: "Rename\nIMG_2042")
        try expectEqual(pillText(for: multilineState), "Rename IMG_2042")
        let questionText = "Let Dotto bring Finder forward when it needs to? · Rename “IMG_2042.jpg” to “beach-01.jpg”"
        try expectEqual(pillText(for: presentationState(.clicking, statusText: questionText)), questionText, "a question is never cut short")
        let longText = pillText(for: presentationState(.clicking, statusText: String(repeating: "a", count: 200)))
        try expectEqual(longText.count, CursorPillText.maximumLength)
        try expectTrue(longText.hasSuffix("…"))
    },
])
