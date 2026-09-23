import Foundation

private let fixtureChecklist = makeFixtureChecklist(itemCount: 3)
private let fixtureSummary = TaskRunSummary(completedItemCount: 3, failedItemCount: 0, needsUserItemCount: 0,
                                            skippedItemCount: 0, stopReason: .allItemsProcessed)
private let fixtureConfirmationRequest = SafetyConfirmationRequest(itemIdentifier: "item-2", itemLabel: "Rename file 2",
                                                                   reason: "This step will click “Send”.", isActionLevel: true)

private let fixtureDecisionRequest = ChecklistItemFailureDecisionRequest(itemIdentifier: "item-2", itemLabel: "Rename file 2",
                                                                failureSummary: "The file was not found.", attemptCount: 3)
private let mouseTakeover = TaskPauseReason.userTookOver(.mouseClicked)

private func transition(_ currentState: TaskSessionState, _ event: TaskSessionEvent) -> TaskSessionState? {
    TaskSessionStateMachine.nextState(from: currentState, on: event)
}

private func checklistWithStatus(_ runStatus: ChecklistItemRunStatus, forItem itemIdentifier: String, in checklist: Checklist = fixtureChecklist) -> Checklist {
    checklist.updatingItem(withIdentifier: itemIdentifier) { $0.runStatus = runStatus }
}

