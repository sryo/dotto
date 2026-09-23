import Foundation

private struct DirectRouteExecutorHarness {
    let fileSystem: InMemoryFileSystem
    let scriptRunner: ScriptedScriptRunner
    let shortcutRunner: ScriptedShortcutRunner
    let journalStore: FileOperationJournalStore
    let confirmationRequester: ScriptedConfirmationRequester
    let observer: RecordingExecutionObserver
    let auditLogWriter: AuditLogWriter

    init(fileSystem: InMemoryFileSystem = makeShotsFileSystem(), scriptRunner: ScriptedScriptRunner = ScriptedScriptRunner(),
         shortcutRunner: ScriptedShortcutRunner = ScriptedShortcutRunner(), confirmationAnswers: [SafetyConfirmationAnswer] = []) throws {
        self.fileSystem = fileSystem
        self.scriptRunner = scriptRunner
        self.shortcutRunner = shortcutRunner
        journalStore = try makeJournalStore()
        confirmationRequester = ScriptedConfirmationRequester(scriptedAnswers: confirmationAnswers)
        observer = RecordingExecutionObserver()
        auditLogWriter = try ConversationFixtures.makeAuditLogWriter()
    }

    func run(_ directRoutePlan: DirectRoutePlan, abortSignal: TaskAbortSignal = TaskAbortSignal(),
             focusPolicy: TaskFocusPolicy = .allowApprovedAssist) async -> (summary: DirectRouteRunSummary, checklist: Checklist) {
        let checklist = Checklist.fromDirectRoutePlan(directRoutePlan, title: "Direct task", originalCommand: "do it",
                                                      targetApplication: fixtureTargetApplication, taskIdentifier: "task-direct",
                                                      createdAt: Date(timeIntervalSince1970: 1_790_000_000))
        let directRouteExecutor = DirectRouteExecutor(
            dependencies: DirectRouteExecutionDependencies(fileSystem: fileSystem, fileSystemReader: fileSystem, journalStore: journalStore,
                                                           scriptRunner: scriptRunner, shortcutRunner: shortcutRunner,
                                                           homeDirectoryPath: directRouteTestHomeDirectoryPath),
            confirmationRequester: confirmationRequester, observer: observer, auditLogWriter: auditLogWriter,
            taskResourceBudget: TaskResourceBudget(safetyLimits: .standard), runControl: TaskRunControl(pollIntervalNanoseconds: 1_000_000),
            focusPolicy: focusPolicy)
        return (await directRouteExecutor.run(approvedChecklist: checklist, abortSignal: abortSignal), checklist)
    }
}

private let sortShotsPlan = DirectRoutePlan.fileOperations(makeFileOperationsPlan(sortShotsOperations, groups: [
    FileOperationGroup(groupIdentifier: "folders", title: "Create 1 folder"),
    FileOperationGroup(groupIdentifier: "moves", title: "Move 2 screenshots"),
]))

private let mailboxScript = "tell application \"Mail\" to make new mailbox with properties {name:\"Receipts\"}"

