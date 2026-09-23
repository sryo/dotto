import Foundation

struct TaskExecutionOptions {
    var focusPolicy: TaskFocusPolicy = .allowApprovedAssist
    var runControl: TaskRunControl? = nil
    var interactionHandler: TaskExecutionInteractionHandling? = nil
    var routineToReplay: Routine? = nil
    var metricsAccumulator: TaskRunMetricsAccumulator? = nil
    /// The files the user attached to this task; the backend refuses every other upload path.
    var uploadFileAllowlist: UploadFileAllowlist = .empty
    /// Holds every bring-forward until the user has paused (no recent input, no password field active elsewhere).
    var foregroundAssistReadinessGate: ForegroundAssistReadinessGating? = nil
}

/// Walks the approved plan item by item: plan-level safety confirmation, one agent loop per item,
/// observer + audit updates, and the task-wide stop conditions.
final class TaskExecutor {
    private static let maximumConsecutiveTransportFailures = 2

    let checklistItemAgentLoop: ChecklistItemAgentLoop
    let routineReplayEngine: RoutineReplayEngine
    /// The routine items replay; learned from the first verified agent item, patched after a fallback. Used for
    /// the rest of this task only; it reaches the library only if the user saves it after review.
    private(set) var currentRoutine: Routine?
    private let options: TaskExecutionOptions
    private let actionBackend: ActionBackend
    private let confirmationRequester: UserConfirmationRequesting
    private let observer: TaskExecutionObserving
    private let auditLogWriter: AuditLogWriter
    /// Created before planning, so planning, compiling a taught routine and this run all draw on the same ceilings.
    private let taskResourceBudget: TaskResourceBudget
    private let safetyLimits: SafetyLimits
    private let currentDate: () -> Date

    init(transport: ClaudeTransport, actionBackend: ActionBackend,
         confirmationRequester: UserConfirmationRequesting, observer: TaskExecutionObserving,
         auditLogWriter: AuditLogWriter, taskResourceBudget: TaskResourceBudget, safetyLimits: SafetyLimits = .standard,
         currentDate: @escaping () -> Date = Date.init, options: TaskExecutionOptions = TaskExecutionOptions()) {
        self.checklistItemAgentLoop = ChecklistItemAgentLoop(
            transport: transport, actionBackend: actionBackend, confirmationRequester: confirmationRequester,
            observer: observer, auditLogWriter: auditLogWriter, safetyLimits: safetyLimits)
        self.routineReplayEngine = RoutineReplayEngine(
            actionBackend: actionBackend, confirmationRequester: confirmationRequester, observer: observer,
            auditLogWriter: auditLogWriter, safetyLimits: safetyLimits)
        self.currentRoutine = options.routineToReplay
        self.options = options
        self.actionBackend = actionBackend
        self.confirmationRequester = confirmationRequester
        self.observer = observer
        self.auditLogWriter = auditLogWriter
        self.taskResourceBudget = taskResourceBudget
        self.safetyLimits = safetyLimits
        self.currentDate = currentDate
    }

