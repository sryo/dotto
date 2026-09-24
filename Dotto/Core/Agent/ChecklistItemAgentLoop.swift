import Foundation

/// Drives one checklist item through a fresh Sonnet conversation: executes the model's tool calls
/// against the ActionBackend, gates every action through SafetyGate, and maps the ending to a run status.
final class ChecklistItemAgentLoop {
    static let finishItemNudgeText = "Call finish_item to report this item's outcome."
    static let skippedAfterEarlierFailureText = "Skipped because an earlier call in this turn failed."
    static let skippedAfterFinishItemText = "Skipped because finish_item was already called in this turn."
    static let actionLimitReachedText = "Action limit reached; call finish_item."
    static let userDeclinedActionText = "The user declined this action. Call finish_item with outcome needs_user."
    static let backgroundOnlyBlockedText = "This action needs the target app in front. The task is set to keep it in the background, so the action was not run."
    static let userStoppedTaskText = "The user stopped the task."
    static let userSkippedItemText = "The user skipped this item."
    static let pausedBeforeActionText = "The task was paused before this action ran and the user may have changed the UI. Check the fresh outline below and repeat the action if it is still needed."
    static let evidenceRequiredText = "For completed, evidence must name a check that proves the item is done (not none)."
    /// First line of a successful action's result. The backend's report follows inside <untrusted_ui>, because it
    /// quotes element names and page text.
    static let actionSucceededText = "ok: the action ran. What the app or page reported:"

    // Tests set these to zero; the defaults give the target app time to redraw before re-reading it.
    var postActionSettleDelayNanoseconds: UInt64 = 350_000_000
    var waitForPollIntervalNanoseconds: UInt64 = 500_000_000
    var expectationTimeoutSeconds = StepExpectation.defaultTimeoutSeconds

    private let transport: ClaudeTransport
    private let actionBackend: ActionBackend
    private let confirmationRequester: UserConfirmationRequesting
    private let observer: TaskExecutionObserving
    private let auditLogWriter: AuditLogWriter
    private let safetyLimits: SafetyLimits

    init(transport: ClaudeTransport, actionBackend: ActionBackend,
         confirmationRequester: UserConfirmationRequesting, observer: TaskExecutionObserving,
         auditLogWriter: AuditLogWriter, safetyLimits: SafetyLimits = .standard) {
        self.transport = transport
        self.actionBackend = actionBackend
        self.confirmationRequester = confirmationRequester
        self.observer = observer
        self.auditLogWriter = auditLogWriter
        self.safetyLimits = safetyLimits
    }

    private enum ForcedItemEnd { case actionLimitExceeded, userDeclinedAction, userStoppedTask, userSkippedItem, stalledWithoutVisibleChange, blockedByBackgroundOnly }

    private final class ItemRunState {
        var latestSnapshot: AccessibilityTreeSnapshot?
        var actionsPerformed = 0
        var riskCategoriesAllowedForRestOfTask: Set<SafetyRiskCategory>
        var reportedOutcome: (outcome: ChecklistItemOutcome, summary: String)?
        var hasReceivedActionLimitError = false
        var forcedItemEnd: ForcedItemEnd?
        var recordedSteps: [RecordedAgentStep] = []
        var verifiedCompletionEvidence: StepExpectation?
        var performedUserConfirmedAction = false
        var performedSideEffectingAction = false
        var finishItemVerificationRejections = 0
        var stallPolicy = ChecklistItemStallPolicy()
        init(riskCategoriesAllowedForRestOfTask: Set<SafetyRiskCategory>) {
            self.riskCategoriesAllowedForRestOfTask = riskCategoriesAllowedForRestOfTask
        }
    }

    private struct PendingToolResult {
        var toolUseIdentifier: String
        var text: String
        var imageBlocks: [ClaudeImageBlock] = []
        var isError: Bool
        var wasSuccessfulAction = false
        var stepProgress: AgentStepProgress = .neutral

        static func error(_ toolUseIdentifier: String, _ errorText: String) -> PendingToolResult {
            PendingToolResult(toolUseIdentifier: toolUseIdentifier, text: errorText, isError: true)
        }

        static func success(_ toolUseIdentifier: String, _ resultText: String) -> PendingToolResult {
            PendingToolResult(toolUseIdentifier: toolUseIdentifier, text: resultText, isError: false)
        }

