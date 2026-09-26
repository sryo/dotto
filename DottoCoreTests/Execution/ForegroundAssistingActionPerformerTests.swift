import Foundation

private let clickOnRename = AgentAction.clickElement(elementIdentifier: "e2", clickType: .single)
private let assistContext = ForegroundAssistContext(itemIdentifier: "item-1", itemLabel: "Rename a", itemParameters: [],
                                                    targetApplicationName: "Finder", riskCategoryConfirmedForThisItem: nil)

private struct PerformerFixture {
    let actionBackend = FakeActionBackend(snapshotRootNodes: ConversationFixtures.windowRootNodes())
    let confirmationRequester: ScriptedConfirmationRequester
    let auditLogWriter: AuditLogWriter
    let abortSignal = TaskAbortSignal()

    init(confirmationAnswers: [SafetyConfirmationAnswer] = []) throws {
        confirmationRequester = ScriptedConfirmationRequester(scriptedAnswers: confirmationAnswers)
        auditLogWriter = try ConversationFixtures.makeAuditLogWriter()
    }

    func perform(_ action: AgentAction, context: ForegroundAssistContext = assistContext,
                 grants: inout Set<SafetyRiskCategory>,
                 readinessGate: ForegroundAssistReadinessGating? = nil) async throws -> ForegroundAssistingPerformResult {
        try await ForegroundAssistingActionPerformer.perform(action, actionBackend: actionBackend, confirmationRequester: confirmationRequester,
                                                             auditLogWriter: auditLogWriter, context: context,
                                                             riskCategoriesAllowedForRestOfTask: &grants, abortSignal: abortSignal,
                                                             readinessGate: readinessGate)
    }
}

/// Polls every 10 ms and gives up after 50 ms, so a test waits in vain quickly.
private var quickReadinessContext: ForegroundAssistContext {
    var quickContext = assistContext
    quickContext.targetProcessIdentifier = 42
    quickContext.readinessPolicy.pollIntervalSeconds = 0.01
    quickContext.readinessPolicy.maximumWaitSeconds = 0.05
    return quickContext
}

private let undeliveredClick = ActionBackendError.inputNotDelivered("the click didn't change the window", foregroundAssistMayHelp: true)