    func run(approvedChecklist: Checklist, abortSignal: TaskAbortSignal) async -> TaskRunSummary {
        var workingChecklist = approvedChecklist
        auditLogWriter.append(eventKind: .checklistApproved, itemIdentifier: nil, message: workingChecklist.title,
                              details: ["included_item_count": String(workingChecklist.includedItems.count)])

        let stopReason: TaskStopReason
        do {
            try await actionBackend.prepareForTask(ActionBackendTaskConfiguration(
                targetApplication: workingChecklist.targetApplication, uploadFileAllowlist: options.uploadFileAllowlist))
            stopReason = await runIncludedItems(of: &workingChecklist, abortSignal: abortSignal)
        } catch {
            stopReason = ClaudeToolResultBuilding.isAbort(error, abortSignal: abortSignal)
                ? .userAborted
                : .unrecoverableError(ClaudeToolResultBuilding.messageForModel(describing: error))
        }

        let runSummary = TaskRunSummary.summarize(checklist: workingChecklist, stopReason: stopReason)
        let runSucceeded = stopReason == .allItemsProcessed && runSummary.failedItemCount == 0 && runSummary.needsUserItemCount == 0
        // Reported before the backend winds down: finishTask hides the cursor, and the done or stuck state (and its
        // "finished" attention request) must already be showing so the presenter can keep it up briefly.
        await observer.taskExecutionDidReportCursorActivity(.runFinished(succeeded: runSucceeded))
        await actionBackend.finishTask()
        auditLogWriter.append(eventKind: stopReason == .userAborted ? .taskAborted : .taskFinished,
                              itemIdentifier: nil, message: String(describing: stopReason),
                              details: ["completed": String(runSummary.completedItemCount),
                                        "failed": String(runSummary.failedItemCount),
                                        "needs_user": String(runSummary.needsUserItemCount),
                                        "skipped": String(runSummary.skippedItemCount)])
        return runSummary
    }