        var contentBlock: ClaudeContentBlock {
            .toolResult(ClaudeToolResultBlock(toolUseIdentifier: toolUseIdentifier,
                                              content: [.text(text)] + imageBlocks.map { .image($0) },
                                              isError: isError))
        }
    }

    func runItem(_ context: ChecklistItemExecutionContext, abortSignal: TaskAbortSignal) async throws -> ChecklistItemExecutionResult {
        let runState = ItemRunState(riskCategoriesAllowedForRestOfTask: context.riskCategoriesAllowedForRestOfTask)
        let initialOutline = try await focusedWindowOutline(runState: runState, abortSignal: abortSignal)
        let initialUserText = PromptLibrary.executorInitialUserText(
            checklist: context.checklist, item: context.item,
            itemPositionAmongIncludedItems: context.itemPositionAmongIncludedItems,
            includedItemCount: context.includedItemCount,
            previousItemResultSummary: context.previousItemResultSummary,
            currentOutline: initialOutline, additionalContext: context.additionalContextForModel,
            focusPolicy: context.focusPolicy)

        let conversationRunner = ClaudeToolConversationRunner(
            transport: transport,
            makeRequest: PromptLibrary.makeExecutorRequest,
            nudgeTextWhenRequiredToolMissing: Self.finishItemNudgeText,
            maximumModelTurns: safetyLimits.maximumModelTurnsPerItem,
            auditLogWriter: auditLogWriter,
            itemIdentifierForAudit: context.item.itemIdentifier,
            maximumRetainedScreenshots: safetyLimits.maximumRetainedScreenshotsPerConversation,
            taskResourceBudget: context.taskResourceBudget)

        await observer.taskExecutionDidReportCursorActivity(.modelTurnStarted)
        let conversationEnd = try await conversationRunner.run(
            initialUserText: initialUserText,
            abortSignal: abortSignal,
            handleToolUses: { toolUseBlocks in
                let toolTurnResolution = try await self.resolveToolTurn(toolUseBlocks, context: context, runState: runState,
                                                                         abortSignal: abortSignal)
                if !toolTurnResolution.shouldStopAfterThisTurn {
                    await self.observer.taskExecutionDidReportCursorActivity(.modelTurnStarted)
                }
                return toolTurnResolution
            })

        return makeExecutionResult(conversationEnd: conversationEnd, runState: runState)
    }

    // MARK: - Turn handling

    private func resolveToolTurn(_ toolUseBlocks: [ClaudeToolUseBlock], context: ChecklistItemExecutionContext,
                                 runState: ItemRunState, abortSignal: TaskAbortSignal) async throws -> ClaudeToolTurnResolution {
        var pendingToolResults: [PendingToolResult] = []
        var hasEarlierCallFailedInThisTurn = false

        for (toolUseIndex, toolUseBlock) in toolUseBlocks.enumerated() {
            if hasEarlierCallFailedInThisTurn || runState.forcedItemEnd != nil {
                pendingToolResults.append(.error(toolUseBlock.toolUseIdentifier, Self.skippedAfterEarlierFailureText))
                continue
            }
            if runState.reportedOutcome != nil {
                pendingToolResults.append(.error(toolUseBlock.toolUseIdentifier, Self.skippedAfterFinishItemText))
                continue
            }
            try abortSignal.throwIfAborted()
            for redactedTextFieldName in AgentActionDescriptions.redactedTextInputFieldNamesByToolName[toolUseBlock.toolName] ?? [] {
                if let fieldText = toolUseBlock.input[redactedTextFieldName]?.stringValue {
                    auditLogWriter.registerTypedTextForRedaction(fieldText)
                }
            }
            auditLogWriter.append(eventKind: .toolCall, itemIdentifier: context.item.itemIdentifier,
                                  message: toolUseBlock.toolName,
                                  details: ["tool_use_id": toolUseBlock.toolUseIdentifier,
                                            "input": AgentActionDescriptions.auditSummary(ofToolInput: toolUseBlock.input, toolName: toolUseBlock.toolName)])

            let pendingToolResult = try await executeToolCall(toolUseBlock, isLastToolCallInTurn: toolUseIndex == toolUseBlocks.count - 1,
                                                              context: context, runState: runState, abortSignal: abortSignal)
            auditLogWriter.append(eventKind: .toolResult, itemIdentifier: context.item.itemIdentifier,
                                  message: AgentActionDescriptions.auditSummary(ofToolResultText: pendingToolResult.text),
                                  details: ["tool": toolUseBlock.toolName, "is_error": String(pendingToolResult.isError)])
            pendingToolResults.append(pendingToolResult)
            if pendingToolResult.isError { hasEarlierCallFailedInThisTurn = true }
            runState.stallPolicy.record(pendingToolResult.stepProgress)
            if runState.stallPolicy.itemHasStalled && runState.forcedItemEnd == nil && runState.reportedOutcome == nil {
                runState.forcedItemEnd = .stalledWithoutVisibleChange
                auditLogWriter.append(eventKind: .verification, itemIdentifier: context.item.itemIdentifier, message: "item stalled",
                                      details: ["steps_without_change": String(runState.stallPolicy.consecutiveStepsWithoutChange)])
            }
        }

        if let lastSuccessfulActionIndex = pendingToolResults.lastIndex(where: { $0.wasSuccessfulAction }),
           !abortSignal.isAborted {
            try await Task.sleep(nanoseconds: postActionSettleDelayNanoseconds)
            let refreshedOutline = try await focusedWindowOutline(runState: runState, abortSignal: abortSignal)
            pendingToolResults[lastSuccessfulActionIndex].text += "\n\nUI after action:\n"
                + PromptLibrary.untrustedUserInterfaceBlock(refreshedOutline)
        }

        return ClaudeToolTurnResolution(
            toolResultBlocks: pendingToolResults.map(\.contentBlock),
            shouldStopAfterThisTurn: runState.reportedOutcome != nil || runState.forcedItemEnd != nil)
    }

