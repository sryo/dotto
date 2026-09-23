import Foundation
import CoreGraphics

private func directRoutePillText(for presentationState: CursorPresentationState, itemPosition: Int? = nil,
                                 itemCount: Int? = nil) -> String {
    CursorPillText.text(for: presentationState, targetApplicationName: "Finder", pausedStatusText: nil,
                        itemPosition: itemPosition, itemCount: itemCount)
}

private let directRouteRunStartEvents: [CursorActivityEvent] = [
    .runStarted(targetWindow: nil), .itemStarted(itemLabel: "Move 23 screenshots into month folders", itemPosition: 2, itemCount: 2),
]

let cursorDirectRouteProgressTestSuite = CoreTestSuite(name: "CursorDirectRouteProgress", testCases: [
    CoreTestCase(name: "operation progress shows the count and the operation, not the item position") {
        let progressedState = cursorState(after: directRouteRunStartEvents + [
            .directOperationProgressed(completedCount: 12, totalCount: 23, operationDescription: "Moving IMG_2041"),
        ])
        try expectEqual(progressedState.activity, .replaying)
        try expectEqual(progressedState.statusText, "Moving IMG_2041")
        try expectEqual(progressedState.replayStepProgress, nil)
        try expectEqual(progressedState.directOperationProgress, CursorReplayStepProgress(completedStepCount: 12, stepCount: 23))
        try expectEqual(progressedState.progress, 12.0 / 23.0)
        try expectEqual(directRoutePillText(for: progressedState, itemPosition: 2, itemCount: 2), "12 / 23 · Moving IMG_2041")
    },
    CoreTestCase(name: "the cursor stays parked: operation progress never sets a point to fly to") {
        let progressedState = cursorState(after: directRouteRunStartEvents + [
            .directOperationProgressed(completedCount: 1, totalCount: 4, operationDescription: "Creating “2026-09 Septiembre”"),
        ])
        try expectEqual(progressedState.targetPointInWindow, nil)
        try expectEqual(progressedState.targetWindowIdentifier, nil)
    },
    CoreTestCase(name: "routine replay text is unchanged when there is no operation progress") {
        let replayState = cursorState(after: directRouteRunStartEvents + [.replayStepStarted(stepIndex: 1, stepCount: 4)])
        try expectEqual(replayState.directOperationProgress, nil)
        try expectEqual(directRoutePillText(for: replayState, itemPosition: 2, itemCount: 5), "Replaying · 2 / 5")
    },
    CoreTestCase(name: "a new item or replay step clears the operation count") {
        let progressedState = cursorState(after: directRouteRunStartEvents + [
            .directOperationProgressed(completedCount: 4, totalCount: 4, operationDescription: "Creating “2026-12 Diciembre”"),
        ])
        let nextItemState = cursorState(after: [.itemStarted(itemLabel: "Move 23 screenshots", itemPosition: 2, itemCount: 2)],
                                        from: progressedState)
        try expectEqual(nextItemState.directOperationProgress, nil)
        let replayState = cursorState(after: [.replayStepStarted(stepIndex: 0, stepCount: 2)], from: progressedState)
        try expectEqual(replayState.directOperationProgress, nil)
    },
    CoreTestCase(name: "a question during the run keeps the count for when it returns") {
        let progressedState = cursorState(after: directRouteRunStartEvents + [
            .directOperationProgressed(completedCount: 3, totalCount: 23, operationDescription: "Moving IMG_2043"),
        ])
        let confirmationRequest = SafetyConfirmationRequest(itemIdentifier: "item-2", itemLabel: "Sort screenshots",
                                                            reason: "Moves 2 files to the Trash.", isActionLevel: false,
                                                            riskCategory: .deleting)
        let waitingState = cursorState(after: [.confirmationRequested(confirmationRequest)], from: progressedState)
        try expectEqual(waitingState.activity, .waiting)
        let answeredState = cursorState(after: [.confirmationAnswered], from: waitingState)
        try expectEqual(answeredState.activity, .replaying)
        try expectEqual(directRoutePillText(for: answeredState), "3 / 23 · Moving IMG_2043")
    },
    CoreTestCase(name: "the finished run shows Done and drops the count") {
        let finishedState = cursorState(after: directRouteRunStartEvents + [
            .directOperationProgressed(completedCount: 23, totalCount: 23, operationDescription: "Moving IMG_2063"),
            .runFinished(succeeded: true),
        ])
        try expectEqual(finishedState.activity, .done)
        try expectEqual(finishedState.directOperationProgress, nil)
        try expectEqual(directRoutePillText(for: finishedState), "Done")
        let stoppedState = cursorState(after: directRouteRunStartEvents + [
            .directOperationProgressed(completedCount: 5, totalCount: 23, operationDescription: "Moving IMG_2045"),
            .runFinished(succeeded: false),
        ])
        try expectEqual(stoppedState.activity, .error)
        try expectEqual(directRoutePillText(for: stoppedState), "Stopped")
    },
    CoreTestCase(name: "a shortcut confirmation offers no rest-of-task grant; scripts and other categories keep it") {
        func decisionOptionIdentifiers(for riskCategory: SafetyRiskCategory) -> [UserDecisionOptionIdentifier] {
            let confirmationRequest = SafetyConfirmationRequest(itemIdentifier: "item-1", itemLabel: "Run shortcut “Resize for web”",
                                                                reason: "Shortcuts can do anything.", isActionLevel: false,
                                                                riskCategory: riskCategory)
            let waitingState = cursorState(after: directRouteRunStartEvents + [.confirmationRequested(confirmationRequest)])
            return waitingState.decisionOptions.map(\.identifier)
        }
        try expectEqual(decisionOptionIdentifiers(for: .runningShortcut), [.allow, .skip, .stop])
        try expectEqual(decisionOptionIdentifiers(for: .runningScript), [.allow, .allowRestOfTask, .skip, .stop])
        try expectEqual(decisionOptionIdentifiers(for: .deleting), [.allow, .allowRestOfTask, .skip, .stop])
        for riskCategory in SafetyRiskCategory.allCases where !riskCategory.offersRestOfTaskGrant {
            try expectTrue(!decisionOptionIdentifiers(for: riskCategory).contains(.allowRestOfTask), "\(riskCategory)")
        }
    },
    CoreTestCase(name: "the shortcut question names the shortcut item on the pill") {
        let confirmationRequest = SafetyConfirmationRequest(itemIdentifier: "item-1", itemLabel: "Run shortcut “Resize for web”",
                                                            reason: "Shortcuts can do anything.", isActionLevel: false,
                                                            riskCategory: .runningShortcut)
        let waitingState = cursorState(after: [.runStarted(targetWindow: nil),
                                               .itemStarted(itemLabel: "Run shortcut “Resize for web”", itemPosition: 1, itemCount: 1),
                                               .confirmationRequested(confirmationRequest)])
        try expectEqual(directRoutePillText(for: waitingState), "Run your shortcut? · Run shortcut “Resize for web”")
    },
    CoreTestCase(name: "a hidden cursor ignores operation progress") {
        let hiddenState = CursorPresentationStateMapper.nextState(
            from: .hidden, on: .directOperationProgressed(completedCount: 1, totalCount: 2, operationDescription: "Moving a"))
        try expectEqual(hiddenState, .hidden)
    },
])