let foregroundAssistingActionPerformerTestSuite = CoreTestSuite(name: "ForegroundAssistingActionPerformer", testCases: [
    CoreTestCase(name: "background-only mode refuses an upload before opening a file dialog or asking to assist") {
        let fixture = try PerformerFixture()
        var context = assistContext
        context.focusPolicy = .backgroundOnly
        var grants: Set<SafetyRiskCategory> = []
        let result = try await fixture.perform(.uploadFiles(elementIdentifier: "e2", filePaths: ["/Users/me/a.pdf"]),
                                               context: context, grants: &grants)
        try expectEqual(result, .blockedByBackgroundOnly)
        try expectEqual(fixture.actionBackend.performedActions, [])
        try expectEqual(fixture.actionBackend.actionsPerformedWithForegroundAssist, [])
        try expectEqual(await fixture.confirmationRequester.receivedRequests, [])
    },
    CoreTestCase(name: "background-only mode reports undelivered input without asking to raise the target") {
        let fixture = try PerformerFixture()
        fixture.actionBackend.errorForNextPerform = undeliveredClick
        var context = assistContext
        context.focusPolicy = .backgroundOnly
        var grants: Set<SafetyRiskCategory> = []
        let result = try await fixture.perform(clickOnRename, context: context, grants: &grants)
        try expectEqual(result, .blockedByBackgroundOnly)
        try expectEqual(fixture.actionBackend.actionsPerformedWithForegroundAssist, [])
        try expectEqual(await fixture.confirmationRequester.receivedRequests, [])
    },
    CoreTestCase(name: "a background success never prompts") {
        let fixture = try PerformerFixture()
        var grants: Set<SafetyRiskCategory> = []
        let result = try await fixture.perform(clickOnRename, grants: &grants)
        guard case .performed(let actionOutcome) = result else { throw CoreTestFailure(description: "expected performed, got \(result)") }
        try expectEqual(actionOutcome.usedForegroundAssist, false)
        try expectEqual(await fixture.confirmationRequester.receivedRequests.count, 0)
        try expectEqual(fixture.actionBackend.actionsPerformedWithForegroundAssist, [])
    },
    CoreTestCase(name: "undelivered input asks to bring the app forward, and allowOnce retries in front once") {
        let fixture = try PerformerFixture(confirmationAnswers: [.allowOnce])
        fixture.actionBackend.errorForNextPerform = undeliveredClick
        var grants: Set<SafetyRiskCategory> = []
        let result = try await fixture.perform(clickOnRename, grants: &grants)
        let receivedRequests = await fixture.confirmationRequester.receivedRequests
        try expectEqual(receivedRequests.map(\.riskCategory), [.bringingAppForward])
        try expectTrue(receivedRequests[0].reason.contains("Dotto's click didn't reach Finder"), receivedRequests[0].reason)
        try expectEqual(receivedRequests[0].isActionLevel, true)
        try expectEqual(fixture.actionBackend.actionsPerformedWithForegroundAssist, [clickOnRename])
        guard case .performed(let actionOutcome) = result else { throw CoreTestFailure(description: "expected performed, got \(result)") }
        try expectEqual(actionOutcome.usedForegroundAssist, true)
        try expectEqual(grants, [])
    },
    CoreTestCase(name: "the rest-of-task grant stops the second prompt") {
        let fixture = try PerformerFixture(confirmationAnswers: [.allowForAllRemainingItems])
        var grants: Set<SafetyRiskCategory> = []
        fixture.actionBackend.errorForNextPerform = undeliveredClick
        _ = try await fixture.perform(clickOnRename, grants: &grants)
        try expectEqual(grants, [.bringingAppForward])
        fixture.actionBackend.errorForNextPerform = undeliveredClick
        _ = try await fixture.perform(clickOnRename, grants: &grants)
        try expectEqual(await fixture.confirmationRequester.receivedRequests.count, 1)
        try expectEqual(fixture.actionBackend.actionsPerformedWithForegroundAssist.count, 2)
    },
    CoreTestCase(name: "skip declines the assist and stop aborts the task") {
        let skippingFixture = try PerformerFixture(confirmationAnswers: [.skipItem])
        skippingFixture.actionBackend.errorForNextPerform = undeliveredClick
        var grants: Set<SafetyRiskCategory> = []
        try expectEqual(try await skippingFixture.perform(clickOnRename, grants: &grants), .userDeclinedForegroundAssist)
        try expectEqual(skippingFixture.actionBackend.actionsPerformedWithForegroundAssist, [])
        let stoppingFixture = try PerformerFixture(confirmationAnswers: [.stopTask])
        stoppingFixture.actionBackend.errorForNextPerform = undeliveredClick
        try expectEqual(try await stoppingFixture.perform(clickOnRename, grants: &grants), .userStoppedTask)
        try expectTrue(stoppingFixture.abortSignal.isAborted)
        try expectEqual(stoppingFixture.actionBackend.actionsPerformedWithForegroundAssist, [])
    },
    CoreTestCase(name: "undelivered input the assist can't help, and any other error, is rethrown unchanged") {
        for backendError in [ActionBackendError.inputNotDelivered("the dialog didn't open", foregroundAssistMayHelp: false),
                             .staleOrUnknownElementIdentifier("e9")] {
            let fixture = try PerformerFixture()
            fixture.actionBackend.errorForNextPerform = backendError
            var grants: Set<SafetyRiskCategory> = []
            do {
                _ = try await fixture.perform(clickOnRename, grants: &grants)
                throw CoreTestFailure(description: "expected \(backendError) to be rethrown")
            } catch let thrownError as ActionBackendError {
                try expectEqual(thrownError, backendError)
            }
            try expectEqual(await fixture.confirmationRequester.receivedRequests.count, 0)
        }
    },
    CoreTestCase(name: "an upload skips the background attempt and never asks to bring the app forward") {
        let fixture = try PerformerFixture()
        let uploadAction = AgentAction.uploadFiles(elementIdentifier: "e2", filePaths: ["/Users/me/a.pdf"])
        var grants: Set<SafetyRiskCategory> = []
        let result = try await fixture.perform(uploadAction, grants: &grants)
        try expectEqual(fixture.actionBackend.actionsPerformedWithForegroundAssist, [uploadAction])
        try expectEqual(fixture.actionBackend.performedActions, [uploadAction], "no background attempt before the assist")
        try expectEqual(await fixture.confirmationRequester.receivedRequests.count, 0)
        guard case .performed(let actionOutcome) = result else { throw CoreTestFailure(description: "expected performed") }
        try expectEqual(actionOutcome.usedForegroundAssist, true)
    },
    CoreTestCase(name: "an item confirmed as bringing the app forward needs no second prompt") {
        let fixture = try PerformerFixture()
        fixture.actionBackend.errorForNextPerform = undeliveredClick
        var confirmedContext = assistContext
        confirmedContext.riskCategoryConfirmedForThisItem = .bringingAppForward
        var grants: Set<SafetyRiskCategory> = []
        _ = try await fixture.perform(clickOnRename, context: confirmedContext, grants: &grants)
        try expectEqual(await fixture.confirmationRequester.receivedRequests.count, 0)
        try expectEqual(fixture.actionBackend.actionsPerformedWithForegroundAssist, [clickOnRename])
    },
    CoreTestCase(name: "the audit log records the assist by summary, never typed text") {
        let fixture = try PerformerFixture(confirmationAnswers: [.allowOnce])
        fixture.actionBackend.errorForNextPerform = ActionBackendError.inputNotDelivered("no change", foregroundAssistMayHelp: true)
        var grants: Set<SafetyRiskCategory> = []
        _ = try await fixture.perform(.typeText(elementIdentifier: "e3", text: "my secret note", replaceExistingText: false,
                                                pressReturnAfter: false), grants: &grants)
        let logText = try String(contentsOf: fixture.auditLogWriter.logFileURL, encoding: .utf8)
        try expectTrue(logText.contains("\"foregroundAssist\"") && logText.contains("assist finished"), logText)
        try expectTrue(!logText.contains("my secret note"), logText)
    },
    CoreTestCase(name: "under a rest-of-task grant the assist still waits for the user to pause, then counts down") {
        let fixture = try PerformerFixture()
        fixture.actionBackend.errorForNextPerform = undeliveredClick
        let readinessGate = ScriptedForegroundAssistReadinessGate(scriptedInputs: [
            ScriptedForegroundAssistReadinessGate.typingInputs, ScriptedForegroundAssistReadinessGate.typingInputs,
            ScriptedForegroundAssistReadinessGate.idleInputs])
        var grants: Set<SafetyRiskCategory> = [.bringingAppForward]
        let result = try await fixture.perform(clickOnRename, context: quickReadinessContext, grants: &grants, readinessGate: readinessGate)
        guard case .performed = result else { throw CoreTestFailure(description: "expected performed, got \(result)") }
        try expectEqual(await readinessGate.recordedCalls, ["inputs", "waiting", "inputs", "inputs", "countdown", "inputs", "ended"])
        try expectEqual(await fixture.confirmationRequester.receivedRequests.count, 0)
        try expectEqual(fixture.actionBackend.actionsPerformedWithForegroundAssist, [clickOnRename])
    },
    CoreTestCase(name: "waiting in vain asks again even under a grant; skipping declines without bringing the app forward") {
        let fixture = try PerformerFixture(confirmationAnswers: [.skipItem])
        fixture.actionBackend.errorForNextPerform = undeliveredClick
        let secureInputElsewhere = ForegroundAssistReadinessInputs(secondsSinceLastRealUserInput: 10, secureEventInputIsEnabled: true,
                                                                   secureEventInputProcessIdentifier: 7)
        let readinessGate = ScriptedForegroundAssistReadinessGate(scriptedInputs: [secureInputElsewhere])
        var grants: Set<SafetyRiskCategory> = [.bringingAppForward]
        let result = try await fixture.perform(clickOnRename, context: quickReadinessContext, grants: &grants, readinessGate: readinessGate)
        try expectEqual(result, .userDeclinedForegroundAssist)
        let receivedRequests = await fixture.confirmationRequester.receivedRequests
        try expectEqual(receivedRequests.map(\.riskCategory), [.bringingAppForward])
        try expectTrue(receivedRequests[0].reason.contains("a password field is active in another app"), receivedRequests[0].reason)
        try expectEqual(fixture.actionBackend.actionsPerformedWithForegroundAssist, [])
        try expectEqual(await readinessGate.recordedCalls.last, "ended")
    },
    CoreTestCase(name: "Cancel during the countdown declines, and input during it restarts the wait") {
        let cancellingFixture = try PerformerFixture()
        cancellingFixture.actionBackend.errorForNextPerform = undeliveredClick
        let cancellingGate = ScriptedForegroundAssistReadinessGate(scriptedInputs: [ScriptedForegroundAssistReadinessGate.idleInputs],
                                                                   countdownResults: [false])
        var grants: Set<SafetyRiskCategory> = [.bringingAppForward]
        try expectEqual(try await cancellingFixture.perform(clickOnRename, context: quickReadinessContext, grants: &grants,
                                                            readinessGate: cancellingGate), .userDeclinedForegroundAssist)
        try expectEqual(cancellingFixture.actionBackend.actionsPerformedWithForegroundAssist, [])

        let interruptedFixture = try PerformerFixture()
        interruptedFixture.actionBackend.errorForNextPerform = undeliveredClick
        let interruptedGate = ScriptedForegroundAssistReadinessGate(scriptedInputs: [
            ScriptedForegroundAssistReadinessGate.idleInputs, ScriptedForegroundAssistReadinessGate.typingInputs,
            ScriptedForegroundAssistReadinessGate.idleInputs])
        _ = try await interruptedFixture.perform(clickOnRename, context: quickReadinessContext, grants: &grants, readinessGate: interruptedGate)
        try expectEqual(await interruptedGate.recordedCalls, ["inputs", "countdown", "inputs", "inputs", "countdown", "inputs", "ended"])
        try expectEqual(interruptedFixture.actionBackend.actionsPerformedWithForegroundAssist, [clickOnRename])
    },
    CoreTestCase(name: "the turn is taken before the readiness wait and given back after the assist, even when declined") {
        let fixture = try PerformerFixture()
        fixture.actionBackend.errorForNextPerform = undeliveredClick
        let readinessGate = ScriptedForegroundAssistReadinessGate(scriptedInputs: [ScriptedForegroundAssistReadinessGate.idleInputs])
        var grants: Set<SafetyRiskCategory> = [.bringingAppForward]
        _ = try await fixture.perform(clickOnRename, context: quickReadinessContext, grants: &grants, readinessGate: readinessGate)
        try expectEqual(await readinessGate.turnCalls, ["turn", "turnEnded"])
        try expectEqual(await readinessGate.inputReadsBeforeTurn, 0, "readiness is only read once the turn is held")
        try expectEqual(fixture.actionBackend.actionsPerformedWithForegroundAssist, [clickOnRename])

        let decliningFixture = try PerformerFixture()
        decliningFixture.actionBackend.errorForNextPerform = undeliveredClick
        let cancellingGate = ScriptedForegroundAssistReadinessGate(scriptedInputs: [ScriptedForegroundAssistReadinessGate.idleInputs],
                                                                   countdownResults: [false])
        _ = try await decliningFixture.perform(clickOnRename, context: quickReadinessContext, grants: &grants, readinessGate: cancellingGate)
        try expectEqual(await cancellingGate.turnCalls, ["turn", "turnEnded"])
    },
    CoreTestCase(name: "a task stopped while waiting for its turn never brings its app forward") {
        let fixture = try PerformerFixture()
        fixture.actionBackend.errorForNextPerform = undeliveredClick
        let readinessGate = ScriptedForegroundAssistReadinessGate(scriptedInputs: [ScriptedForegroundAssistReadinessGate.idleInputs])
        await MainActor.run { readinessGate.grantsTurn = false }
        var grants: Set<SafetyRiskCategory> = [.bringingAppForward]
        let result = try await fixture.perform(clickOnRename, context: quickReadinessContext, grants: &grants, readinessGate: readinessGate)
        try expectEqual(result, .userStoppedTask)
        try expectEqual(fixture.actionBackend.actionsPerformedWithForegroundAssist, [])
        try expectEqual(await readinessGate.recordedCalls, [])
    },
    CoreTestCase(name: "uploads wait for the user to pause too") {
        let fixture = try PerformerFixture()
        let uploadAction = AgentAction.uploadFiles(elementIdentifier: "e2", filePaths: ["/Users/me/a.pdf"])
        let readinessGate = ScriptedForegroundAssistReadinessGate(scriptedInputs: [ScriptedForegroundAssistReadinessGate.idleInputs],
                                                                  countdownResults: [false])
        var grants: Set<SafetyRiskCategory> = []
        try expectEqual(try await fixture.perform(uploadAction, context: quickReadinessContext, grants: &grants,
                                                  readinessGate: readinessGate), .userDeclinedForegroundAssist)
        try expectEqual(fixture.actionBackend.performedActions, [])
    },
])