    private func executeToolCall(_ toolUseBlock: ClaudeToolUseBlock, isLastToolCallInTurn: Bool, context: ChecklistItemExecutionContext,
                                 runState: ItemRunState, abortSignal: TaskAbortSignal) async throws -> PendingToolResult {
        let toolUseIdentifier = toolUseBlock.toolUseIdentifier
        let decodedToolCall: AgentToolCall
        switch AgentToolCallDecoder.decodeToolCall(toolUseBlock) {
        case .success(let toolCall): decodedToolCall = toolCall
        case .failure(let inputError): return .error(toolUseIdentifier, inputError.messageForModel)
        }

        do {
            switch decodedToolCall {
            case .readUserInterface(let readRequest):
                await observer.taskExecutionDidReportCursorActivity(.userInterfaceReadStarted)
                let snapshot = try await actionBackend.readUserInterface(readRequest, abortSignal: abortSignal)
                runState.latestSnapshot = snapshot
                var readResult = PendingToolResult.success(toolUseIdentifier, PromptLibrary.untrustedUserInterfaceBlock(
                    AccessibilityOutlineFormatter.formatOutline(snapshot, query: readRequest.query, limits: .executor)))
                if let query = readRequest.query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty,
                   !snapshot.containsText(query) {
                    readResult.stepProgress = .changedNothing(isAction: false)
                }
                return readResult

            case .screenshot:
                let screenshotCapture = try await actionBackend.captureScreenshot()
                var screenshotResult = PendingToolResult.success(toolUseIdentifier, "")
                for contentPart in ClaudeToolResultBuilding.screenshotResultContent(
                    screenshotCapture, applicationName: context.checklist.targetApplication.applicationName) {
                    switch contentPart {
                    case .text(let descriptionText): screenshotResult.text = descriptionText
                    case .image(let imageBlock): screenshotResult.imageBlocks.append(imageBlock)
                    }
                }
                return screenshotResult

            case .action(let agentAction):
                return try await executeAction(agentAction, toolUseBlock: toolUseBlock, isLastToolCallInTurn: isLastToolCallInTurn,
                                               context: context, runState: runState, abortSignal: abortSignal)

            case .waitFor(let awaitedText, let timeoutSeconds):
                let (waitResultText, awaitedTextWasFound) = try await waitForText(awaitedText, timeoutSeconds: timeoutSeconds,
                                                                                  runState: runState, abortSignal: abortSignal)
                var waitResult = PendingToolResult.success(toolUseIdentifier, waitResultText)
                waitResult.stepProgress = awaitedTextWasFound ? .changedSomething : .changedNothing(isAction: false)
                return waitResult

            case .finishItem(let outcome, let summary):
                guard outcome == .completed else {
                    runState.reportedOutcome = (outcome, summary)
                    return .success(toolUseIdentifier, "Recorded outcome \(outcome.rawValue).")
                }
                return try await verifyCompletion(summary: summary, toolUseBlock: toolUseBlock, context: context,
                                                  runState: runState, abortSignal: abortSignal)

            case .submitPlan, .askUser:
                return .error(toolUseIdentifier, "\(toolUseBlock.toolName) is not available while executing an item.")
            case .readDirectRouteData, .submitDirectRoutePlan:
                return .error(toolUseIdentifier, "\(toolUseBlock.toolName) is only available during planning.")
            }
        } catch {
            if ClaudeToolResultBuilding.isAbort(error, abortSignal: abortSignal) { throw error }
            var errorResult = PendingToolResult.error(toolUseIdentifier, ClaudeToolResultBuilding.fencedMessageForModel(describing: error))
            if case .action = decodedToolCall, case ActionBackendError.inputNotDelivered = error {
                errorResult.stepProgress = .changedNothing(isAction: true)
            }
            return errorResult
        }
    }