    private func runIncludedItems(of workingChecklist: inout Checklist, abortSignal: TaskAbortSignal) async -> TaskStopReason {
        let includedItems = workingChecklist.includedItems
        taskResourceBudget.startRunWallClock()
        var riskCategoriesAllowedForRestOfTask: Set<SafetyRiskCategory> = []
        var consecutiveUnsuccessfulItemCount = 0
        var consecutiveTransportFailureCount = 0
        var totalActionsPerformed = 0
        var previousItemResultSummary: String?

        for (includedItemIndex, item) in includedItems.enumerated() where item.runStatus == .pending {
            if abortSignal.isAborted { return .userAborted }
            if let runControl = options.runControl {
                let betweenItemsOutcome: TaskRunCheckpointOutcome
                do { betweenItemsOutcome = try await runControl.checkpointBetweenItems(abortSignal: abortSignal) } catch { return .userAborted }
                if betweenItemsOutcome == .skipCurrentItem {
                    await recordFinishedItem(item.itemIdentifier, runStatus: .skipped,
                                             resultSummary: TaskUserFacingMessages.itemSkippedByUserSummary, in: &workingChecklist)
                    continue
                }
            }
            let remainingTaskActionBudget = safetyLimits.maximumActionsPerTask - totalActionsPerformed
            if remainingTaskActionBudget <= 0 { return .taskActionLimitReached }
            do {
                try taskResourceBudget.throwIfExhausted()
            } catch {
                return stopReason(forCeilingError: error)
            }

            // A routine needing a foreground step is bypassed under background-only mode. The agent gets a chance
            // to find another route, and its actual actions receive their own safety checks.
            let routineNeedsForeground = options.focusPolicy == .backgroundOnly
                && currentRoutine?.steps.contains(where: BackgroundActionPolicy.requiresForeground) == true
            // Covers only this category: an item confirmed as "irreversible" or "sending" still asks before a delete.
            var riskCategoryConfirmedForThisItem: SafetyRiskCategory?
            let itemSafetyVerdict: SafetyVerdict = routineNeedsForeground ? .allow : SafetyGate.evaluateChecklistItem(item)
            if case .requireUserConfirmation(let reason, let riskCategory) = itemSafetyVerdict {
                if riskCategoriesAllowedForRestOfTask.contains(riskCategory) {
                    // The user already allowed this exact kind of item for the rest of the task.
                    riskCategoryConfirmedForThisItem = riskCategory
                    auditLogWriter.append(eventKind: .safetyDecision, itemIdentifier: item.itemIdentifier,
                                          message: "allowed by earlier grant",
                                          details: ["reason": reason, "risk_category": riskCategory.rawValue])
                } else {
                    switch await SafetyConfirmationFlow.askUser(
                        SafetyConfirmationRequest(itemIdentifier: item.itemIdentifier, itemLabel: item.label,
                                                  reason: reason, isActionLevel: false, riskCategory: riskCategory,
                                                  itemParameters: item.parameters),
                        confirmationRequester: confirmationRequester, auditLogWriter: auditLogWriter,
                        riskCategoriesAllowedForRestOfTask: &riskCategoriesAllowedForRestOfTask, abortSignal: abortSignal) {
                    case .allowed(let answeredRiskCategory):
                        riskCategoryConfirmedForThisItem = answeredRiskCategory
                    case .declined:
                        await recordFinishedItem(item.itemIdentifier, runStatus: .skipped,
                                                 resultSummary: TaskUserFacingMessages.itemSkippedByUserSummary, in: &workingChecklist)
                        continue
                    case .stopped:
                        return .userAborted
                    }
                    if abortSignal.isAborted { return .userAborted }
                }
            }

            await observer.taskExecutionDidStartItem(itemIdentifier: item.itemIdentifier)
            await observer.taskExecutionDidReportCursorActivity(.itemStarted(itemLabel: item.label, itemPosition: includedItemIndex + 1,
                                                                             itemCount: includedItems.count))
            workingChecklist = workingChecklist.updatingItem(withIdentifier: item.itemIdentifier) { $0.runStatus = .running }
            auditLogWriter.append(eventKind: .itemStarted, itemIdentifier: item.itemIdentifier, message: item.label, details: [:])

            let itemContext = ChecklistItemExecutionContext(
                checklist: workingChecklist, item: item,
                itemPositionAmongIncludedItems: includedItemIndex + 1,
                includedItemCount: includedItems.count,
                previousItemResultSummary: previousItemResultSummary,
                riskCategoryConfirmedForThisItem: riskCategoryConfirmedForThisItem,
                remainingTaskActionBudget: remainingTaskActionBudget,
                riskCategoriesAllowedForRestOfTask: riskCategoriesAllowedForRestOfTask,
                taskResourceBudget: taskResourceBudget, runControl: options.runControl,
                uploadFileAllowlist: options.uploadFileAllowlist,
                foregroundAssistReadinessGate: options.foregroundAssistReadinessGate,
                focusPolicy: options.focusPolicy)

            let itemResult: ChecklistItemExecutionResult
            do {
                itemResult = try await runItemWithRetries(itemContext, abortSignal: abortSignal)
                consecutiveTransportFailureCount = 0
            } catch {
                if ClaudeToolResultBuilding.isAbort(error, abortSignal: abortSignal) {
                    // Mirrors the state machine: an item interrupted by abort counts as skipped, not failed.
                    await recordFinishedItem(item.itemIdentifier, runStatus: .skipped,
                                             resultSummary: TaskUserFacingMessages.itemStoppedByUserSummary, in: &workingChecklist)
                    return .userAborted
                }
                if let ceilingError = error as? TaskCeilingReachedError {
                    await recordFinishedItem(item.itemIdentifier, runStatus: .failed,
                                             resultSummary: "Stopped: \(ceilingError.userFacingDescription).", in: &workingChecklist)
                    return stopReason(forCeilingError: ceilingError)
                }
                consecutiveTransportFailureCount += 1
                auditLogWriter.append(eventKind: .error, itemIdentifier: item.itemIdentifier,
                                      message: String(describing: error), details: [:])
                itemResult = ChecklistItemExecutionResult(
                    runStatus: .failed, resultSummary: "Could not reach Claude: \(error.localizedDescription)",
                    actionsPerformed: 0, userChoseToStopTask: false,
                    riskCategoriesAllowedForRestOfTask: riskCategoriesAllowedForRestOfTask)
            }

            totalActionsPerformed += itemResult.actionsPerformed
            riskCategoriesAllowedForRestOfTask.formUnion(itemResult.riskCategoriesAllowedForRestOfTask)
            await recordFinishedItem(item.itemIdentifier, runStatus: itemResult.runStatus,
                                     resultSummary: itemResult.resultSummary, in: &workingChecklist)
            previousItemResultSummary = itemResult.resultSummary
            if let metricsAccumulator = options.metricsAccumulator {
                await options.interactionHandler?.taskExecutionDidUpdateMetrics(metricsAccumulator.currentMetrics)
            }

            if itemResult.userChoseToStopTask { return .userAborted }
            if consecutiveTransportFailureCount >= Self.maximumConsecutiveTransportFailures {
                return .unrecoverableError("Claude could not be reached for \(consecutiveTransportFailureCount) items in a row.")
            }
            switch itemResult.runStatus {
            case .failed, .needsUser: consecutiveUnsuccessfulItemCount += 1
            case .completed: consecutiveUnsuccessfulItemCount = 0
            case .pending, .running, .skipped: break
            }
            if consecutiveUnsuccessfulItemCount >= safetyLimits.maximumConsecutiveFailedItems {
                return .tooManyConsecutiveFailures
            }
        }

        return abortSignal.isAborted ? .userAborted : .allItemsProcessed
    }

