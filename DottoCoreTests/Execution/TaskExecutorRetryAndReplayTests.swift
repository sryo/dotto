import Foundation
import CoreGraphics

let taskExecutorRetryAndReplayTestSuite = CoreTestSuite(name: "TaskExecutorRetryAndReplay", testCases: [
    CoreTestCase(name: "executor: a failed item retries twice with the reason, then asks; retry, then skip") {
        let failedTurn = try ConversationFixtures.finishItemTurn(outcome: "failed", summary: "file not found")
        let harness = try TaskExecutorTestHarness(replies: [failedTurn, failedTurn, failedTurn, failedTurn], rootNodes: RoutineRunFixtures.finderRootNodes(),
                                                 failureDecisions: [.retry, .skipItem])
        let runSummary = await harness.run(RoutineRunFixtures.renameChecklist(oldNames: ["a.png"]))
        let initialTexts = harness.transport.recordedRequests.map(ConversationFixtures.initialUserText)
        try expectEqual(initialTexts.count, 4)
        try expectTrue(!initialTexts[0].contains("Attempt 1 of this item failed"))
        try expectTrue(initialTexts[1].contains("Attempt 1 of this item failed: file not found"), initialTexts[1])
        try expectTrue(initialTexts[2].contains("Attempt 2 of this item failed"), initialTexts[2])
        try expectEqual(await harness.interactionHandler.receivedDecisionRequests.map(\.attemptCount), [3, 4])
        try expectEqual(runSummary.skippedItemCount, 1)
        try expectEqual(runSummary.stopReason, .allItemsProcessed)
    },
    CoreTestCase(name: "executor: stop at the failure decision aborts the task") {
        let failedTurn = try ConversationFixtures.finishItemTurn(outcome: "failed")
        let harness = try TaskExecutorTestHarness(replies: [failedTurn, failedTurn, failedTurn], rootNodes: RoutineRunFixtures.finderRootNodes(), failureDecisions: [.stopTask])
        let runSummary = await harness.run(RoutineRunFixtures.renameChecklist(oldNames: ["a.png", "b.png"]))
        try expectEqual(runSummary.stopReason, .userAborted)
        try expectEqual(await harness.observer.startedItemIdentifiers, ["item-1"])
    },
    CoreTestCase(name: "executor: an irreversible failed item is never retried automatically") {
        let harness = try TaskExecutorTestHarness(replies: [try ConversationFixtures.finishItemTurn(outcome: "failed")], rootNodes: RoutineRunFixtures.finderRootNodes(),
                                                 failureDecisions: [.skipItem])
        let runSummary = await harness.run(RoutineRunFixtures.renameChecklist(oldNames: ["a.png"], irreversible: true))
        try expectEqual(harness.transport.recordedRequests.count, 1)
        try expectEqual(await harness.interactionHandler.receivedDecisionRequests.map(\.attemptCount), [1])
        try expectEqual(runSummary.skippedItemCount, 1)
    },
    CoreTestCase(name: "executor: the first verified item becomes a routine and the rest replay without Claude") {
        let harness = try TaskExecutorTestHarness(replies: try RoutineRunFixtures.agentRenameTurns(fieldIdentifier: "e11", newName: "shot-01.png"), rootNodes: RoutineRunFixtures.finderRootNodes())
        let runSummary = await harness.run(RoutineRunFixtures.renameChecklist())
        try expectEqual(runSummary.completedItemCount, 3)
        try expectEqual(harness.transport.recordedRequests.count, 3, "item 1 only")
        try expectEqual(harness.actionBackend.performedActions.suffix(4), [
            .clickElement(elementIdentifier: "e13", clickType: .single),
            .typeText(elementIdentifier: "e13", text: "shot-02.png", replaceExistingText: true, pressReturnAfter: false),
            .clickElement(elementIdentifier: "e15", clickType: .single),
            .typeText(elementIdentifier: "e15", text: "shot-03.png", replaceExistingText: true, pressReturnAfter: false),
        ])
        try expectEqual(harness.metricsAccumulator.currentMetrics.itemsCompletedByReplay, 2)
        let updatedRoutines = await harness.interactionHandler.updatedRoutines
        try expectEqual(updatedRoutines.map(\.wasNewlyLearned), [true])
        try expectEqual(updatedRoutines.map(\.routine.routineIdentifier), ["routine-test-task"])
    },
    CoreTestCase(name: "executor: a replay locator miss falls back to the agent and patches the routine") {
        // The recorded field's role no longer matches (say the app switched views), so step 1 can't resolve.
        var routineWithStaleFirstStep = try RoutineRunFixtures.learnedRenameRoutine()
        routineWithStaleFirstStep.steps[0].targetLocator?.role = "AXComboBox"
        let harness = try TaskExecutorTestHarness(replies: try RoutineRunFixtures.agentRenameTurns(fieldIdentifier: "e11", newName: "shot-01.png"), rootNodes: RoutineRunFixtures.finderRootNodes(),
            routineToReplay: routineWithStaleFirstStep)
        let runSummary = await harness.run(RoutineRunFixtures.renameChecklist(oldNames: ["a.png"]))
        try expectEqual(runSummary.completedItemCount, 1)
        let fallbackInitialText = ConversationFixtures.initialUserText(of: harness.transport.recordedRequests[0])
        try expectTrue(fallbackInitialText.contains("step 1 (“"), fallbackInitialText)
        try expectEqual(harness.metricsAccumulator.currentMetrics.replayFallbacksToAgent, 1)
        try expectEqual(harness.taskExecutor.currentRoutine?.patchCount, 1)
        let updatedRoutines = await harness.interactionHandler.updatedRoutines
        try expectEqual(updatedRoutines.map(\.wasNewlyLearned), [false])
        try expectEqual(updatedRoutines.map(\.routine.patchCount), [1])
        try expectEqual(harness.metricsAccumulator.currentMetrics.itemsCompletedAfterReplayFallback, 1)
        try expectEqual(harness.metricsAccumulator.currentMetrics.itemsCompletedByAgent, 0)
    },
    CoreTestCase(name: "executor: a confirm-each-item step asks per item until allowed for all") {
        var routine = try RoutineRunFixtures.learnedRenameRoutine()
        routine.steps[0].requiresConfirmationEachItem = true
        routine.steps[0].confirmationRiskCategory = .sendingOrPublishing
        let harness = try TaskExecutorTestHarness(replies: [], rootNodes: RoutineRunFixtures.finderRootNodes(), routineToReplay: routine,
                                                 confirmationAnswers: [.allowOnce, .allowForAllRemainingItems])
        let runSummary = await harness.run(RoutineRunFixtures.renameChecklist())
        try expectEqual(runSummary.completedItemCount, 3)
        let confirmationRequests = await harness.confirmationRequester.receivedRequests
        try expectEqual(confirmationRequests.map(\.itemIdentifier), ["item-1", "item-2"])
        try expectEqual(confirmationRequests.map(\.riskCategory), [.sendingOrPublishing, .sendingOrPublishing])
        try expectTrue(harness.transport.recordedRequests.isEmpty)
    },
    CoreTestCase(name: "executor: replay never types into a password field and does not fall back") {
        var routine = try RoutineRunFixtures.learnedRenameRoutine()
        routine.steps = [RoutineStep(
            stepDescription: "Type “{{new_name}}”", action: .typeText(textTemplate: "{{new_name}}", replaceExistingText: true, pressReturnAfter: false),
            targetLocator: ElementLocator(role: "AXTextField", subrole: "AXSecureTextField", titleTemplate: "Password", descriptionTemplate: nil,
                                          valueTemplate: nil, descendantTextTemplate: nil, placeholder: nil, accessibilityIdentifier: nil,
                                          ancestorsNearestFirst: [], normalizedPositionInWindow: nil, readScope: .focusedWindow),
            expectation: nil, requiresConfirmationEachItem: false)]
        let harness = try TaskExecutorTestHarness(replies: [], rootNodes: makePasswordFieldWindowRootNodes(), routineToReplay: routine, canAskUser: false)
        let runSummary = await harness.run(RoutineRunFixtures.renameChecklist(oldNames: ["a.png"]))
        try expectEqual(runSummary.failedItemCount, 1)
        try expectTrue(harness.actionBackend.performedActions.isEmpty)
        try expectTrue(harness.transport.recordedRequests.isEmpty, "a denial must not fall back to the agent")
    },
    CoreTestCase(name: "executor: a pause between items holds the next item until resume") {
        let harness = try TaskExecutorTestHarness(replies: [], rootNodes: RoutineRunFixtures.finderRootNodes(), routineToReplay: try RoutineRunFixtures.learnedRenameRoutine())
        harness.runControl.requestPause(reason: .requestedByUser)
        let runTask = Task { await harness.run(RoutineRunFixtures.renameChecklist(oldNames: ["a.png"])) }
        try await Task.sleep(nanoseconds: 50_000_000)
        try expectTrue(await harness.observer.startedItemIdentifiers.isEmpty)
        harness.runControl.resume()
        let runSummary = await runTask.value
        try expectEqual(runSummary.completedItemCount, 1)
        try expectEqual(await harness.observer.startedItemIdentifiers, ["item-1"])
    },
    CoreTestCase(name: "executor: an irreversible item doesn't ask up front, but its Send click still asks") {
        let harness = try TaskExecutorTestHarness(replies: [
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_send", "click", ConversationFixtures.clickInput("e3"))),
            try ConversationFixtures.finishItemTurn(outcome: "completed"),
        ], rootNodes: RoutineRunFixtures.finderRootNodes())
        _ = await harness.run(RoutineRunFixtures.renameChecklist(oldNames: ["a.png"], irreversible: true))
        let confirmationRequests = await harness.confirmationRequester.receivedRequests
        try expectEqual(confirmationRequests.map(\.isActionLevel), [true])
        try expectEqual(confirmationRequests.map(\.riskCategory), [.sendingOrPublishing])
    },
    CoreTestCase(name: "executor: a replayed step flagged under a category that no longer asks runs without asking, and is never retried") {
        for recordedRiskCategory in [SafetyRiskCategory.pressingReturn, .unrecognizedShortcut, .irreversibleItem] {
            var routine = try RoutineRunFixtures.learnedRenameRoutine()
            routine.steps[0].requiresConfirmationEachItem = true
            routine.steps[0].confirmationRiskCategory = recordedRiskCategory
            let harness = try TaskExecutorTestHarness(replies: [], rootNodes: RoutineRunFixtures.finderRootNodes(), routineToReplay: routine)
            let runSummary = await harness.run(RoutineRunFixtures.renameChecklist())
            try expectEqual(runSummary.completedItemCount, 3, recordedRiskCategory.rawValue)
            try expectEqual(await harness.confirmationRequester.receivedRequests, [], recordedRiskCategory.rawValue)
        }
        var failingRoutine = try RoutineRunFixtures.learnedRenameRoutine()
        failingRoutine.steps[0].requiresConfirmationEachItem = true
        failingRoutine.steps[0].confirmationRiskCategory = .pressingReturn
        failingRoutine.completionEvidence = StepExpectation(kind: .textAppears, text: "never shown")
        // The completion check fails, so attempt 1 falls back to the agent, which fails too; a second attempt would redo the flagged step.
        let failingHarness = try TaskExecutorTestHarness(replies: [try ConversationFixtures.finishItemTurn(outcome: "failed")],
                                                        rootNodes: RoutineRunFixtures.finderRootNodes(), routineToReplay: failingRoutine,
                                                        failureDecisions: [.skipItem])
        let failingRunSummary = await failingHarness.run(RoutineRunFixtures.renameChecklist(oldNames: ["a.png"]))
        try expectEqual(await failingHarness.interactionHandler.receivedDecisionRequests.map(\.attemptCount), [1])
        try expectEqual(failingHarness.transport.recordedRequests.count, 1)
        try expectEqual(failingRunSummary.skippedItemCount, 1)
    },
    CoreTestCase(name: "executor: a routine plan confirms each item under its risky step's category, which then covers that step") {
        var routine = try RoutineRunFixtures.learnedRenameRoutine()
        routine.steps[0].requiresConfirmationEachItem = true
        routine.steps[0].confirmationRiskCategory = .sendingOrPublishing
        let routineChecklist = RoutineChecklistFactory.makeChecklist(routine: routine, parameterSets: RoutineRunFixtures.renameChecklist(oldNames: ["a.png", "b.png"]).items.map(\.parameters),
                                                                     targetApplication: fixtureTargetApplication, taskIdentifier: "test-task", now: Date())
        let harness = try TaskExecutorTestHarness(replies: [], rootNodes: RoutineRunFixtures.finderRootNodes(), routineToReplay: routine)
        let runSummary = await harness.run(routineChecklist)
        try expectEqual(runSummary.completedItemCount, 2)
        let confirmationRequests = await harness.confirmationRequester.receivedRequests
        try expectEqual(confirmationRequests.map(\.isActionLevel), [false, false])
        try expectEqual(confirmationRequests.map(\.riskCategory), [.sendingOrPublishing, .sendingOrPublishing])
    },
    CoreTestCase(name: "executor: a routine is learned only from attempt 1; metrics count every attempt's model calls") {
        let harness = try TaskExecutorTestHarness(replies: [try ConversationFixtures.finishItemTurn(outcome: "failed")]
                                                 + (try RoutineRunFixtures.agentRenameTurns(fieldIdentifier: "e11", newName: "shot-01.png")), rootNodes: RoutineRunFixtures.finderRootNodes())
        let runSummary = await harness.run(RoutineRunFixtures.renameChecklist(oldNames: ["a.png"]))
        try expectEqual(runSummary.completedItemCount, 1)
        try expectEqual(harness.taskExecutor.currentRoutine, nil)
        try expectTrue(await harness.interactionHandler.updatedRoutines.isEmpty)
        try expectEqual(harness.metricsAccumulator.currentMetrics.itemsCompletedByAgent, 1)
        try expectEqual(harness.metricsAccumulator.currentMetrics.modelCallsDuringAgentItems, 4)
    },
    CoreTestCase(name: "executor: a skip pressed while paused before an item skips that item without starting it") {
        let harness = try TaskExecutorTestHarness(replies: [], rootNodes: RoutineRunFixtures.finderRootNodes(), routineToReplay: try RoutineRunFixtures.learnedRenameRoutine())
        harness.runControl.requestPause(reason: .requestedByUser)
        harness.runControl.requestSkipCurrentItem()
        let runSummary = await harness.run(RoutineRunFixtures.renameChecklist(oldNames: ["a.png", "b.png"]))
        try expectEqual(runSummary.skippedItemCount, 1)
        try expectEqual(runSummary.completedItemCount, 1)
        try expectEqual(await harness.observer.startedItemIdentifiers, ["item-2"])
        try expectEqual(await harness.observer.finishedItems.map(\.itemIdentifier), ["item-1", "item-2"])
    },
    CoreTestCase(name: "executor: a denied replay step is not retried automatically") {
        var routine = try RoutineRunFixtures.learnedRenameRoutine()
        routine.steps = [RoutineStep(
            stepDescription: "Type", action: .typeText(textTemplate: "{{new_name}}", replaceExistingText: true, pressReturnAfter: false),
            targetLocator: ElementLocator(role: "AXTextField", subrole: "AXSecureTextField", titleTemplate: "Password", descriptionTemplate: nil,
                                          valueTemplate: nil, descendantTextTemplate: nil, placeholder: nil, accessibilityIdentifier: nil,
                                          ancestorsNearestFirst: [], normalizedPositionInWindow: nil, readScope: .focusedWindow),
            expectation: nil, requiresConfirmationEachItem: false)]
        let harness = try TaskExecutorTestHarness(replies: [], rootNodes: makePasswordFieldWindowRootNodes(), routineToReplay: routine, failureDecisions: [.skipItem])
        let runSummary = await harness.run(RoutineRunFixtures.renameChecklist(oldNames: ["a.png"]))
        try expectEqual(runSummary.skippedItemCount, 1)
        try expectEqual(await harness.interactionHandler.receivedDecisionRequests.map(\.attemptCount), [1])
        try expectTrue(harness.actionBackend.performedActions.isEmpty)
        try expectTrue(harness.transport.recordedRequests.isEmpty)
    },
    CoreTestCase(name: "executor: after replay typed, one retry follows, through the agent only, never replaying again") {
        var routine = try RoutineRunFixtures.learnedRenameRoutine()
        routine.completionEvidence = StepExpectation(kind: .textAppears, text: "never shown")
        let failedTurn = try ConversationFixtures.finishItemTurn(outcome: "failed", summary: "still not done")
        let harness = try TaskExecutorTestHarness(replies: [failedTurn, failedTurn], rootNodes: RoutineRunFixtures.finderRootNodes(), routineToReplay: routine, failureDecisions: [.skipItem])
        let runSummary = await harness.run(RoutineRunFixtures.renameChecklist(oldNames: ["a.png"]))
        try expectEqual(runSummary.skippedItemCount, 1)
        try expectEqual(harness.actionBackend.performedActions, [
            .clickElement(elementIdentifier: "e11", clickType: .single),
            .typeText(elementIdentifier: "e11", text: "shot-01.png", replaceExistingText: true, pressReturnAfter: false),
        ])
        try expectEqual(harness.transport.recordedRequests.count, 2)
        let retryInitialText = ConversationFixtures.initialUserText(of: harness.transport.recordedRequests[1])
        try expectTrue(retryInitialText.contains("Attempt 1 of this item failed"), retryInitialText)
        try expectTrue(!retryInitialText.contains("A recorded routine did"), retryInitialText)
        try expectEqual(await harness.interactionHandler.receivedDecisionRequests.map(\.attemptCount), [2])
    },
])
