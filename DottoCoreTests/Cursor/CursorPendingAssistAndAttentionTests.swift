import Foundation
import CoreGraphics

private let sendConfirmation = CursorActivityEvent.confirmationRequested(SafetyConfirmationRequest(
    itemIdentifier: "item-1", itemLabel: "Reply to Ana", reason: "This step will click “Send”.", isActionLevel: true,
    riskCategory: .sendingOrPublishing))

let cursorPendingAssistAndAttentionTestSuite = CoreTestSuite(name: "Cursor pending assist and attention ids", testCases: [
    CoreTestCase(name: "attention ids stay unique across a hide and the next run") {
        let firstRunState = cursorState(after: [.runStarted(targetWindow: cursorFixtureTargetWindow), sendConfirmation])
        try expectEqual(firstRunState.attentionRequest?.requestIdentifier, "attention-1")
        let hiddenState = firstRunState.hiddenKeepingAttentionRequestCount
        try expectEqual(hiddenState.activity, .hidden)
        try expectEqual(hiddenState.attentionRequest, nil)
        let secondRunState = cursorState(after: [.runStarted(targetWindow: cursorFixtureTargetWindow), sendConfirmation], from: hiddenState)
        try expectEqual(secondRunState.attentionRequest?.requestIdentifier, "attention-2")
    },
    CoreTestCase(name: "waiting and the countdown keep the working state, and ending returns to it") {
        let workingState = cursorState(after: [.runStarted(targetWindow: cursorFixtureTargetWindow),
                                       .itemStarted(itemLabel: "Rename a", itemPosition: 1, itemCount: 2), .modelTurnStarted])
        let waitingState = cursorState(after: [.foregroundAssistWaitingForUser], from: workingState)
        try expectEqual(waitingState.statusText, CursorPresentationStateMapper.waitingForUserBeforeBringingAppForwardStatusText)
        try expectEqual(waitingState.decisionOptions, [])
        try expectEqual(waitingState.attentionRequest, nil, "waiting for the user to pause never chimes")
        let countdownState = cursorState(after: [.foregroundAssistCountdownStarted], from: waitingState)
        try expectEqual(countdownState.statusText, CursorPresentationStateMapper.bringingAppForwardCountdownStatusText)
        try expectEqual(countdownState.decisionOptions.map(\.identifier), [.cancel])
        let endedState = cursorState(after: [.foregroundAssistPendingEnded], from: countdownState)
        try expectEqual(endedState.activity, .thinking)
        try expectEqual(endedState.statusText, "Rename a")
        try expectEqual(endedState.decisionOptions, [])
        try expectEqual(cursorState(after: [.foregroundAssistPendingEnded], from: workingState), workingState, "ending with nothing pending is a no-op")
    },
    CoreTestCase(name: "Cancel is not a safety or item-failure answer") {
        try expectEqual(SafetyConfirmationAnswer(decisionOptionIdentifier: .cancel), nil)
        try expectEqual(ChecklistItemFailureDecision(decisionOptionIdentifier: .cancel), nil)
    },
])

let userDecisionAnswerPolicyTestSuite = CoreTestSuite(name: "UserDecisionAnswerPolicy", testCases: [
    CoreTestCase(name: "answers count only for the pending question") {
        let allowForCurrent = UserDecisionAnswer(optionIdentifier: .allow, attentionRequestIdentifier: "attention-4")
        try expectTrue(UserDecisionAnswerPolicy.accepts(allowForCurrent, pendingAttentionRequestIdentifier: "attention-4"))
        try expectTrue(!UserDecisionAnswerPolicy.accepts(allowForCurrent, pendingAttentionRequestIdentifier: "attention-5"), "stale id")
        try expectTrue(!UserDecisionAnswerPolicy.accepts(allowForCurrent, pendingAttentionRequestIdentifier: nil), "answered already")
        for answerOption in [UserDecisionOptionIdentifier.allow, .allowRestOfTask, .skip, .retry] {
            try expectTrue(!UserDecisionAnswerPolicy.accepts(UserDecisionAnswer(optionIdentifier: answerOption, attentionRequestIdentifier: nil),
                                                             pendingAttentionRequestIdentifier: "attention-4"), "\(answerOption) without an id")
        }
    },
    CoreTestCase(name: "Stop, Pause and Cancel count unless they name a stale request; Resume only while no question is pending") {
        for alwaysHonored in [UserDecisionOptionIdentifier.stop, .pause, .cancel] {
            try expectTrue(UserDecisionAnswerPolicy.accepts(UserDecisionAnswer(optionIdentifier: alwaysHonored, attentionRequestIdentifier: nil),
                                                            pendingAttentionRequestIdentifier: "attention-9"))
            try expectTrue(UserDecisionAnswerPolicy.accepts(UserDecisionAnswer(optionIdentifier: alwaysHonored, attentionRequestIdentifier: "attention-9"),
                                                            pendingAttentionRequestIdentifier: "attention-9"))
            try expectTrue(!UserDecisionAnswerPolicy.accepts(UserDecisionAnswer(optionIdentifier: alwaysHonored, attentionRequestIdentifier: "attention-1"),
                                                             pendingAttentionRequestIdentifier: "attention-9"), "a stale notification's \(alwaysHonored)")
        }
        let resume = UserDecisionAnswer(optionIdentifier: .resume, attentionRequestIdentifier: nil)
        try expectTrue(UserDecisionAnswerPolicy.accepts(resume, pendingAttentionRequestIdentifier: nil))
        try expectTrue(!UserDecisionAnswerPolicy.accepts(resume, pendingAttentionRequestIdentifier: "attention-2"))
    },
    CoreTestCase(name: "buttons ignore clicks for 0.5 s after they appear and after the question changes") {
        var clickGuard = UserDecisionClickGuard()
        clickGuard.noteDisplayedQuestion(signature: "attention-1|Dotto needs your OK|allow,skip", atUptimeSeconds: 10)
        try expectTrue(!clickGuard.acceptsClick(on: .allow, atUptimeSeconds: 10.3))
        try expectTrue(clickGuard.acceptsClick(on: .stop, atUptimeSeconds: 10.3), "Stop always works")
        try expectTrue(clickGuard.acceptsClick(on: .allow, atUptimeSeconds: 10.5))
        clickGuard.noteDisplayedQuestion(signature: "attention-1|Dotto needs your OK|allow,skip", atUptimeSeconds: 11)
        try expectTrue(clickGuard.acceptsClick(on: .allow, atUptimeSeconds: 11.1), "the same question doesn't re-arm")
        clickGuard.noteDisplayedQuestion(signature: "attention-1|Attach files?|allow,skip", atUptimeSeconds: 12)
        try expectTrue(!clickGuard.acceptsClick(on: .skip, atUptimeSeconds: 12.2), "changed text re-arms")
        try expectTrue(clickGuard.acceptsClick(on: .cancel, atUptimeSeconds: 12.2))
    },
])