let taskSessionStateMachineTestSuite = CoreTestSuite(name: "TaskSessionStateMachine", testCases: [
    CoreTestCase(name: "commandSubmitted starts planning from every resting state, trimmed") {
        let restingStates: [TaskSessionState] = [.idle, .plannerNeedsInput(command: "c", question: fixtureOpenQuestion),
                                                 .finished(checklist: fixtureChecklist, summary: fixtureSummary),
                                                 .failed(checklist: nil, reason: "r"), .aborted(checklist: fixtureChecklist)]
        for restingState in restingStates {
            try expectEqual(transition(restingState, .commandSubmitted("  rename files \n")), .planning(command: "rename files"), "\(restingState)")
        }
    },
    CoreTestCase(name: "blank command is rejected") {
        try expectEqual(transition(.idle, .commandSubmitted("   \n")), nil)
    },
    CoreTestCase(name: "planning transitions: plan, needs input, failure, abort") {
        try expectEqual(transition(.planning(command: "c"), .checklistProduced(fixtureChecklist)), .awaitingApproval(checklist: fixtureChecklist))
        try expectEqual(transition(.planning(command: "c"), .plannerAskedForInput(fixtureOpenQuestion)),
                        .plannerNeedsInput(command: "c", question: fixtureOpenQuestion))
        try expectEqual(transition(.planning(command: "c"), .planningFailed("refused")), .failed(checklist: nil, reason: "refused"))
        try expectEqual(transition(.planning(command: "c"), .abortRequested), .aborted(checklist: nil))
    },
    CoreTestCase(name: "a reply to the planner's question goes back to planning the same command") {
        try expectEqual(transition(.plannerNeedsInput(command: "c", question: fixtureOpenQuestion), .plannerReplySent),
                        .planning(command: "c"))
        let blockingExplanation = PlannerQuestion.blockingExplanation("Dotto can't see any files.")
        try expectEqual(transition(.plannerNeedsInput(command: "c", question: blockingExplanation), .plannerReplySent), nil)
        try expectEqual(transition(.idle, .plannerReplySent), nil)
        try expectEqual(transition(.planning(command: "c"), .plannerReplySent), nil)
    },
    CoreTestCase(name: "approval: edit, approve marks excluded items skipped, dismiss") {
        let editedChecklist = fixtureChecklist.updatingItem(withIdentifier: "item-2") { item in
            item.label = "Edited"
            item.wasLabelEditedByUser = true
            item.isIncludedByUser = false
        }
        try expectEqual(transition(.awaitingApproval(checklist: fixtureChecklist), .checklistEdited(editedChecklist)), .awaitingApproval(checklist: editedChecklist))
        try expectEqual(transition(.awaitingApproval(checklist: fixtureChecklist), .checklistApproved(editedChecklist)),
                        .executing(checklist: checklistWithStatus(.skipped, forItem: "item-2", in: editedChecklist), currentItemIdentifier: nil))
        try expectEqual(transition(.awaitingApproval(checklist: fixtureChecklist), .dismissed), .idle)
    },
    CoreTestCase(name: "approving a plan with no included items is invalid") {
        var checklistWithNothingIncluded = fixtureChecklist
        for itemIndex in checklistWithNothingIncluded.items.indices { checklistWithNothingIncluded.items[itemIndex].isIncludedByUser = false }
        try expectEqual(transition(.awaitingApproval(checklist: fixtureChecklist), .checklistApproved(checklistWithNothingIncluded)), nil)
    },
    CoreTestCase(name: "executing: item started, progressed, finished") {
        let executingState = TaskSessionState.executing(checklist: fixtureChecklist, currentItemIdentifier: nil)
        let runningChecklist = checklistWithStatus(.running, forItem: "item-1")
        try expectEqual(transition(executingState, .itemStarted(itemIdentifier: "item-1")),
                        .executing(checklist: runningChecklist, currentItemIdentifier: "item-1"))
        try expectEqual(transition(.executing(checklist: runningChecklist, currentItemIdentifier: nil), .itemProgressed(itemIdentifier: "item-1")),
                        .executing(checklist: runningChecklist, currentItemIdentifier: "item-1"))
        let finishedChecklist = runningChecklist.updatingItem(withIdentifier: "item-1") { item in
            item.runStatus = .completed
            item.resultSummary = "Renamed."
        }
        try expectEqual(transition(.executing(checklist: runningChecklist, currentItemIdentifier: "item-1"),
                                   .itemFinished(itemIdentifier: "item-1", runStatus: .completed, resultSummary: "Renamed.")),
                        .executing(checklist: finishedChecklist, currentItemIdentifier: nil))
    },
    CoreTestCase(name: "unknown item ids are invalid") {
        let executingState = TaskSessionState.executing(checklist: fixtureChecklist, currentItemIdentifier: nil)
        try expectEqual(transition(executingState, .itemStarted(itemIdentifier: "item-9")), nil)
        try expectEqual(transition(executingState, .itemFinished(itemIdentifier: "item-9", runStatus: .failed, resultSummary: "")), nil)
    },
    CoreTestCase(name: "safety confirmation round trip returns to the requesting item") {
        let executingState = TaskSessionState.executing(checklist: fixtureChecklist, currentItemIdentifier: "item-2")
        let confirmingState = TaskSessionState.awaitingSafetyConfirmation(checklist: fixtureChecklist, request: fixtureConfirmationRequest)
        try expectEqual(transition(executingState, .safetyConfirmationRequested(fixtureConfirmationRequest)), confirmingState)
        try expectEqual(transition(confirmingState, .safetyConfirmationAnswered),
                        .executing(checklist: fixtureChecklist, currentItemIdentifier: "item-2"))
    },
    CoreTestCase(name: "abort while executing or confirming skips the running item") {
        let runningChecklist = checklistWithStatus(.running, forItem: "item-2")
        let expectedAbortedState = TaskSessionState.aborted(checklist: checklistWithStatus(.skipped, forItem: "item-2"))
        try expectEqual(transition(.executing(checklist: runningChecklist, currentItemIdentifier: "item-2"), .abortRequested), expectedAbortedState)
        try expectEqual(transition(.awaitingSafetyConfirmation(checklist: runningChecklist, request: fixtureConfirmationRequest), .abortRequested),
                        expectedAbortedState)
    },
    CoreTestCase(name: "execution finished and dismissal of terminal states") {
        try expectEqual(transition(.executing(checklist: fixtureChecklist, currentItemIdentifier: nil), .executionFinished(fixtureSummary)),
                        .finished(checklist: fixtureChecklist, summary: fixtureSummary))
        let dismissibleStates: [TaskSessionState] = [.plannerNeedsInput(command: "c", question: fixtureOpenQuestion),
                                                     .finished(checklist: fixtureChecklist, summary: fixtureSummary),
                                                     .failed(checklist: fixtureChecklist, reason: "r"), .aborted(checklist: nil)]
        for dismissibleState in dismissibleStates {
            try expectEqual(transition(dismissibleState, .dismissed), .idle, "\(dismissibleState)")
        }
    },
    CoreTestCase(name: "invalid pairs are rejected, across planning, running, pausing and teaching") {
        let executingState = TaskSessionState.executing(checklist: fixtureChecklist, currentItemIdentifier: nil)
        let invalidPairs: [(TaskSessionState, TaskSessionEvent)] = [
            (.idle, .checklistProduced(fixtureChecklist)),
            (.idle, .abortRequested),
            (.idle, .dismissed),
            (.planning(command: "c"), .commandSubmitted("again")),
            (.planning(command: "c"), .checklistApproved(fixtureChecklist)),
            (.planning(command: "c"), .dismissed),
            (.awaitingApproval(checklist: fixtureChecklist), .itemStarted(itemIdentifier: "item-1")),
            (.awaitingApproval(checklist: fixtureChecklist), .commandSubmitted("new")),
            (executingState, .commandSubmitted("new")),
            (executingState, .dismissed),
            (executingState, .checklistEdited(fixtureChecklist)),
            (executingState, .safetyConfirmationAnswered),
            (.awaitingSafetyConfirmation(checklist: fixtureChecklist, request: fixtureConfirmationRequest), .itemFinished(itemIdentifier: "item-2", runStatus: .completed, resultSummary: "")),
            (.aborted(checklist: fixtureChecklist), .itemFinished(itemIdentifier: "item-1", runStatus: .completed, resultSummary: "late")),
            (.aborted(checklist: fixtureChecklist), .executionFinished(fixtureSummary)),
            (.finished(checklist: fixtureChecklist, summary: fixtureSummary), .abortRequested),
            (.awaitingSafetyConfirmation(checklist: fixtureChecklist, request: fixtureConfirmationRequest), .pauseRequested(.requestedByUser)),
            (.paused(checklist: fixtureChecklist, currentItemIdentifier: nil, reason: .requestedByUser), .pauseRequested(mouseTakeover)),
            (executingState, .demonstrationStarted(itemIdentifier: "item-1")),
            (executingState, .routineChecklistPrepared(fixtureChecklist)),
            (executingState, .resumeRequested),
            (executingState, .itemFailureDecisionAnswered),
            (.idle, .pauseRequested(.requestedByUser)),
            (.awaitingApproval(checklist: fixtureChecklist), .demonstrationRecordingStopped),
        ]
        for (currentState, event) in invalidPairs {
            try expectEqual(transition(currentState, event), nil, "\(event) in \(currentState)")
        }
    },
    CoreTestCase(name: "isBusy and currentChecklist in every state") {
        try expectTrue(TaskSessionState.planning(command: "c").isBusy)
        try expectTrue(TaskSessionState.executing(checklist: fixtureChecklist, currentItemIdentifier: nil).isBusy)
        try expectTrue(TaskSessionState.awaitingSafetyConfirmation(checklist: fixtureChecklist, request: fixtureConfirmationRequest).isBusy)
        try expectTrue(!TaskSessionState.awaitingApproval(checklist: fixtureChecklist).isBusy)
        try expectTrue(!TaskSessionState.idle.isBusy)
        try expectEqual(TaskSessionState.idle.currentChecklist, nil)
        try expectEqual(TaskSessionState.awaitingApproval(checklist: fixtureChecklist).currentChecklist, fixtureChecklist)
        try expectEqual(TaskSessionState.failed(checklist: fixtureChecklist, reason: "r").currentChecklist, fixtureChecklist)
        let pausedState = TaskSessionState.paused(checklist: fixtureChecklist, currentItemIdentifier: nil, reason: .requestedByUser)
        let decidingState = TaskSessionState.awaitingItemFailureDecision(checklist: fixtureChecklist, request: fixtureDecisionRequest)
        let demonstratingState = TaskSessionState.demonstrating(checklist: fixtureChecklist, itemIdentifier: "item-1", isCompilingRoutine: false)
        try expectTrue(pausedState.isBusy)
        try expectTrue(decidingState.isBusy)
        try expectTrue(!demonstratingState.isBusy, "a demonstration is the user working, not Dotto")
        for stateWithChecklist in [pausedState, decidingState, demonstratingState] {
            try expectEqual(stateWithChecklist.currentChecklist, fixtureChecklist, "\(stateWithChecklist)")
        }
    },
    CoreTestCase(name: "pause and resume keep the plan, current item and reason") {
        let pausedState = TaskSessionState.paused(checklist: fixtureChecklist, currentItemIdentifier: "item-2", reason: mouseTakeover)
        try expectEqual(transition(.executing(checklist: fixtureChecklist, currentItemIdentifier: "item-2"), .pauseRequested(mouseTakeover)), pausedState)
        try expectEqual(transition(pausedState, .resumeRequested), .executing(checklist: fixtureChecklist, currentItemIdentifier: "item-2"))
    },
    CoreTestCase(name: "item events while paused update the plan and stay paused") {
        let runningChecklist = checklistWithStatus(.running, forItem: "item-2")
        try expectEqual(transition(.paused(checklist: fixtureChecklist, currentItemIdentifier: nil, reason: .requestedByUser), .itemStarted(itemIdentifier: "item-2")),
                        .paused(checklist: runningChecklist, currentItemIdentifier: "item-2", reason: .requestedByUser))
        try expectEqual(transition(.paused(checklist: runningChecklist, currentItemIdentifier: nil, reason: mouseTakeover), .itemProgressed(itemIdentifier: "item-2")),
                        .paused(checklist: runningChecklist, currentItemIdentifier: "item-2", reason: mouseTakeover))
        let finishedChecklist = runningChecklist.updatingItem(withIdentifier: "item-2") { item in
            item.runStatus = .completed
            item.resultSummary = "Renamed."
        }
        try expectEqual(transition(.paused(checklist: runningChecklist, currentItemIdentifier: "item-2", reason: mouseTakeover),
                                   .itemFinished(itemIdentifier: "item-2", runStatus: .completed, resultSummary: "Renamed.")),
                        .paused(checklist: finishedChecklist, currentItemIdentifier: nil, reason: mouseTakeover))
        try expectEqual(transition(.paused(checklist: fixtureChecklist, currentItemIdentifier: nil, reason: mouseTakeover), .itemStarted(itemIdentifier: "item-9")), nil)
    },
    CoreTestCase(name: "paused: execution finished, abort, and late requests reach the user") {
        let runningChecklist = checklistWithStatus(.running, forItem: "item-2")
        let pausedState = TaskSessionState.paused(checklist: runningChecklist, currentItemIdentifier: "item-2", reason: mouseTakeover)
        try expectEqual(transition(pausedState, .executionFinished(fixtureSummary)), .finished(checklist: runningChecklist, summary: fixtureSummary))
        try expectEqual(transition(pausedState, .abortRequested), .aborted(checklist: checklistWithStatus(.skipped, forItem: "item-2")))
        try expectEqual(transition(pausedState, .safetyConfirmationRequested(fixtureConfirmationRequest)),
                        .awaitingSafetyConfirmation(checklist: runningChecklist, request: fixtureConfirmationRequest))
        try expectEqual(transition(pausedState, .itemFailureDecisionRequested(fixtureDecisionRequest)),
                        .awaitingItemFailureDecision(checklist: runningChecklist, request: fixtureDecisionRequest))
    },
    CoreTestCase(name: "item failure decision round trip and abort") {
        let runningChecklist = checklistWithStatus(.running, forItem: "item-2")
        let decidingState = TaskSessionState.awaitingItemFailureDecision(checklist: runningChecklist, request: fixtureDecisionRequest)
        try expectEqual(transition(.executing(checklist: runningChecklist, currentItemIdentifier: "item-2"), .itemFailureDecisionRequested(fixtureDecisionRequest)),
                        decidingState)
        try expectEqual(transition(decidingState, .itemFailureDecisionAnswered), .executing(checklist: runningChecklist, currentItemIdentifier: "item-2"))
        try expectEqual(transition(decidingState, .abortRequested), .aborted(checklist: checklistWithStatus(.skipped, forItem: "item-2")))
    },
    CoreTestCase(name: "demonstration: start, stop recording, finish, cancel, dismiss") {
        let recordingState = TaskSessionState.demonstrating(checklist: fixtureChecklist, itemIdentifier: "item-1", isCompilingRoutine: false)
        let compilingState = TaskSessionState.demonstrating(checklist: fixtureChecklist, itemIdentifier: "item-1", isCompilingRoutine: true)
        try expectEqual(transition(.awaitingApproval(checklist: fixtureChecklist), .demonstrationStarted(itemIdentifier: "item-1")), recordingState)
        try expectEqual(transition(recordingState, .demonstrationRecordingStopped), compilingState)
        let demonstratedChecklist = checklistWithStatus(.completed, forItem: "item-1")
        try expectEqual(transition(compilingState, .demonstrationFinished(demonstratedChecklist)), .awaitingApproval(checklist: demonstratedChecklist))
        try expectEqual(transition(recordingState, .demonstrationCancelled), .awaitingApproval(checklist: fixtureChecklist))
        try expectEqual(transition(compilingState, .demonstrationCancelled), .awaitingApproval(checklist: fixtureChecklist))
        try expectEqual(transition(recordingState, .dismissed), .idle)
    },
    CoreTestCase(name: "demonstration needs an included, pending item") {
        let excludedChecklist = fixtureChecklist.updatingItem(withIdentifier: "item-1") { $0.isIncludedByUser = false }
        try expectEqual(transition(.awaitingApproval(checklist: excludedChecklist), .demonstrationStarted(itemIdentifier: "item-1")), nil)
        try expectEqual(transition(.awaitingApproval(checklist: checklistWithStatus(.completed, forItem: "item-1")), .demonstrationStarted(itemIdentifier: "item-1")), nil)
        try expectEqual(transition(.awaitingApproval(checklist: fixtureChecklist), .demonstrationStarted(itemIdentifier: "item-9")), nil)
        try expectEqual(transition(.demonstrating(checklist: fixtureChecklist, itemIdentifier: "item-1", isCompilingRoutine: false),
                                   .demonstrationFinished(fixtureChecklist)), nil)
    },
    CoreTestCase(name: "routinePlanPrepared goes to approval from resting states, never with an empty plan") {
        let restingStates: [TaskSessionState] = [.idle, .plannerNeedsInput(command: "c", question: fixtureOpenQuestion), .awaitingApproval(checklist: fixtureChecklist),
                                                 .finished(checklist: fixtureChecklist, summary: fixtureSummary), .failed(checklist: nil, reason: "r"),
                                                 .aborted(checklist: nil)]
        for restingState in restingStates {
            try expectEqual(transition(restingState, .routineChecklistPrepared(fixtureChecklist)), .awaitingApproval(checklist: fixtureChecklist), "\(restingState)")
        }
        try expectEqual(transition(.idle, .routineChecklistPrepared(makeFixtureChecklist(itemCount: 0))), nil)
    },
])

private let fixtureOpenQuestion = PlannerQuestion(text: "Which folder?", choices: [], allowsFreeText: true)