    // MARK: - Attempts, replay and routine learning

    /// Runs attempts until ChecklistItemRetryPolicy accepts one. The returned result sums actions and grants over all attempts.
    private func runItemWithRetries(_ firstAttemptContext: ChecklistItemExecutionContext,
                                    abortSignal: TaskAbortSignal) async throws -> ChecklistItemExecutionResult {
        let item = firstAttemptContext.item
        let itemStartDate = currentDate()
        let modelCallsBeforeItem = options.metricsAccumulator?.currentMetrics.modelCallCount ?? 0
        var attemptContext = firstAttemptContext
        var automaticRetriesUsed = 0
        var attemptCount = 0
        var actionsInEarlierAttempts = 0
        var earlierAttemptPerformedConfirmedAction = false
        var earlierAttemptPerformedSideEffectingAction = false
        while true {
            attemptCount += 1
            let modelCallsBeforeAttempt = options.metricsAccumulator?.currentMetrics.modelCallCount ?? 0
            let routineAtAttemptStart = currentRoutine
            // After an attempt changed data, replaying from step 1 would redo those changes; the agent instead
            // starts from a fresh read of what the earlier attempt left.
            let usesAgentOnly = earlierAttemptPerformedSideEffectingAction
                || (attemptContext.focusPolicy == .backgroundOnly
                    && currentRoutine?.steps.contains(where: BackgroundActionPolicy.requiresForeground) == true)
            var (attemptResult, executionPath) = try await runSingleAttempt(attemptContext, attemptNumber: attemptCount,
                                                                            usesAgentOnly: usesAgentOnly, abortSignal: abortSignal)
            // Only attempt 1 starts from the untouched UI every other item starts from, so only it may teach a routine.
            if attemptResult.runStatus == .completed, attemptCount == 1, routineAtAttemptStart == nil,
               let verifiedCompletionEvidence = attemptResult.verifiedCompletionEvidence,
               let learnedRoutine = RoutineCompiler.compileFromAgentRun(
                   recordedSteps: attemptResult.recordedSteps, completionEvidence: verifiedCompletionEvidence,
                   checklist: attemptContext.checklist, item: item,
                   modelCallsUsed: (options.metricsAccumulator?.currentMetrics.modelCallCount ?? 0) - modelCallsBeforeAttempt,
                   routineIdentifier: "routine-" + attemptContext.checklist.taskIdentifier, now: currentDate()) {
                await adoptRoutine(learnedRoutine, wasNewlyLearned: true)
            }
            attemptContext.remainingTaskActionBudget -= attemptResult.actionsPerformed
            attemptContext.riskCategoriesAllowedForRestOfTask = attemptResult.riskCategoriesAllowedForRestOfTask
            actionsInEarlierAttempts += attemptResult.actionsPerformed
            earlierAttemptPerformedConfirmedAction = earlierAttemptPerformedConfirmedAction || attemptResult.performedUserConfirmedAction
            earlierAttemptPerformedSideEffectingAction = earlierAttemptPerformedSideEffectingAction || attemptResult.performedSideEffectingAction
            attemptResult.actionsPerformed = actionsInEarlierAttempts
            attemptResult.performedUserConfirmedAction = earlierAttemptPerformedConfirmedAction
            attemptResult.performedSideEffectingAction = earlierAttemptPerformedSideEffectingAction

            let failureSummary = attemptResult.resultSummary
            switch ChecklistItemRetryPolicy.followUp(afterAttemptWith: attemptResult.runStatus, automaticRetriesUsed: automaticRetriesUsed,
                                                     itemIsIrreversible: item.isIrreversible,
                                                     itemPerformedUserConfirmedAction: earlierAttemptPerformedConfirmedAction,
                                                     canAskUser: options.interactionHandler != nil,
                                                     attemptFailedDeterministically: attemptResult.failedDeterministically,
                                                     itemPerformedSideEffectingAction: earlierAttemptPerformedSideEffectingAction) {
            case .acceptResult:
                if attemptResult.runStatus == .completed {
                    options.metricsAccumulator?.recordCompletedItem(
                        path: executionPath,
                        modelCallsUsed: (options.metricsAccumulator?.currentMetrics.modelCallCount ?? 0) - modelCallsBeforeItem,
                        durationSeconds: currentDate().timeIntervalSince(itemStartDate))
                }
                return attemptResult
            case .retryAutomatically:
                automaticRetriesUsed += 1
            case .askUser:
                guard let interactionHandler = options.interactionHandler else { return attemptResult }
                let decision = await interactionHandler.requestItemFailureDecision(ChecklistItemFailureDecisionRequest(
                    itemIdentifier: item.itemIdentifier, itemLabel: item.label, failureSummary: failureSummary, attemptCount: attemptCount))
                auditLogWriter.append(eventKind: .userConfirmation, itemIdentifier: item.itemIdentifier,
                                      message: "item failure decision: \(decision)", details: [:])
                switch decision {
                case .retry:
                    break
                case .skipItem:
                    attemptResult.runStatus = .skipped
                    attemptResult.resultSummary = "Skipped by you after: \(failureSummary)"
                    return attemptResult
                case .stopTask:
                    abortSignal.abort()
                    attemptResult.runStatus = .skipped
                    attemptResult.resultSummary = TaskUserFacingMessages.itemStoppedByUserSummary
                    attemptResult.userChoseToStopTask = true
                    return attemptResult
                }
            }
            if abortSignal.isAborted || attemptContext.remainingTaskActionBudget <= 0 { return attemptResult }
            attemptContext.additionalContextForModel = "Attempt \(attemptCount) of this item failed: \(failureSummary). "
                + "The UI may be partly changed by that attempt; check it before acting."
            auditLogWriter.append(eventKind: .retry, itemIdentifier: item.itemIdentifier, message: failureSummary,
                                  details: ["attempt": String(attemptCount + 1)])
            await observer.taskExecutionDidReportProgress(itemIdentifier: item.itemIdentifier,
                                                          progressDescription: "Retrying (attempt \(attemptCount + 1))…")
        }
    }