    private func executeAction(_ agentAction: AgentAction, toolUseBlock: ClaudeToolUseBlock, isLastToolCallInTurn: Bool,
                               context: ChecklistItemExecutionContext, runState: ItemRunState,
                               abortSignal: TaskAbortSignal) async throws -> PendingToolResult {
        let itemIdentifier = context.item.itemIdentifier
        let toolUseIdentifier = toolUseBlock.toolUseIdentifier
        switch try await context.runControl?.checkpoint(abortSignal: abortSignal) ?? .proceed {
        case .proceed:
            break
        case .resumedAfterPause:
            auditLogWriter.append(eventKind: .resume, itemIdentifier: itemIdentifier, message: "resumed before an action", details: [:])
            let freshOutline = try await focusedWindowOutline(runState: runState, abortSignal: abortSignal)
            return .error(toolUseIdentifier, Self.pausedBeforeActionText + "\n\n" + PromptLibrary.untrustedUserInterfaceBlock(freshOutline))
        case .skipCurrentItem:
            runState.forcedItemEnd = .userSkippedItem
            return .error(toolUseIdentifier, Self.userSkippedItemText)
        }
        let itemActionBudget = min(safetyLimits.maximumActionsPerItem, context.remainingTaskActionBudget)
        if runState.actionsPerformed >= itemActionBudget {
            // The first refusal gives the model one chance to report via finish_item; a second attempt ends the item.
            if runState.hasReceivedActionLimitError { runState.forcedItemEnd = .actionLimitExceeded }
            runState.hasReceivedActionLimitError = true
            return .error(toolUseIdentifier, Self.actionLimitReachedText)
        }

        let preActionSnapshot = runState.latestSnapshot
        let targetElementIdentifier = AgentActionDescriptions.targetElementIdentifier(of: agentAction)
        let targetNode = targetElementIdentifier.flatMap { preActionSnapshot?.node(withIdentifier: $0) }
        let focusedNode = preActionSnapshot?.focusedNode
        let targetApplicationBundleIdentifier = context.checklist.targetApplication.bundleIdentifier
        if context.focusPolicy == .backgroundOnly,
           BackgroundActionPolicy.requiresForeground(agentAction, targetNode: targetNode) {
            runState.forcedItemEnd = .blockedByBackgroundOnly
            return .error(toolUseIdentifier, Self.backgroundOnlyBlockedText)
        }
        var confirmedRiskCategory: SafetyRiskCategory?
        switch SafetyGate.evaluateAction(agentAction, targetNode: targetNode,
                                         riskCategoryConfirmedForThisItem: context.riskCategoryConfirmedForThisItem,
                                         riskCategoriesAllowedForRestOfTask: runState.riskCategoriesAllowedForRestOfTask,
                                         focusedNode: focusedNode,
                                         targetApplicationBundleIdentifier: targetApplicationBundleIdentifier,
                                         uploadFileAllowlist: context.uploadFileAllowlist) {
        case .allow:
            break
        case .deny(let reasonForModel):
            auditLogWriter.append(eventKind: .safetyDecision, itemIdentifier: itemIdentifier,
                                  message: "denied", details: ["reason": reasonForModel])
            return .error(toolUseIdentifier, reasonForModel)
        case .requireUserConfirmation(let reason, let riskCategory):
            auditLogWriter.append(eventKind: .safetyDecision, itemIdentifier: itemIdentifier,
                                  message: "confirmation required",
                                  details: ["reason": reason, "risk_category": riskCategory.rawValue])
            switch await SafetyConfirmationFlow.askUser(
                context.actionConfirmationRequest(reason: reason, riskCategory: riskCategory),
                confirmationRequester: confirmationRequester, auditLogWriter: auditLogWriter,
                riskCategoriesAllowedForRestOfTask: &runState.riskCategoriesAllowedForRestOfTask, abortSignal: abortSignal) {
            case .allowed(let answeredRiskCategory):
                // Covers exactly this action; the next risky action asks again unless the user allowed the category.
                confirmedRiskCategory = answeredRiskCategory
            case .declined:
                runState.forcedItemEnd = .userDeclinedAction
                return .error(toolUseIdentifier, Self.userDeclinedActionText)
            case .stopped:
                runState.forcedItemEnd = .userStoppedTask
                return .error(toolUseIdentifier, Self.userStoppedTaskText)
            }
        }

        try abortSignal.throwIfAborted()
        runState.actionsPerformed += 1
        // Anything the gate would stop without a grant counts, including actions a task-wide grant let through.
        if context.itemWasConfirmedByUser
            || SafetyGate.actionIsRiskyWithoutAnyGrant(agentAction, targetNode: targetNode, focusedNode: focusedNode,
                                                       targetApplicationBundleIdentifier: targetApplicationBundleIdentifier) {
            runState.performedUserConfirmedAction = true
        }
        let targetContext = targetElementIdentifier.flatMap { preActionSnapshot?.recordedElementContext(forNodeWithIdentifier: $0) }
        let requestedExpectation = AgentToolCallDecoder.decodeStepExpectation(fromToolInput: toolUseBlock.input, fieldName: "expect")
        await observer.taskExecutionDidReportProgress(itemIdentifier: itemIdentifier,
                                                      progressDescription: AgentActionDescriptions.progressDescription(of: agentAction, targetNode: targetNode))
        let actionOutcome: ActionOutcome
        switch try await ForegroundAssistingActionPerformer.perform(
            agentAction, actionBackend: actionBackend, confirmationRequester: confirmationRequester, auditLogWriter: auditLogWriter,
            context: context.foregroundAssistContext, riskCategoriesAllowedForRestOfTask: &runState.riskCategoriesAllowedForRestOfTask,
            abortSignal: abortSignal, readinessGate: context.foregroundAssistReadinessGate) {
        case .performed(let performedActionOutcome):
            actionOutcome = performedActionOutcome
        case .userDeclinedForegroundAssist:
            runState.forcedItemEnd = .userDeclinedAction
            return .error(toolUseIdentifier, Self.userDeclinedActionText)
        case .blockedByBackgroundOnly:
            runState.forcedItemEnd = .blockedByBackgroundOnly
            return .error(toolUseIdentifier, Self.backgroundOnlyBlockedText)
        case .userStoppedTask:
            runState.forcedItemEnd = .userStoppedTask
            return .error(toolUseIdentifier, Self.userStoppedTaskText)
        }
        if ChecklistItemRetryPolicy.actionHasSideEffects(agentAction, targetNode: targetNode) { runState.performedSideEffectingAction = true }
        var actionResult = PendingToolResult.success(
            toolUseIdentifier, Self.actionSucceededText + "\n" + PromptLibrary.untrustedUserInterfaceBlock(actionOutcome.descriptionForModel))
        actionResult.wasSuccessfulAction = true
        // Checking re-reads the UI, which would invalidate the ids later calls in this turn still use, so only the
        // turn's last call is checked. Only a check that passed becomes part of a learned routine.
        actionResult.stepProgress = actionOutcome.noVisibleChangeWasSeen ? .changedNothing(isAction: true) : .changedSomething
        var satisfiedExpectation: StepExpectation?
        if let requestedExpectation, isLastToolCallInTurn {
            let verdict = try await waitForExpectation(requestedExpectation, itemIdentifier: itemIdentifier, runState: runState,
                                                       preActionSnapshot: preActionSnapshot, abortSignal: abortSignal)
            if case .unsatisfied(let reasonForModel) = verdict {
                actionResult.text += "\nExpectation not met within \(Int(expectationTimeoutSeconds)) s: \(reasonForModel)"
                actionResult.isError = true
                actionResult.stepProgress = .changedNothing(isAction: true)
            } else {
                satisfiedExpectation = requestedExpectation
                actionResult.stepProgress = .changedSomething
            }
        }
        // The action ran either way, so a routine must repeat it even when its check failed.
        runState.recordedSteps.append(RecordedAgentStep(toolCall: .action(agentAction), targetContext: targetContext,
                                                        expectation: satisfiedExpectation, wasConfirmedByUser: confirmedRiskCategory != nil,
                                                        confirmedRiskCategory: confirmedRiskCategory))
        return actionResult
    }

