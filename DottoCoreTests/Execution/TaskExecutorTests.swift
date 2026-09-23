import Foundation
import CoreGraphics

/// A clock that moves on by a fixed step every time it is read.
private final class SteppingClock: @unchecked Sendable {
    var currentDate = Date(timeIntervalSince1970: 0)
    let stepSeconds: TimeInterval
    init(stepSeconds: TimeInterval) { self.stepSeconds = stepSeconds }
    func advanceAndRead() -> Date {
        currentDate = currentDate.addingTimeInterval(stepSeconds)
        return currentDate
    }
}

/// A window with one button per asking category, so the confirmation mechanics are exercised by actions that ask.
private func askingButtonsRootNodes() -> [AccessibilityElementNode] {
    var windowNode = ConversationFixtures.node("e1", role: "AXWindow", title: "Notes")
    windowNode.children = [ConversationFixtures.node("e4", role: "AXButton", title: "Send"),
                           ConversationFixtures.node("e5", role: "AXButton", title: "Delete"),
                           ConversationFixtures.node("e6", role: "AXButton", title: "Buy now")]
    return [windowNode]
}

private func clickTurn(_ elementIdentifier: String) throws -> ScriptedClaudeTransport.ScriptedReply {
    try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_\(elementIdentifier)", "click", ConversationFixtures.clickInput(elementIdentifier)))
}

