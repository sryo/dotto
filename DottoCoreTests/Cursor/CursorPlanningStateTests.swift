import Foundation
import CoreGraphics

let cursorPlanningStateTestSuite = CoreTestSuite(name: "CursorPlanningState", testCases: [
    CoreTestCase(name: "planning brings a hidden cursor up reading the target app") {
        let planningState = cursorState(after: [.planningStarted(targetApplicationName: "Finder")])
        try expectEqual(planningState.activity, .reading)
        try expectEqual(planningState.statusText, "Reading Finder…")
        try expectEqual(planningState.targetWindowIdentifier, nil)
        try expectEqual(cursorState(after: [.planningStarted(targetApplicationName: "")]).statusText,
                        CursorPresentationStateMapper.planningStatusText)
    },
    CoreTestCase(name: "planning progress reads, then thinks as Planning…") {
        let startedState = cursorState(after: [.planningStarted(targetApplicationName: "Finder")])
        let thinkingState = cursorState(after: [.planningProgressed(.thinking)], from: startedState)
        try expectEqual(thinkingState.activity, .thinking)
        try expectEqual(thinkingState.statusText, "Planning…")
        let readingAgainState = cursorState(after: [.planningProgressed(.readingApplication(applicationName: "Arc"))], from: thinkingState)
        try expectEqual(readingAgainState.activity, .reading)
        try expectEqual(readingAgainState.statusText, "Reading Arc…")
        let screenshotState = cursorState(after: [.planningProgressed(.takingScreenshot)], from: readingAgainState)
        try expectEqual(screenshotState.activity, .reading)
        try expectEqual(screenshotState.statusText, "Taking a screenshot…")
    },
    CoreTestCase(name: "a ready checklist waits for review without asking for attention; the run then starts fresh") {
        let reviewState = cursorState(after: [.planningStarted(targetApplicationName: "Finder"), .planningProgressed(.thinking),
                                              .checklistReadyForReview])
        try expectEqual(reviewState.activity, .waiting)
        try expectEqual(reviewState.statusText, CursorPresentationStateMapper.reviewChecklistStatusText)
        try expectEqual(reviewState.attentionRequest, nil)
        try expectEqual(reviewState.decisionOptions, [])
        let runningState = cursorState(after: [.runStarted(targetWindow: nil)], from: reviewState)
        try expectEqual(runningState.activity, .reading)
        try expectEqual(runningState.statusText, nil)
    },
    CoreTestCase(name: "a planner question waits at the summon point with its own text") {
        let needsInputState = cursorState(after: [.planningStarted(targetApplicationName: "Finder"), .plannerAskedForInput])
        try expectEqual(needsInputState.activity, .waiting)
        try expectEqual(needsInputState.statusText, CursorPresentationStateMapper.plannerNeedsInputStatusText)
        try expectEqual(needsInputState.attentionRequest, nil)
    },
    CoreTestCase(name: "a hidden cursor ignores planning progress and review until planning starts") {
        try expectEqual(cursorState(after: [.planningProgressed(.thinking)]), .hidden)
        try expectEqual(cursorState(after: [.checklistReadyForReview]), .hidden)
        try expectEqual(cursorState(after: [.plannerAskedForInput]), .hidden)
    },
    CoreTestCase(name: "planning keeps counting attention requests across tasks") {
        var finishedState = cursorState(after: [.runStarted(targetWindow: nil), .runFinished(succeeded: true)])
        finishedState = finishedState.hiddenKeepingAttentionRequestCount
        let planningState = cursorState(after: [.planningStarted(targetApplicationName: "Finder")], from: finishedState)
        try expectEqual(planningState.attentionRequestCount, 1)
    },
    CoreTestCase(name: "the planner's progress reads as the status line") {
        try expectEqual(ChecklistPlanningProgress.readingApplication(applicationName: "Finder").statusLineText, "Reading Finder…")
        try expectEqual(ChecklistPlanningProgress.takingScreenshot.statusLineText, "Taking a screenshot…")
        try expectEqual(ChecklistPlanningProgress.thinking.statusLineText, "Thinking…")
    },
])

private func workingPresentationState(_ activity: CursorActivity, statusText: String?) -> CursorPresentationState {
    CursorPresentationState(activity: activity, statusText: statusText, progress: nil, replayStepProgress: nil,
                            targetPointInWindow: nil, targetWindowIdentifier: nil)
}

let cursorPillProgressTextTestSuite = CoreTestSuite(name: "CursorPillText progress", testCases: [
    CoreTestCase(name: "working states lead with the item's place once an item has started") {
        let clickingState = workingPresentationState(.clicking, statusText: "Rename IMG_2042")
        try expectEqual(CursorPillText.text(for: clickingState, targetApplicationName: "Finder", pausedStatusText: nil,
                                            itemPosition: 2, itemCount: 5), "2 / 5 · Rename IMG_2042")
        let readingWithoutTextState = workingPresentationState(.reading, statusText: nil)
        try expectEqual(CursorPillText.text(for: readingWithoutTextState, targetApplicationName: "Finder", pausedStatusText: nil,
                                            itemPosition: 2, itemCount: 5), "2 / 5")
    },
    CoreTestCase(name: "planning texts and bring-forward statuses carry no item position") {
        let planningState = workingPresentationState(.thinking, statusText: CursorPresentationStateMapper.planningStatusText)
        try expectEqual(CursorPillText.text(for: planningState, targetApplicationName: "Finder", pausedStatusText: nil,
                                            itemPosition: nil, itemCount: nil), "Planning…")
        let bringingState = workingPresentationState(.pointing, statusText: CursorPresentationStateMapper.bringingAppForwardCountdownStatusText)
        try expectEqual(CursorPillText.text(for: bringingState, targetApplicationName: "Finder", pausedStatusText: nil,
                                            itemPosition: 2, itemCount: 5), "Bringing Finder forward…")
    },
    CoreTestCase(name: "an error keeps its own text, without the item position") {
        let stuckState = workingPresentationState(.error, statusText: "Stuck on “Rename IMG_2042”")
        try expectEqual(CursorPillText.text(for: stuckState, targetApplicationName: "Finder", pausedStatusText: nil,
                                            itemPosition: 2, itemCount: 5), "Stuck on “Rename IMG_2042”")
    },
])