    /// ADR-10: the model names a check, the app runs it on fresh outlines; one failed check gets a second chance.
    private func verifyCompletion(summary: String, toolUseBlock: ClaudeToolUseBlock, context: ChecklistItemExecutionContext,
                                  runState: ItemRunState, abortSignal: TaskAbortSignal) async throws -> PendingToolResult {
        let toolUseIdentifier = toolUseBlock.toolUseIdentifier
        let isFirstVerificationAttempt = runState.finishItemVerificationRejections == 0
        guard let evidence = AgentToolCallDecoder.decodeStepExpectation(fromToolInput: toolUseBlock.input, fieldName: "evidence") else {
            if isFirstVerificationAttempt {
                runState.finishItemVerificationRejections += 1
                return .error(toolUseIdentifier, Self.evidenceRequiredText)
            }
            runState.reportedOutcome = (.completed, summary)
            return .success(toolUseIdentifier, "Recorded outcome completed.")
        }
        let verdict = try await waitForExpectation(evidence, itemIdentifier: context.item.itemIdentifier, runState: runState,
                                                   preActionSnapshot: nil, abortSignal: abortSignal)
        guard case .unsatisfied(let reasonForModel) = verdict else {
            runState.reportedOutcome = (.completed, summary)
            runState.verifiedCompletionEvidence = evidence
            return .success(toolUseIdentifier, "Verified. Recorded outcome completed.")
        }
        if isFirstVerificationAttempt {
            runState.finishItemVerificationRejections += 1
            return .error(toolUseIdentifier, "Verification failed: \(reasonForModel) Fix the item, or call finish_item with outcome failed.")
        }
        runState.reportedOutcome = (.failed, "Verification failed: \(reasonForModel)")
        return .success(toolUseIdentifier, "Verification failed again; recorded outcome failed.")
    }

