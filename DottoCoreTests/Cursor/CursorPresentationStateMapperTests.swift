import Foundation
import CoreGraphics

private func confirmationRequest(_ riskCategory: SafetyRiskCategory, reason: String = "This step will click “Send”.") -> SafetyConfirmationRequest {
    SafetyConfirmationRequest(itemIdentifier: "item-2", itemLabel: "Reply to Ana", reason: reason, isActionLevel: true,
                              riskCategory: riskCategory)
}

private let runningEvents: [CursorActivityEvent] = [
    .runStarted(targetWindow: cursorFixtureTargetWindow), .itemStarted(itemLabel: "Rename IMG_2042", itemPosition: 2, itemCount: 5),
]

let cursorPresentationStateMapperTestSuite = CoreTestSuite(name: "CursorPresentationStateMapper", testCases: [
    CoreTestCase(name: "a hidden cursor absorbs every event except runStarted") {
        let everyOtherEvent: [CursorActivityEvent] = [
            .targetWindowChanged(cursorFixtureTargetWindow), .itemStarted(itemLabel: "x", itemPosition: 1, itemCount: 1), .userInterfaceReadStarted,
            .modelTurnStarted, .replayStepStarted(stepIndex: 0, stepCount: 2), .actionTargeted(.click, windowRelativePoint: .zero),
            .confirmationRequested(confirmationRequest(.deleting)), .confirmationAnswered, .paused(.requestedByUser), .resumed,
            .foregroundAssistStarted, .foregroundAssistFinished, .itemFinished(.failed), .runFinished(succeeded: true),
            .itemFailureDecisionRequested(ChecklistItemFailureDecisionRequest(itemIdentifier: "i", itemLabel: "x", failureSummary: "", attemptCount: 1)),
        ]
        for event in everyOtherEvent {
            try expectEqual(CursorPresentationStateMapper.nextState(from: .hidden, on: event), .hidden, "\(event)")
        }
    },
    CoreTestCase(name: "runStarted reads with the window id; a window change keeps everything but the id and the point") {
        let startedState = cursorState(after: [.runStarted(targetWindow: cursorFixtureTargetWindow)])
        try expectEqual(startedState.activity, .reading)
        try expectEqual(startedState.targetWindowIdentifier, 31)
        let pointedState = cursorState(after: [.actionTargeted(.click, windowRelativePoint: CGPoint(x: 5, y: 6))], from: startedState)
        var movedWindow = cursorFixtureTargetWindow
        movedWindow.windowIdentifier = 32
        let changedState = cursorState(after: [.targetWindowChanged(movedWindow)], from: pointedState)
        try expectEqual(changedState.targetWindowIdentifier, 32)
        try expectEqual(changedState.targetPointInWindow, nil)
        try expectEqual(changedState.activity, pointedState.activity)
    },
    CoreTestCase(name: "itemStarted shows the label and the item's position; reads and model turns keep text and point") {
        let itemState = cursorState(after: runningEvents + [.actionTargeted(.typing, windowRelativePoint: CGPoint(x: 9, y: 9))])
        try expectEqual(itemState.statusText, "Rename IMG_2042")
        try expectEqual(itemState.progress, 0.2)
        try expectEqual(itemState.activity, .typing)
        let thinkingState = cursorState(after: [.modelTurnStarted], from: itemState)
        try expectEqual(thinkingState.activity, .thinking)
        try expectEqual(thinkingState.statusText, "Rename IMG_2042")
        try expectEqual(thinkingState.targetPointInWindow, CGPoint(x: 9, y: 9))
        try expectEqual(cursorState(after: [.userInterfaceReadStarted], from: thinkingState).activity, .reading)
    },
    CoreTestCase(name: "actions map to the prototype's clicking, typing and pointing states") {
        let expectedActivities: [(CursorActionKind, CursorActivity)] = [
            (.click, .clicking), (.doubleClick, .clicking), (.rightClick, .clicking), (.attachingFiles, .clicking),
            (.typing, .typing), (.pressingKey, .typing), (.scrolling, .pointing),
        ]
        for (actionKind, expectedActivity) in expectedActivities {
            try expectEqual(cursorState(after: runningEvents + [.actionTargeted(actionKind, windowRelativePoint: nil)]).activity,
                            expectedActivity, actionKind.rawValue)
        }
    },
    CoreTestCase(name: "replay shows step progress and stays replaying through its actions, while the point updates") {
        let replayingState = cursorState(after: runningEvents + [.replayStepStarted(stepIndex: 3, stepCount: 5),
                                                           .actionTargeted(.click, windowRelativePoint: CGPoint(x: 40, y: 50))])
        try expectEqual(replayingState.activity, .replaying)
        try expectEqual(replayingState.progress, 0.6)
        try expectEqual(replayingState.replayStepProgress, CursorReplayStepProgress(completedStepCount: 3, stepCount: 5))
        try expectEqual(replayingState.targetPointInWindow, CGPoint(x: 40, y: 50))
    },
    CoreTestCase(name: "a confirmation waits with buttons and an attention request, then returns to what came before") {
        let clickingState = cursorState(after: runningEvents + [.actionTargeted(.click, windowRelativePoint: nil)])
        let waitingState = cursorState(after: [.confirmationRequested(confirmationRequest(.sendingOrPublishing))], from: clickingState)
        try expectEqual(waitingState.activity, .waiting)
        try expectEqual(waitingState.decisionOptions.map(\.identifier), [.allow, .allowRestOfTask, .skip, .stop])
        let attentionRequest = try unwrapOrFail(waitingState.attentionRequest)
        try expectEqual(attentionRequest.kind, .needsDecision)
        try expectEqual(attentionRequest.bodyText, "“Reply to Ana”: This step will click “Send”.")
        let answeredState = cursorState(after: [.confirmationAnswered], from: waitingState)
        try expectEqual(answeredState.activity, .clicking)
        try expectEqual(answeredState.statusText, "Rename IMG_2042")
        try expectEqual(answeredState.attentionRequest, nil)
        try expectEqual(answeredState.decisionOptions, [])
        // With nothing to go back to, the cursor reads.
        var bareWaitingState = waitingState
        bareWaitingState.activityBeforeInterruption = nil
        try expectEqual(cursorState(after: [.confirmationAnswered], from: bareWaitingState).activity, .reading)
    },
    CoreTestCase(name: "bring-forward and upload confirmations get their own attention kind and button titles") {
        let bringForwardState = cursorState(after: runningEvents + [.confirmationRequested(confirmationRequest(.bringingAppForward))])
        try expectEqual(bringForwardState.attentionRequest?.kind, .needsBringForward)
        // The task-wide grant leads for bring-forward: the same app comes forward for many steps of one task.
        try expectEqual(bringForwardState.decisionOptions.map(\.identifier), [.allowRestOfTask, .allow, .skip, .stop])
        try expectEqual(bringForwardState.decisionOptions.map(\.title), ["Allow for this task", "Just this once", "Skip", "Stop"])
        try expectEqual(bringForwardState.decisionOptions.map(\.isPrimary), [true, false, false, false])
        try expectEqual(bringForwardState.attentionRequest?.title, "Let Dotto bring the app forward when it needs to?")
        // Sends, deletes and payments keep a single Allow as the primary answer.
        let riskyState = cursorState(after: runningEvents + [.confirmationRequested(confirmationRequest(.sendingOrPublishing))])
        try expectEqual(riskyState.decisionOptions.first(where: \.isPrimary)?.identifier, .allow)
        let uploadState = cursorState(after: runningEvents + [.confirmationRequested(confirmationRequest(.uploadingFiles))])
        try expectEqual(uploadState.attentionRequest?.kind, .needsDecision)
        try expectEqual(uploadState.attentionRequest?.title, "Attach files?")
    },
    CoreTestCase(name: "an item failure prompt is a stuck request with retry, skip and stop") {
        let stuckState = cursorState(after: runningEvents + [.itemFailureDecisionRequested(ChecklistItemFailureDecisionRequest(
            itemIdentifier: "item-2", itemLabel: "Rename IMG_2042", failureSummary: "typed hunter2 into the wrong field", attemptCount: 2))])
        try expectEqual(stuckState.activity, .error)
        let attentionRequest = try unwrapOrFail(stuckState.attentionRequest)
        try expectEqual(attentionRequest.kind, .stuck)
        try expectEqual(attentionRequest.decisionOptions.map(\.identifier), [.retry, .skip, .stop])
        // Model-written failure summaries can echo typed text, so they never reach a notification.
        try expectTrue(!attentionRequest.bodyText.contains("hunter2"), attentionRequest.bodyText)
        try expectEqual(cursorState(after: [.confirmationAnswered], from: stuckState).activity, .reading)
    },
    CoreTestCase(name: "pause shows the banner and a Resume button without asking for attention; resume reads again") {
        let pausedState = cursorState(after: runningEvents + [.paused(.userTookOver(.mouseClicked))])
        try expectEqual(pausedState.activity, .paused)
        try expectEqual(pausedState.statusText, "Paused: you clicked in the app Dotto is using. Resume?")
        try expectEqual(pausedState.decisionOptions.map(\.identifier), [.resume])
        try expectEqual(pausedState.attentionRequest, nil)
        let resumedState = cursorState(after: [.resumed], from: pausedState)
        try expectEqual(resumedState.activity, .reading)
        try expectEqual(resumedState.statusText, "Rename IMG_2042")
        try expectEqual(resumedState.decisionOptions, [])
    },
    CoreTestCase(name: "progress events while paused change only what the cursor returns to") {
        let pausedState = cursorState(after: runningEvents + [.paused(.requestedByUser), .modelTurnStarted])
        try expectEqual(pausedState.activity, .paused)
        try expectEqual(pausedState.activityBeforeInterruption, .thinking)
    },
    CoreTestCase(name: "the assist says the app comes forward, then restores the status") {
        let assistState = cursorState(after: runningEvents + [.foregroundAssistStarted])
        try expectEqual(assistState.statusText, CursorPresentationStateMapper.bringingAppForwardStatusText)
        let finishedState = cursorState(after: [.foregroundAssistFinished], from: assistState)
        try expectEqual(finishedState.activity, .reading)
        try expectEqual(finishedState.statusText, "Rename IMG_2042")
    },
    CoreTestCase(name: "a failed item shows the error state, a completed one done, a skipped one keeps the activity") {
        try expectEqual(cursorState(after: runningEvents + [.itemFinished(.failed)]).activity, .error)
        try expectEqual(cursorState(after: runningEvents + [.itemFinished(.completed)]).activity, .done)
        try expectEqual(cursorState(after: runningEvents + [.modelTurnStarted, .itemFinished(.skipped)]).activity, .thinking)
    },
    CoreTestCase(name: "runFinished is done or error, with a finished attention request") {
        let doneState = cursorState(after: runningEvents + [.runFinished(succeeded: true)])
        try expectEqual(doneState.activity, .done)
        try expectEqual(doneState.attentionRequest?.kind, .finished)
        try expectEqual(doneState.attentionRequest?.title, "Dotto finished")
        try expectEqual(doneState.attentionRequest?.decisionOptions, [])
        let stoppedState = cursorState(after: runningEvents + [.confirmationRequested(confirmationRequest(.deleting)), .runFinished(succeeded: false)])
        try expectEqual(stoppedState.activity, .error)
        try expectEqual(stoppedState.attentionRequest?.title, "Dotto stopped")
        try expectEqual(stoppedState.decisionOptions, [])
    },
    CoreTestCase(name: "every attention request gets a new identifier, also across runs") {
        let firstRequestState = cursorState(after: runningEvents + [.confirmationRequested(confirmationRequest(.deleting))])
        let secondRequestState = cursorState(after: [.confirmationAnswered, .confirmationRequested(confirmationRequest(.deleting))], from: firstRequestState)
        let nextRunState = cursorState(after: [.runStarted(targetWindow: nil), .confirmationRequested(confirmationRequest(.deleting))], from: secondRequestState)
        let identifiers = [firstRequestState, secondRequestState, nextRunState].compactMap(\.attentionRequest?.requestIdentifier)
        try expectEqual(identifiers, ["attention-1", "attention-2", "attention-3"])
    },
    CoreTestCase(name: "status and attention texts are single-line and truncated with an ellipsis") {
        let longLabel = "Rename\nthe\tfile " + String(repeating: "x", count: 100)
        let itemState = cursorState(after: [.runStarted(targetWindow: nil), .itemStarted(itemLabel: longLabel, itemPosition: 1, itemCount: 1)])
        let statusText = try unwrapOrFail(itemState.statusText)
        try expectEqual(statusText.count, 60)
        try expectTrue(statusText.hasPrefix("Rename the file xx") && statusText.hasSuffix("…"), statusText)
        let waitingState = cursorState(after: [.confirmationRequested(confirmationRequest(.deleting, reason: String(repeating: "y", count: 300)))],
                                 from: itemState)
        try expectEqual(waitingState.attentionRequest?.bodyText.count, UserAttentionRequest.maximumBodyTextLength)
    },
    CoreTestCase(name: "decision identifiers map onto confirmation answers and failure decisions") {
        try expectEqual(SafetyConfirmationAnswer(decisionOptionIdentifier: .allow), .allowOnce)
        try expectEqual(SafetyConfirmationAnswer(decisionOptionIdentifier: .allowRestOfTask), .allowForAllRemainingItems)
        try expectEqual(SafetyConfirmationAnswer(decisionOptionIdentifier: .skip), .skipItem)
        try expectEqual(SafetyConfirmationAnswer(decisionOptionIdentifier: .stop), .stopTask)
        try expectEqual(SafetyConfirmationAnswer(decisionOptionIdentifier: .resume), nil)
        try expectEqual(ChecklistItemFailureDecision(decisionOptionIdentifier: .retry), .retry)
        try expectEqual(ChecklistItemFailureDecision(decisionOptionIdentifier: .skip), .skipItem)
        try expectEqual(ChecklistItemFailureDecision(decisionOptionIdentifier: .allow), nil)
    },
])