let directRouteExecutorTestSuite = CoreTestSuite(name: "DirectRouteExecutor", testCases: [
    CoreTestCase(name: "background-only mode runs file operations but refuses scripts and Shortcuts") {
        let fileHarness = try DirectRouteExecutorHarness()
        let (fileSummary, _) = await fileHarness.run(sortShotsPlan, focusPolicy: .backgroundOnly)
        try expectEqual(fileSummary.taskRunSummary.completedItemCount, 2)

        let scriptHarness = try DirectRouteExecutorHarness()
        let (scriptSummary, _) = await scriptHarness.run(.script(makeScriptPlan(source: mailboxScript)), focusPolicy: .backgroundOnly)
        try expectEqual(scriptSummary.taskRunSummary.failedItemCount, 1)
        try expectEqual(scriptHarness.scriptRunner.ranScriptPlans, [])
        try expectTrue(scriptHarness.scriptRunner.automationPermissionRequests.isEmpty)

        let shortcutHarness = try DirectRouteExecutorHarness()
        let shortcut = ShortcutPlan(shortcutName: "Resize for web", input: .none, oneSentenceSummary: "Resizes.", timeoutSeconds: 30)
        let (shortcutSummary, _) = await shortcutHarness.run(.shortcut(shortcut), focusPolicy: .backgroundOnly)
        try expectEqual(shortcutSummary.taskRunSummary.failedItemCount, 1)
        try expectEqual(shortcutHarness.shortcutRunner.ranShortcutPlans, [])
        try expectEqual(await shortcutHarness.confirmationRequester.receivedRequests, [])
    },
    CoreTestCase(name: "file operations run group by group with progress, and the run ends succeeded") {
        let harness = try DirectRouteExecutorHarness()
        let (summary, _) = await harness.run(sortShotsPlan)
        try expectEqual(summary.taskRunSummary.stopReason, .allItemsProcessed)
        try expectEqual(summary.taskRunSummary.completedItemCount, 2)
        try expectEqual(summary.report.completedOperationCount, 3)
        try expectEqual(summary.report.undoJournalIdentifier, "task-direct")
        let observer = harness.observer
        try expectEqual(await observer.startedItemIdentifiers, ["item-1", "item-2"])
        try expectEqual(await observer.finishedItems.map(\.itemIdentifier), ["item-1", "item-2"])
        let cursorEvents = await observer.reportedCursorActivityEvents
        try expectEqual(cursorEvents.first, .runStarted(targetWindow: nil))
        try expectEqual(cursorEvents.last, .runFinished(succeeded: true))
        try expectTrue(cursorEvents.contains(.directOperationProgressed(completedCount: 3, totalCount: 3, operationDescription: "Moving IMG_2")),
                       "\(cursorEvents)")
        try expectEqual(await harness.confirmationRequester.receivedRequests, [])
    },
    CoreTestCase(name: "a plan that no longer matches the folder changes nothing and fails every item") {
        let harness = try DirectRouteExecutorHarness()
        _ = try harness.fileSystem.moveItemToTrash(atCanonicalPath: "/Users/me/Desktop/Shots/IMG_1.png")
        let mutationCountBeforeRun = harness.fileSystem.performedMutations.count
        let (summary, _) = await harness.run(sortShotsPlan)
        try expectEqual(harness.fileSystem.performedMutations.count, mutationCountBeforeRun)
        try expectEqual(summary.taskRunSummary.failedItemCount, 2)
        try expectEqual(summary.report.completedOperationCount, 0)
        try expectTrue(summary.report.failures.first?.userFacingReason.hasPrefix(DirectRouteExecutor.folderChangedSincePlanningPrefix) == true,
                       "\(summary.report.failures)")
        try expectEqual(await harness.observer.reportedCursorActivityEvents.last, .runFinished(succeeded: false))
    },
    CoreTestCase(name: "declining the Trash confirmation trashes nothing and skips every item") {
        let harness = try DirectRouteExecutorHarness(confirmationAnswers: [.skipItem])
        let trashPlan = DirectRoutePlan.fileOperations(makeFileOperationsPlan([
            makePlannedOperation(.moveToTrash, from: "/Users/me/Desktop/Shots/IMG_1.png"),
        ]))
        let (summary, _) = await harness.run(trashPlan)
        try expectEqual(harness.fileSystem.performedMutations, [])
        try expectEqual(summary.taskRunSummary.skippedItemCount, 1)
        let confirmationRequests = await harness.confirmationRequester.receivedRequests
        try expectEqual(confirmationRequests.map(\.riskCategory), [.deleting])
    },
    CoreTestCase(name: "a script whose app isn't running fails without launching it or asking for Automation") {
        let harness = try DirectRouteExecutorHarness(scriptRunner: ScriptedScriptRunner(runningBundleIdentifiers: []),
                                                     confirmationAnswers: [.allowOnce])
        let (summary, checklist) = await harness.run(.script(makeScriptPlan(source: mailboxScript, modifiesData: true)))
        try expectEqual(summary.taskRunSummary.failedItemCount, 1)
        try expectEqual(harness.scriptRunner.ranScriptPlans, [])
        try expectTrue(harness.scriptRunner.automationPermissionRequests.isEmpty)
        try expectEqual(checklist.items.first?.label, "Run script in Mail")
        try expectEqual(await harness.observer.finishedItems.first?.runStatus, .failed)
    },
    CoreTestCase(name: "Automation denied fails with a friendly message; granted runs once without asking again after Run") {
        let deniedHarness = try DirectRouteExecutorHarness(scriptRunner: ScriptedScriptRunner(automationPermissionState: .denied),
                                                           confirmationAnswers: [.allowOnce])
        let (deniedSummary, _) = await deniedHarness.run(.script(makeScriptPlan(source: mailboxScript, modifiesData: true)))
        try expectEqual(deniedSummary.report.failures.first?.userFacingReason, DirectRouteExecutor.automationDeniedSummary(applicationName: "Mail"))
        try expectEqual(deniedHarness.scriptRunner.ranScriptPlans, [])

        let grantedHarness = try DirectRouteExecutorHarness()
        let (grantedSummary, _) = await grantedHarness.run(.script(makeScriptPlan(source: mailboxScript, modifiesData: true, timeoutSeconds: 9_999)))
        try expectEqual(grantedSummary.taskRunSummary.completedItemCount, 1)
        try expectEqual(grantedSummary.report.outputText, "Created 4 mailboxes")
        try expectEqual(grantedHarness.scriptRunner.ranScriptPlans.first?.timeoutSeconds, 300)
        try expectEqual(grantedHarness.scriptRunner.automationPermissionRequests.first?.mayPromptUser, true)
        // A data-changing script doesn't ask again: the user read it verbatim and clicked Run.
        try expectEqual(await grantedHarness.confirmationRequester.receivedRequests.map(\.riskCategory), [])
        let logText = try String(contentsOf: grantedHarness.auditLogWriter.logFileURL, encoding: .utf8)
        try expectTrue(logText.contains("scriptRun") && logText.contains("source_sha256") && !logText.contains("Receipts"), logText)
    },
    CoreTestCase(name: "a script that deletes asks as deleting, and declining it runs nothing") {
        let harness = try DirectRouteExecutorHarness(confirmationAnswers: [.skipItem])
        let deletingScript = "tell application \"Mail\" to delete mailbox \"Receipts\""
        let (summary, _) = await harness.run(.script(makeScriptPlan(source: deletingScript, modifiesData: true)))
        try expectEqual(await harness.confirmationRequester.receivedRequests.map(\.riskCategory), [.deleting])
        try expectEqual(harness.scriptRunner.ranScriptPlans, [])
        try expectEqual(summary.taskRunSummary.skippedItemCount, 1)
    },
    CoreTestCase(name: "a script with a denied construct never runs") {
        let harness = try DirectRouteExecutorHarness()
        let (summary, _) = await harness.run(.script(makeScriptPlan(source: "tell application \"Mail\" to do shell script \"ls\"")))
        try expectEqual(summary.taskRunSummary.failedItemCount, 1)
        try expectEqual(harness.scriptRunner.ranScriptPlans, [])
    },
    CoreTestCase(name: "a timeout fails the item; a stopped script ends the task as user-aborted") {
        let timedOutHarness = try DirectRouteExecutorHarness(scriptRunner: ScriptedScriptRunner(scriptedOutput: ScriptRunOutput(
            exitStatus: 15, standardOutputText: "", standardErrorText: "", timedOut: true, wasStopped: false)))
        let (timedOutSummary, _) = await timedOutHarness.run(.script(makeScriptPlan(source: "tell application \"Mail\" to count mailboxes")))
        try expectEqual(timedOutSummary.taskRunSummary.failedItemCount, 1)
        try expectEqual(timedOutSummary.taskRunSummary.stopReason, .allItemsProcessed)

        let stoppedHarness = try DirectRouteExecutorHarness(scriptRunner: ScriptedScriptRunner(scriptedOutput: ScriptRunOutput(
            exitStatus: 15, standardOutputText: "", standardErrorText: "", timedOut: false, wasStopped: true)))
        let (stoppedSummary, _) = await stoppedHarness.run(.script(makeScriptPlan(source: "tell application \"Mail\" to count mailboxes")))
        try expectEqual(stoppedSummary.taskRunSummary.stopReason, .userAborted)
        try expectEqual(stoppedSummary.taskRunSummary.skippedItemCount, 1)
    },
    CoreTestCase(name: "a shortcut asks every run, even after a rest-of-task answer, and runs by its exact listed name") {
        let harness = try DirectRouteExecutorHarness(confirmationAnswers: [.allowForAllRemainingItems])
        let shortcutPlan = ShortcutPlan(shortcutName: "Resize for web", input: .none, oneSentenceSummary: "Resizes.", timeoutSeconds: 30)
        let (summary, _) = await harness.run(.shortcut(shortcutPlan))
        try expectEqual(summary.taskRunSummary.completedItemCount, 1)
        try expectEqual(harness.shortcutRunner.ranShortcutPlans.map(\.shortcutName), ["Resize for web"])
        try expectEqual(await harness.confirmationRequester.receivedRequests.map(\.riskCategory), [.runningShortcut])

        let unlistedHarness = try DirectRouteExecutorHarness(shortcutRunner: ScriptedShortcutRunner(listedShortcutNames: ["Other"]))
        let (unlistedSummary, _) = await unlistedHarness.run(.shortcut(shortcutPlan))
        try expectEqual(unlistedSummary.taskRunSummary.failedItemCount, 1)
        try expectEqual(unlistedHarness.shortcutRunner.ranShortcutPlans, [])
        try expectEqual(await unlistedHarness.confirmationRequester.receivedRequests, [])
    },
    CoreTestCase(name: "Automation not yet asked or unknown still runs the script; macOS answers when it runs") {
        for automationPermissionState in [AutomationPermissionState.notYetAsked, .unknown] {
            let harness = try DirectRouteExecutorHarness(scriptRunner: ScriptedScriptRunner(automationPermissionState: automationPermissionState),
                                                         confirmationAnswers: [.allowOnce])
            let (summary, _) = await harness.run(.script(makeScriptPlan(source: mailboxScript, modifiesData: true)))
            try expectEqual(summary.taskRunSummary.completedItemCount, 1, "\(automationPermissionState)")
            try expectEqual(harness.scriptRunner.ranScriptPlans.count, 1)
        }
        try expectEqual(DirectRouteExecutor.scriptFailureSummary(standardErrorText: "execution error: Not authorized to send Apple events to Mail. (-1743)",
                                                                 applicationName: "Mail"),
                        "Allow Dotto to control Mail in System Settings ▸ Privacy & Security ▸ Automation, then run the task again.")
    },
    CoreTestCase(name: "a stopped shortcut says it may keep running in Shortcuts") {
        let harness = try DirectRouteExecutorHarness(shortcutRunner: ScriptedShortcutRunner(scriptedOutput: ShortcutRunOutput(
            exitStatus: 15, outputText: "", standardErrorText: "", timedOut: false, wasStopped: true)), confirmationAnswers: [.allowOnce])
        let (summary, _) = await harness.run(.shortcut(ShortcutPlan(shortcutName: "Resize for web", input: .none,
                                                                    oneSentenceSummary: "Resizes.", timeoutSeconds: 30)))
        try expectEqual(summary.taskRunSummary.stopReason, .userAborted)
        let logText = try String(contentsOf: harness.auditLogWriter.logFileURL, encoding: .utf8)
        try expectTrue(logText.contains("it may keep running in the Shortcuts app"), logText)
    },
    CoreTestCase(name: "the run-time re-check keeps operation ids, so the preview's name adjustments still match") {
        let harness = try DirectRouteExecutorHarness(fileSystem: makeShotsFileSystem().addFolder("/Users/me/Desktop/Shots/2026-09"))
        var approvedPlan = makeFileOperationsPlan(sortShotsOperations)
        approvedPlan.collisionAdjustments = [FileOperationCollisionAdjustment(
            operationIdentifier: "op-3", requestedDestinationPath: "/Users/me/Desktop/Shots/2026-09/IMG_2.png",
            adjustedDestinationPath: "/Users/me/Desktop/Shots/2026-09/IMG_2 2.png")]
        approvedPlan.operations[2].destinationPath = "/Users/me/Desktop/Shots/2026-09/IMG_2 2.png"
        let (summary, _) = await harness.run(.fileOperations(approvedPlan))
        try expectEqual(summary.report.completedOperationCount, 2)
        let journalEntries = try harness.journalStore.loadJournal("task-direct").entries
        try expectEqual(journalEntries.map(\.operationIdentifier), ["op-2", "op-3"], "the folder that already exists drops out without renumbering")
        try expectEqual(DirectRouteExecutor.combinedCollisionAdjustments(
            approvedAdjustments: approvedPlan.collisionAdjustments,
            runTimeAdjustments: [FileOperationCollisionAdjustment(operationIdentifier: "op-3",
                                                                  requestedDestinationPath: "/Users/me/Desktop/Shots/2026-09/IMG_2 2.png",
                                                                  adjustedDestinationPath: "/Users/me/Desktop/Shots/2026-09/IMG_2 3.png")]),
                        [FileOperationCollisionAdjustment(operationIdentifier: "op-3",
                                                          requestedDestinationPath: "/Users/me/Desktop/Shots/2026-09/IMG_2.png",
                                                          adjustedDestinationPath: "/Users/me/Desktop/Shots/2026-09/IMG_2 3.png")])
    },
    CoreTestCase(name: "Stop at the confirmation ends the task before anything runs") {
        let harness = try DirectRouteExecutorHarness(confirmationAnswers: [.stopTask])
        let (summary, _) = await harness.run(.shortcut(ShortcutPlan(shortcutName: "Resize for web", input: .none,
                                                                    oneSentenceSummary: "Resizes.", timeoutSeconds: 30)))
        try expectEqual(summary.taskRunSummary.stopReason, .userAborted)
        try expectEqual(harness.shortcutRunner.ranShortcutPlans, [])
        try expectEqual(await harness.observer.reportedCursorActivityEvents.last, .runFinished(succeeded: false))
    },
])