    private func waitForExpectation(_ expectation: StepExpectation, itemIdentifier: String, runState: ItemRunState,
                                    preActionSnapshot: AccessibilityTreeSnapshot?, abortSignal: TaskAbortSignal) async throws -> StepExpectationVerdict {
        let (verdict, latestSnapshot) = try await StepExpectationWaiting.waitForExpectation(
            expectation, actionBackend: actionBackend, timeoutSeconds: expectationTimeoutSeconds,
            pollIntervalNanoseconds: waitForPollIntervalNanoseconds, abortSignal: abortSignal, preActionSnapshot: preActionSnapshot)
        if let latestSnapshot { runState.latestSnapshot = latestSnapshot }
        auditLogWriter.append(eventKind: .verification, itemIdentifier: itemIdentifier,
                              message: verdict == .satisfied ? "check passed" : "check failed",
                              details: ["kind": expectation.kind.rawValue])
        return verdict
    }

    private func waitForText(_ awaitedText: String, timeoutSeconds: Int, runState: ItemRunState,
                             abortSignal: TaskAbortSignal) async throws -> (resultText: String, awaitedTextWasFound: Bool) {
        let waitDeadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        await observer.taskExecutionDidReportCursorActivity(.userInterfaceReadStarted)
        while true {
            try abortSignal.throwIfAborted()
            let snapshot = try await readFocusedWindow(runState: runState, abortSignal: abortSignal)
            let outline = PromptLibrary.untrustedUserInterfaceBlock(
                AccessibilityOutlineFormatter.formatOutline(snapshot, query: nil, limits: .executor))
            if snapshot.containsText(awaitedText) {
                runState.recordedSteps.append(RecordedAgentStep(toolCall: .waitFor(text: awaitedText, timeoutSeconds: timeoutSeconds),
                                                                targetContext: nil, expectation: nil, wasConfirmedByUser: false))
                return ("found \"\(awaitedText)\"\n\n" + outline, true)
            }
            if Date() >= waitDeadline { return ("not found after \(timeoutSeconds) s\n\n" + outline, false) }
            try await Task.sleep(nanoseconds: waitForPollIntervalNanoseconds)
        }
    }