    private func runSingleAttempt(_ context: ChecklistItemExecutionContext, attemptNumber: Int, usesAgentOnly: Bool,
                                  abortSignal: TaskAbortSignal) async throws -> (ChecklistItemExecutionResult, ChecklistItemExecutionPath) {
        guard let routine = currentRoutine, !usesAgentOnly else {
            return (try await checklistItemAgentLoop.runItem(context, abortSignal: abortSignal), .agent)
        }
        let replayOutcome = try await routineReplayEngine.replayItem(routine, context: context, abortSignal: abortSignal)
        guard case .needsAgentFallback(let failedStepIndex, let reason, let replayProgress) = replayOutcome else {
            guard case .finished(let replayResult) = replayOutcome else { preconditionFailure("unhandled replay outcome") }
            return (replayResult, .replay)
        }
        options.metricsAccumulator?.recordReplayFallback()
        auditLogWriter.append(eventKind: .replayFallback, itemIdentifier: context.item.itemIdentifier, message: reason,
                              details: ["failed_step": String(failedStepIndex + 1), "routine": routine.routineIdentifier])

        let failedStepDescription = routine.steps.indices.contains(failedStepIndex)
            ? (try? RoutineTemplating.render(routine.steps[failedStepIndex].stepDescription, parameters: context.item.parameters))
                ?? routine.steps[failedStepIndex].stepDescription
            : nil
        let failedPart = failedStepDescription.map { "step \(failedStepIndex + 1) (“\($0)”)" } ?? "its completion check"
        var fallbackContext = context
        fallbackContext.remainingTaskActionBudget -= replayProgress.actionsPerformed
        fallbackContext.riskCategoriesAllowedForRestOfTask = replayProgress.riskCategoriesAllowedForRestOfTask
        fallbackContext.additionalContextForModel = [context.additionalContextForModel,
            "A recorded routine did \(failedStepIndex) of its \(routine.steps.count) steps for this item, then \(failedPart) failed: "
                + "\(reason) Finish the item from the current UI state."].compactMap { $0 }.joined(separator: "\n")

        var agentResult = try await checklistItemAgentLoop.runItem(fallbackContext, abortSignal: abortSignal)
        if attemptNumber == 1, agentResult.runStatus == .completed, agentResult.verifiedCompletionEvidence != nil,
           failedStepIndex < routine.steps.count,
           let patchedRoutine = RoutineCompiler.patch(routine, replacingStepsFrom: failedStepIndex,
                                                      withAgentSteps: agentResult.recordedSteps, item: context.item, now: currentDate()) {
            await adoptRoutine(patchedRoutine, wasNewlyLearned: false)
        }
        agentResult.actionsPerformed += replayProgress.actionsPerformed
        agentResult.performedUserConfirmedAction = agentResult.performedUserConfirmedAction || replayProgress.performedUserConfirmedAction
        agentResult.performedSideEffectingAction = agentResult.performedSideEffectingAction || replayProgress.performedSideEffectingAction
        return (agentResult, .replayFallback)
    }