let taskExecutorTestSuite = CoreTestSuite(name: "TaskExecutor", testCases: [
    CoreTestCase(name: "executor stops after three consecutive failed items") {
        let harness = try TaskExecutorTestHarness(replies: [
            // Failed items are retried automatically twice (ChecklistItemRetryPolicy), so each takes three attempts.
            try ConversationFixtures.finishItemTurn(outcome: "failed"),
            try ConversationFixtures.finishItemTurn(outcome: "failed"),
            try ConversationFixtures.finishItemTurn(outcome: "failed"),
            try ConversationFixtures.finishItemTurn(outcome: "needs_user"),
            try ConversationFixtures.finishItemTurn(outcome: "failed"),
            try ConversationFixtures.finishItemTurn(outcome: "failed"),
            try ConversationFixtures.finishItemTurn(outcome: "failed"),
            try ConversationFixtures.finishItemTurn(outcome: "completed"),
        ], canAskUser: false)
        let runSummary = await harness.run(ConversationFixtures.makeChecklist(itemLabels: ["one", "two", "three", "four"]))
        try expectEqual(runSummary.stopReason, .tooManyConsecutiveFailures)
        try expectEqual(runSummary.failedItemCount, 2)
        try expectEqual(runSummary.needsUserItemCount, 1)
        try expectEqual(await harness.observer.startedItemIdentifiers, ["item-1", "item-2", "item-3"])
        try expectTrue(harness.actionBackend.didFinishTask)
    },
    CoreTestCase(name: "executor: an irreversible item runs without asking up front; a Delete click asks and skips the item on request") {
        let harness = try TaskExecutorTestHarness(replies: [
            try clickTurn("e5"),
            try ConversationFixtures.finishItemTurn(outcome: "completed"),
        ], rootNodes: askingButtonsRootNodes(), confirmationAnswers: [.skipItem])
        let runSummary = await harness.run(ConversationFixtures.makeChecklist(itemLabels: ["Archive note", "Tidy note"],
                                                                              irreversibleItemLabels: ["Archive note"]))
        try expectEqual(runSummary.stopReason, .allItemsProcessed)
        try expectEqual(runSummary.skippedItemCount, 1)
        try expectEqual(runSummary.completedItemCount, 1)
        let confirmationRequests = await harness.confirmationRequester.receivedRequests
        try expectEqual(confirmationRequests.map(\.isActionLevel), [true])
        try expectEqual(confirmationRequests.map(\.riskCategory), [.deleting])
        try expectEqual(await harness.observer.startedItemIdentifiers, ["item-1", "item-2"])
        try expectTrue(harness.actionBackend.performedActions.isEmpty)
    },
    CoreTestCase(name: "an item interrupted by Stop is skipped, and reported before runFinished and the backend's finish") {
        let harness = try TaskExecutorTestHarness(replies: [
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_a", "click", ConversationFixtures.clickInput("e2"))),
            try ConversationFixtures.finishItemTurn(outcome: "completed"),
        ])
        let abortSignal = TaskAbortSignal()
        harness.actionBackend.actionHookAfterPerform = { _ in abortSignal.abort() }
        var finishedItemsWhenBackendFinished: [ChecklistItemRunStatus] = []
        harness.actionBackend.finishTaskHook = {
            finishedItemsWhenBackendFinished = await harness.observer.finishedItems.map(\.runStatus)
        }
        let runSummary = await harness.run(ConversationFixtures.makeChecklist(itemLabels: ["one", "two"]), abortSignal: abortSignal)
        try expectEqual(runSummary.stopReason, .userAborted)
        try expectEqual(runSummary.skippedItemCount, 1)
        try expectEqual(harness.actionBackend.performedActions.count, 1)
        try expectEqual(finishedItemsWhenBackendFinished, [.skipped])
        try expectEqual(await harness.observer.reportedCursorActivityEvents.last, .runFinished(succeeded: false))
        try expectTrue(harness.actionBackend.didFinishTask)
    },
    CoreTestCase(name: "runFinished and every item's final state are reported before the backend finishes the task") {
        let harness = try TaskExecutorTestHarness(replies: [
            try ConversationFixtures.finishItemTurn(outcome: "completed"),
            try ConversationFixtures.finishItemTurn(outcome: "completed"),
        ])
        var cursorEventsWhenBackendFinished: [CursorActivityEvent] = []
        var finishedItemCountWhenBackendFinished = 0
        harness.actionBackend.finishTaskHook = {
            cursorEventsWhenBackendFinished = await harness.observer.reportedCursorActivityEvents
            finishedItemCountWhenBackendFinished = await harness.observer.finishedItems.count
        }
        _ = await harness.run(ConversationFixtures.makeChecklist(itemLabels: ["one", "two"]))
        try expectEqual(cursorEventsWhenBackendFinished.last, .runFinished(succeeded: true))
        try expectEqual(finishedItemCountWhenBackendFinished, 2)
        try expectTrue(harness.actionBackend.didFinishTask)
    },
    CoreTestCase(name: "executor stops after two consecutive transport failures") {
        let transportError = CoreTestFailure(description: "api.anthropic.com unreachable")
        let harness = try TaskExecutorTestHarness(replies: [.failure(transportError), .failure(transportError)])
        let runSummary = await harness.run(ConversationFixtures.makeChecklist(itemLabels: ["one", "two", "three"]))
        guard case .unrecoverableError = runSummary.stopReason else {
            throw CoreTestFailure(description: "expected unrecoverableError, got \(runSummary.stopReason)")
        }
        try expectEqual(runSummary.failedItemCount, 2)
        try expectEqual(await harness.observer.finishedItems.map(\.runStatus), [.failed, .failed])
    },
    CoreTestCase(name: "executor: allow for all approves later actions of the same category only") {
        let harness = try TaskExecutorTestHarness(replies: [
            try clickTurn("e4"), try ConversationFixtures.finishItemTurn(outcome: "completed"),
            try clickTurn("e4"), try ConversationFixtures.finishItemTurn(outcome: "completed"),
            try clickTurn("e5"),
        ], rootNodes: askingButtonsRootNodes(), confirmationAnswers: [.allowForAllRemainingItems, .skipItem])
        let runSummary = await harness.run(ConversationFixtures.makeChecklist(itemLabels: ["Send note 1", "Send note 2", "Wipe note 3"],
                                                                              irreversibleItemLabels: ["Wipe note 3"]))
        let confirmationRequests = await harness.confirmationRequester.receivedRequests
        try expectEqual(confirmationRequests.map(\.itemIdentifier), ["item-1", "item-3"])
        try expectEqual(confirmationRequests.map(\.riskCategory), [.sendingOrPublishing, .deleting])
        try expectEqual(harness.actionBackend.performedActions, [.clickElement(elementIdentifier: "e4", clickType: .single),
                                                                 .clickElement(elementIdentifier: "e4", clickType: .single)])
        try expectEqual(runSummary.completedItemCount, 2)
        try expectEqual(runSummary.skippedItemCount, 1)
    },
    CoreTestCase(name: "executor: a sending grant never covers paying, and Stop at that question ends the task") {
        let harness = try TaskExecutorTestHarness(replies: [
            try clickTurn("e4"), try ConversationFixtures.finishItemTurn(outcome: "completed"),
            try clickTurn("e6"),
        ], rootNodes: askingButtonsRootNodes(), confirmationAnswers: [.allowForAllRemainingItems, .stopTask])
        let runSummary = await harness.run(ConversationFixtures.makeChecklist(itemLabels: ["Send note 1", "Order note 2"],
                                                                              irreversibleItemLabels: ["Order note 2"]))
        try expectEqual(await harness.confirmationRequester.receivedRequests.map(\.riskCategory), [.sendingOrPublishing, .payingOrBuying])
        try expectEqual(harness.actionBackend.performedActions, [.clickElement(elementIdentifier: "e4", clickType: .single)])
        try expectEqual(runSummary.stopReason, .userAborted)
    },
    CoreTestCase(name: "executor stops at the task-wide model turn ceiling") {
        var tightLimits = SafetyLimits.standard
        tightLimits.maximumModelTurnsPerTask = 2
        let harness = try TaskExecutorTestHarness(replies: [
            try ConversationFixtures.finishItemTurn(outcome: "completed"),
            try ConversationFixtures.finishItemTurn(outcome: "completed"),
            try ConversationFixtures.finishItemTurn(outcome: "completed"),
        ], safetyLimits: tightLimits)
        let runSummary = await harness.run(ConversationFixtures.makeChecklist(itemLabels: ["one", "two", "three"]))
        guard case .taskCeilingReached(let ceilingDescription) = runSummary.stopReason else {
            throw CoreTestFailure(description: "expected taskCeilingReached, got \(runSummary.stopReason)")
        }
        try expectTrue(ceilingDescription.contains("2 Claude turns"), ceilingDescription)
        try expectEqual(runSummary.completedItemCount, 2)
        try expectEqual(harness.transport.recordedRequests.count, 2)
    },
    CoreTestCase(name: "executor stops at the task-wide input token ceiling, mid-item") {
        var tightLimits = SafetyLimits.standard
        tightLimits.maximumInputTokensPerTask = 300
        let readTurn = try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_read", "read_ui",
            #"{"scope":"focused_window","application_name":null,"query":null}"#))
        let harness = try TaskExecutorTestHarness(replies: [readTurn, readTurn, readTurn], safetyLimits: tightLimits)
        let runSummary = await harness.run(ConversationFixtures.makeChecklist(itemLabels: ["one", "two"]))
        guard case .taskCeilingReached = runSummary.stopReason else {
            throw CoreTestFailure(description: "expected taskCeilingReached, got \(runSummary.stopReason)")
        }
        try expectEqual(harness.transport.recordedRequests.count, 2, "each scripted turn reports 180 input tokens")
        try expectEqual(await harness.observer.finishedItems.map(\.runStatus), [.failed])
    },
    CoreTestCase(name: "executor stops at the wall-clock ceiling, counted from the start of the run") {
        let steppingClock = SteppingClock(stepSeconds: 20 * 60)
        let harness = try TaskExecutorTestHarness(replies: [try ConversationFixtures.finishItemTurn(outcome: "completed")],
                                                  currentDate: { steppingClock.advanceAndRead() })
        let runSummary = await harness.run(ConversationFixtures.makeChecklist(itemLabels: ["one", "two"]))
        try expectEqual(runSummary.stopReason, .taskCeilingReached("the task ran for its 30-minute limit"))
        try expectEqual(harness.transport.recordedRequests.count, 0)
    },
    CoreTestCase(name: "time spent before the run (planning, review, teaching) doesn't count toward the wall clock") {
        let manualClock = SteppingClock(stepSeconds: 0)
        let taskResourceBudget = TaskResourceBudget(safetyLimits: .standard, currentDate: { manualClock.currentDate })
        manualClock.currentDate = manualClock.currentDate.addingTimeInterval(45 * 60)
        try taskResourceBudget.throwIfExhausted()
        taskResourceBudget.startRunWallClock()
        try taskResourceBudget.throwIfExhausted()
        manualClock.currentDate = manualClock.currentDate.addingTimeInterval(30 * 60)
        let ceilingError = try expectThrowsError { try taskResourceBudget.throwIfExhausted() }
        try expectEqual((ceilingError as? TaskCeilingReachedError)?.ceiling, .wallClock)
    },
    CoreTestCase(name: "planning turns count against the task-wide ceiling the run then draws on") {
        var tightLimits = SafetyLimits.standard
        tightLimits.maximumModelTurnsPerTask = 3
        let taskResourceBudget = TaskResourceBudget(safetyLimits: tightLimits)
        let planningTransport = ScriptedClaudeTransport(replies: [
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_read", "read_ui",
                #"{"scope":"focused_window","application_name":null,"query":null}"#)),
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_plan", "submit_plan",
                #"{"task_title":"Tidy","message_to_user":null,"items":[{"label":"one","action_summary":"Do one.","parameters":[],"is_irreversible":false},{"label":"two","action_summary":"Do two.","parameters":[],"is_irreversible":false}]}"#)),
        ])
        let checklistPlanner = ChecklistPlanner(transport: planningTransport,
                                                actionBackend: FakeActionBackend(snapshotRootNodes: ConversationFixtures.windowRootNodes()),
                                                auditLogWriter: try ConversationFixtures.makeAuditLogWriter(), taskResourceBudget: taskResourceBudget)
        let planningResult = try await checklistPlanner.produceChecklist(command: "tidy", targetApplication: fixtureTargetApplication,
                                                                        taskIdentifier: "test-task", abortSignal: TaskAbortSignal(),
                                                                        onProgress: { _ in })
        guard case .checklist(let plannedChecklist) = planningResult else {
            throw CoreTestFailure(description: "expected a checklist, got \(planningResult)")
        }
        try expectEqual(taskResourceBudget.modelTurnsUsed, 2)

        let harness = try TaskExecutorTestHarness(replies: [
            try ConversationFixtures.finishItemTurn(outcome: "completed"),
            try ConversationFixtures.finishItemTurn(outcome: "completed"),
        ], safetyLimits: tightLimits, taskResourceBudget: taskResourceBudget)
        let runSummary = await harness.run(plannedChecklist)
        try expectEqual(runSummary.stopReason, .taskCeilingReached("the task used its limit of 3 Claude turns"))
        try expectEqual(runSummary.completedItemCount, 1)
        try expectEqual(harness.transport.recordedRequests.count, 1)
    },
    CoreTestCase(name: "planning stops at the task-wide ceiling with its own error") {
        var tightLimits = SafetyLimits.standard
        tightLimits.maximumModelTurnsPerTask = 1
        let taskResourceBudget = TaskResourceBudget(safetyLimits: tightLimits)
        let planningTransport = ScriptedClaudeTransport(replies: [
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_read", "read_ui",
                #"{"scope":"focused_window","application_name":null,"query":null}"#)),
        ])
        let checklistPlanner = ChecklistPlanner(transport: planningTransport,
                                                actionBackend: FakeActionBackend(snapshotRootNodes: ConversationFixtures.windowRootNodes()),
                                                auditLogWriter: try ConversationFixtures.makeAuditLogWriter(), taskResourceBudget: taskResourceBudget)
        do {
            _ = try await checklistPlanner.produceChecklist(command: "tidy", targetApplication: fixtureTargetApplication,
                                                           taskIdentifier: "test-task", abortSignal: TaskAbortSignal(), onProgress: { _ in })
            throw CoreTestFailure(description: "expected the planning ceiling")
        } catch let planningError as ChecklistPlanningError {
            try expectEqual(planningError, .taskCeilingReached("the task used its limit of 1 Claude turns"))
            try expectEqual(TaskUserFacingMessages.userFacingDescription(ofPlanningError: planningError),
                            "Stopped: the task used its limit of 1 Claude turns")
        }
        try expectEqual(planningTransport.recordedRequests.count, 1)
    },
    CoreTestCase(name: "executor hands the upload allowlist to the backend and reports item and run cursor events") {
        let uploadFileAllowlist = UploadFileAllowlist(grants: [UploadFileGrant.userPicked(canonicalPath: "/Users/me/a.pdf", isDirectory: false)])
        let harness = try TaskExecutorTestHarness(replies: [try ConversationFixtures.finishItemTurn(outcome: "completed")],
                                                  uploadFileAllowlist: uploadFileAllowlist)
        let checklist = ConversationFixtures.makeChecklist(itemLabels: ["one"])
        _ = await harness.run(checklist)
        try expectEqual(harness.actionBackend.preparedTaskConfigurations,
                        [ActionBackendTaskConfiguration(targetApplication: checklist.targetApplication, uploadFileAllowlist: uploadFileAllowlist)])
        let cursorEvents = await harness.observer.reportedCursorActivityEvents
        try expectEqual(cursorEvents.first, .itemStarted(itemLabel: "one", itemPosition: 1, itemCount: 1))
        try expectEqual(cursorEvents.last, .runFinished(succeeded: true))
    },
])