    /// A failed read is reported inline rather than thrown so the model can still decide what to do.
    private func focusedWindowOutline(runState: ItemRunState, abortSignal: TaskAbortSignal) async throws -> String {
        await observer.taskExecutionDidReportCursorActivity(.userInterfaceReadStarted)
        do {
            let snapshot = try await readFocusedWindow(runState: runState, abortSignal: abortSignal)
            return AccessibilityOutlineFormatter.formatOutline(snapshot, query: nil, limits: .executor)
        } catch {
            if ClaudeToolResultBuilding.isAbort(error, abortSignal: abortSignal) { throw error }
            return "(Could not read the UI: \(ClaudeToolResultBuilding.messageForModel(describing: error)))"
        }
    }

    private func readFocusedWindow(runState: ItemRunState, abortSignal: TaskAbortSignal) async throws -> AccessibilityTreeSnapshot {
        let snapshot = try await actionBackend.readUserInterface(
            ReadUserInterfaceRequest(scope: .focusedWindow, applicationName: nil, query: nil), abortSignal: abortSignal)
        runState.latestSnapshot = snapshot
        return snapshot
    }

    // MARK: - Result mapping

    private func makeExecutionResult(conversationEnd: ClaudeToolConversationEnd, runState: ItemRunState) -> ChecklistItemExecutionResult {
        func result(_ runStatus: ChecklistItemRunStatus, _ resultSummary: String) -> ChecklistItemExecutionResult {
            ChecklistItemExecutionResult(runStatus: runStatus, resultSummary: resultSummary,
                                         actionsPerformed: runState.actionsPerformed,
                                         userChoseToStopTask: runState.forcedItemEnd == .userStoppedTask,
                                         riskCategoriesAllowedForRestOfTask: runState.riskCategoriesAllowedForRestOfTask,
                                         recordedSteps: runState.recordedSteps,
                                         verifiedCompletionEvidence: runState.verifiedCompletionEvidence,
                                         performedUserConfirmedAction: runState.performedUserConfirmedAction,
                                         performedSideEffectingAction: runState.performedSideEffectingAction,
                                         failedDeterministically: runState.forcedItemEnd == .blockedByBackgroundOnly)
        }

        switch runState.forcedItemEnd {
        case .userStoppedTask: return result(.skipped, TaskUserFacingMessages.itemStoppedByUserSummary)
        case .userSkippedItem: return result(.skipped, TaskUserFacingMessages.itemSkippedByUserSummary)
        case .userDeclinedAction: return result(.skipped, TaskUserFacingMessages.itemActionDeclinedByUserSummary)
        case .blockedByBackgroundOnly: return result(.needsUser, TaskUserFacingMessages.itemNeedsForegroundSummary)
        case .actionLimitExceeded: return result(.failed, TaskUserFacingMessages.itemActionLimitReachedSummary)
        case .stalledWithoutVisibleChange: return result(.needsUser, ChecklistItemStallPolicy.stalledItemSummary)
        case nil: break
        }
        if let reportedOutcome = runState.reportedOutcome {
            switch reportedOutcome.outcome {
            case .completed: return result(.completed, reportedOutcome.summary)
            case .failed: return result(.failed, reportedOutcome.summary)
            case .needsUser: return result(.needsUser, reportedOutcome.summary)
            }
        }
        switch conversationEnd {
        case .stoppedByToolHandler, .endedWithoutRequiredTool, .pausedForUserReply, .endedWithTextOnlyTurn:
            return result(.failed, "Claude stopped without reporting the item's outcome.")
        case .refused(let explanation):
            return result(.failed, "Claude declined this item" + (explanation.map { ": \($0)" } ?? "."))
        case .turnLimitReached:
            return result(.failed, "Reached the model turn limit for this item.")
        case .truncatedRepeatedly:
            return result(.failed, "Claude's response was cut off repeatedly.")
        case .unexpectedStopReason(let stopReason):
            return result(.failed, "Unexpected stop reason \(stopReason).")
        }
    }
}