    /// No disk write here: a routine learned from an agent run, or patched after a fallback, replays for the rest of
    /// this task and is handed to the user to review; only a review saves it.
    private func adoptRoutine(_ routine: Routine, wasNewlyLearned: Bool) async {
        currentRoutine = routine
        auditLogWriter.append(eventKind: .routineReadyForReview, itemIdentifier: nil, message: routine.name,
                              details: ["routine": routine.routineIdentifier, "patch_count": String(routine.patchCount)])
        await options.interactionHandler?.taskExecutionDidUpdateRoutine(routine, wasNewlyLearned: wasNewlyLearned)
    }

    private func stopReason(forCeilingError error: Error) -> TaskStopReason {
        guard let ceilingError = error as? TaskCeilingReachedError else {
            return .unrecoverableError(ClaudeToolResultBuilding.messageForModel(describing: error))
        }
        auditLogWriter.append(eventKind: .error, itemIdentifier: nil, message: "Task ceiling reached",
                              details: ["reason": ceilingError.userFacingDescription])
        return .taskCeilingReached(ceilingError.userFacingDescription)
    }

    private func recordFinishedItem(_ itemIdentifier: String, runStatus: ChecklistItemRunStatus, resultSummary: String,
                                    in workingChecklist: inout Checklist) async {
        workingChecklist = workingChecklist.updatingItem(withIdentifier: itemIdentifier) { finishedItem in
            finishedItem.runStatus = runStatus
            finishedItem.resultSummary = resultSummary
        }
        await observer.taskExecutionDidFinishItem(itemIdentifier: itemIdentifier, runStatus: runStatus, resultSummary: resultSummary)
        auditLogWriter.append(eventKind: .itemFinished, itemIdentifier: itemIdentifier, message: resultSummary,
                              details: ["run_status": runStatus.rawValue])
    }
}
