import Foundation

enum RoutineReplayItemOutcome: Equatable {
    case finished(ChecklistItemExecutionResult)
    /// Steps before `failedStepIndex` ran (`routine.steps.count` means only the completion check failed).
    /// `progressSoFar` carries their actions and grants into the agent fallback.
    case needsAgentFallback(failedStepIndex: Int, reason: String, progressSoFar: ChecklistItemExecutionResult)
}

/// Replays a routine for one item without Claude. Every step re-reads the target app, resolves its locator on
/// the live UI and passes SafetyGate on the resolved node, exactly like an agent action (§5).
final class RoutineReplayEngine {
    var stepSettleDelayNanoseconds: UInt64 = 350_000_000
    var expectationPollIntervalNanoseconds: UInt64 = 250_000_000
    var expectationTimeoutSeconds = StepExpectation.defaultTimeoutSeconds

    private let actionBackend: ActionBackend
    private let confirmationRequester: UserConfirmationRequesting
    private let observer: TaskExecutionObserving
    private let auditLogWriter: AuditLogWriter
    private let safetyLimits: SafetyLimits

    init(actionBackend: ActionBackend, confirmationRequester: UserConfirmationRequesting,
         observer: TaskExecutionObserving, auditLogWriter: AuditLogWriter, safetyLimits: SafetyLimits = .standard) {
        self.actionBackend = actionBackend
        self.confirmationRequester = confirmationRequester
        self.observer = observer
        self.auditLogWriter = auditLogWriter
        self.safetyLimits = safetyLimits
    }

    func replayItem(_ routine: Routine, context: ChecklistItemExecutionContext,
                    abortSignal: TaskAbortSignal) async throws -> RoutineReplayItemOutcome {
        let item = context.item
        let targetApplicationBundleIdentifier = context.checklist.targetApplication.bundleIdentifier
        let itemActionBudget = min(safetyLimits.maximumActionsPerItem, context.remainingTaskActionBudget)
        var progress = ChecklistItemExecutionResult(runStatus: .failed, resultSummary: "", actionsPerformed: 0, userChoseToStopTask: false,
                                                    riskCategoriesAllowedForRestOfTask: context.riskCategoriesAllowedForRestOfTask)
        func finished(_ runStatus: ChecklistItemRunStatus, _ resultSummary: String) -> RoutineReplayItemOutcome {
            progress.runStatus = runStatus
            progress.resultSummary = resultSummary
            return .finished(progress)
        }
        /// A failure a retry would only repeat, so the item goes to the user instead of being retried.
        func failedDeterministically(_ resultSummary: String) -> RoutineReplayItemOutcome {
            progress.failedDeterministically = true
            return finished(.failed, resultSummary)
        }
        func stoppedByUser() -> RoutineReplayItemOutcome {
            progress.userChoseToStopTask = true
            return finished(.skipped, TaskUserFacingMessages.itemStoppedByUserSummary)
        }
        func fallback(atStep stepIndex: Int, _ reason: String) -> RoutineReplayItemOutcome {
            .needsAgentFallback(failedStepIndex: stepIndex, reason: reason, progressSoFar: progress)
        }
        func render(_ template: String) throws -> String { try RoutineTemplating.render(template, parameters: item.parameters) }
        func waitFor(_ expectation: StepExpectation, timeoutSeconds: Double,
                     preActionSnapshot: AccessibilityTreeSnapshot?) async throws -> StepExpectationVerdict {
            try await StepExpectationWaiting.waitForExpectation(
                expectation, actionBackend: actionBackend, timeoutSeconds: timeoutSeconds,
                pollIntervalNanoseconds: expectationPollIntervalNanoseconds, abortSignal: abortSignal,
                preActionSnapshot: preActionSnapshot).verdict
        }

        for (stepIndex, step) in routine.steps.enumerated() {
            if try await context.runControl?.checkpoint(abortSignal: abortSignal) == .skipCurrentItem {
                return finished(.skipped, TaskUserFacingMessages.itemSkippedByUserSummary)
            }
            await observer.taskExecutionDidReportCursorActivity(.replayStepStarted(stepIndex: stepIndex, stepCount: routine.steps.count))
            let stepDescription = (try? render(step.stepDescription)) ?? step.stepDescription
            // Read, template and perform errors hand the item to the agent; only abort and password fields don't.
            do {
                var resolvedNode: AccessibilityElementNode?
                var preActionSnapshot: AccessibilityTreeSnapshot?
                if let locator = step.targetLocator {
                    let snapshot = try await actionBackend.readUserInterface(
                        ReadUserInterfaceRequest(scope: locator.readScope, applicationName: nil, query: nil), abortSignal: abortSignal)
                    let resolution = try ElementLocatorResolver.resolve(locator, parameters: item.parameters, in: snapshot)
                    guard snapshot.application.processIdentifier == context.checklist.targetApplication.processIdentifier,
                          case .resolved(let node, _) = resolution else {
                        return fallback(atStep: stepIndex, resolution.failureReasonForModel ?? "The recorded element isn't in the target app.")
                    }
                    resolvedNode = node
                    preActionSnapshot = snapshot
                } else if case .waitForText = step.action {
                    // Waiting reads the UI itself.
                } else {
                    // Keys and focused-field typing act on whatever has focus, so SafetyGate needs to see it.
                    preActionSnapshot = try await actionBackend.readUserInterface(
                        ReadUserInterfaceRequest(scope: .focusedWindow, applicationName: nil, query: nil), abortSignal: abortSignal)
                }
                let focusedNode = preActionSnapshot?.focusedNode

                let agentAction: AgentAction
                switch step.action {
                case .waitForText(let textTemplate, let timeoutSeconds):
                    let verdict = try await waitFor(StepExpectation(kind: .textAppears, text: try render(textTemplate)),
                                                    timeoutSeconds: Double(timeoutSeconds), preActionSnapshot: nil)
                    if case .unsatisfied(let reasonForModel) = verdict { return fallback(atStep: stepIndex, reasonForModel) }
                    continue
                case .click(let clickType):
                    guard let resolvedNode else { return fallback(atStep: stepIndex, "The click step has no recorded target.") }
                    agentAction = .clickElement(elementIdentifier: resolvedNode.elementIdentifier, clickType: clickType)
                case .typeText(let textTemplate, let replaceExistingText, let pressReturnAfter):
                    agentAction = .typeText(elementIdentifier: resolvedNode?.elementIdentifier, text: try render(textTemplate),
                                            replaceExistingText: replaceExistingText, pressReturnAfter: pressReturnAfter)
                case .pressKey(let keyName, let modifiers):
                    agentAction = .pressKey(keyName: keyName, modifiers: modifiers)
                case .uploadFiles(let filePathTemplates):
                    guard let resolvedNode else { return fallback(atStep: stepIndex, "The upload step has no recorded target.") }
                    // The backend re-checks every rendered path against this task's allowlist, so a saved routine can
                    // never upload files attached to an earlier task.
                    agentAction = .uploadFiles(elementIdentifier: resolvedNode.elementIdentifier, filePaths: try filePathTemplates.map(render))
                }
                let renderedExpectation = try step.expectation?.renderingParameters(item.parameters)

                if context.focusPolicy == .backgroundOnly,
                   BackgroundActionPolicy.requiresForeground(agentAction, targetNode: resolvedNode) {
                    progress.failedDeterministically = true
                    return finished(.needsUser, TaskUserFacingMessages.itemNeedsForegroundSummary)
                }

                // A routine file can only add confirmations (A1): the live gate runs first, the recorded flag on top.
                // Neither an item confirmation nor a grant covers a step unless it names the step's own category.
                var confirmationNeeded: (reason: String, riskCategory: SafetyRiskCategory)?
                switch SafetyGate.evaluateAction(agentAction, targetNode: resolvedNode,
                                                 riskCategoryConfirmedForThisItem: context.riskCategoryConfirmedForThisItem,
                                                 riskCategoriesAllowedForRestOfTask: progress.riskCategoriesAllowedForRestOfTask,
                                                 focusedNode: focusedNode, targetApplicationBundleIdentifier: targetApplicationBundleIdentifier,
                                                 uploadFileAllowlist: context.uploadFileAllowlist) {
                case .deny(let reasonForModel):
                    auditLogWriter.append(eventKind: .safetyDecision, itemIdentifier: item.itemIdentifier, message: "denied",
                                          details: ["reason": reasonForModel])
                    return failedDeterministically(reasonForModel)
                case .requireUserConfirmation(let reason, let riskCategory):
                    confirmationNeeded = ("Routine step \(stepIndex + 1): \(reason)", riskCategory)
                case .allow:
                    let stepRiskCategory = step.confirmationRiskCategory ?? .irreversibleItem
                    if step.requiresConfirmationEachItem && stepRiskCategory.asksUser && stepRiskCategory != context.riskCategoryConfirmedForThisItem
                        && !progress.riskCategoriesAllowedForRestOfTask.contains(stepRiskCategory) {
                        confirmationNeeded = ("Routine step \(stepIndex + 1): \(stepDescription)", stepRiskCategory)
                    }
                }
                if let (reason, riskCategory) = confirmationNeeded {
                    switch await SafetyConfirmationFlow.askUser(
                        context.actionConfirmationRequest(reason: reason, riskCategory: riskCategory),
                        confirmationRequester: confirmationRequester, auditLogWriter: auditLogWriter,
                        riskCategoriesAllowedForRestOfTask: &progress.riskCategoriesAllowedForRestOfTask, abortSignal: abortSignal) {
                    case .allowed: break
                    case .declined: return finished(.skipped, TaskUserFacingMessages.itemActionDeclinedByUserSummary)
                    case .stopped: return stoppedByUser()
                    }
                }

                guard progress.actionsPerformed < itemActionBudget else {
                    return failedDeterministically(TaskUserFacingMessages.itemActionLimitReachedSummary)
                }
                try abortSignal.throwIfAborted()
                progress.actionsPerformed += 1
                if context.itemWasConfirmedByUser || step.requiresConfirmationEachItem
                    || SafetyGate.actionIsRiskyWithoutAnyGrant(agentAction, targetNode: resolvedNode, focusedNode: focusedNode,
                                                               targetApplicationBundleIdentifier: targetApplicationBundleIdentifier) {
                    progress.performedUserConfirmedAction = true
                }
                if case .typeText(_, let typedText, _, _) = agentAction { auditLogWriter.registerTypedTextForRedaction(typedText) }
                await observer.taskExecutionDidReportProgress(itemIdentifier: item.itemIdentifier, progressDescription: "Replaying: \(stepDescription)")
                auditLogWriter.append(eventKind: .replayStep, itemIdentifier: item.itemIdentifier, message: stepDescription,
                                      details: ["step": String(stepIndex + 1), "routine": routine.routineIdentifier])
                switch try await ForegroundAssistingActionPerformer.perform(
                    agentAction, actionBackend: actionBackend, confirmationRequester: confirmationRequester,
                    auditLogWriter: auditLogWriter, context: context.foregroundAssistContext,
                    riskCategoriesAllowedForRestOfTask: &progress.riskCategoriesAllowedForRestOfTask, abortSignal: abortSignal,
                    readinessGate: context.foregroundAssistReadinessGate) {
                case .performed:
                    break
                case .userDeclinedForegroundAssist:
                    return finished(.skipped, TaskUserFacingMessages.itemActionDeclinedByUserSummary)
                case .blockedByBackgroundOnly:
                    progress.failedDeterministically = true
                    return finished(.needsUser, TaskUserFacingMessages.itemNeedsForegroundSummary)
                case .userStoppedTask:
                    return stoppedByUser()
                }
                if ChecklistItemRetryPolicy.actionHasSideEffects(agentAction, targetNode: resolvedNode) { progress.performedSideEffectingAction = true }

                if let renderedExpectation {
                    let verdict = try await waitFor(renderedExpectation, timeoutSeconds: expectationTimeoutSeconds,
                                                    preActionSnapshot: preActionSnapshot)
                    if case .unsatisfied(let reasonForModel) = verdict { return fallback(atStep: stepIndex, reasonForModel) }
                } else {
                    try await Task.sleep(nanoseconds: stepSettleDelayNanoseconds)
                }
            } catch {
                if ClaudeToolResultBuilding.isAbort(error, abortSignal: abortSignal) { throw error }
                if (error as? ActionBackendError) == .secureFieldTypingDenied {
                    return failedDeterministically(ActionBackendError.secureFieldTypingDenied.messageForModel)
                }
                return fallback(atStep: stepIndex, (error as? RoutineTemplateError)?.message
                                ?? ClaudeToolResultBuilding.fencedMessageForModel(describing: error))
            }
        }

        do {
            if let completionEvidence = try routine.completionEvidence?.renderingParameters(item.parameters),
               case .unsatisfied(let reasonForModel) = try await waitFor(completionEvidence, timeoutSeconds: expectationTimeoutSeconds,
                                                                         preActionSnapshot: nil) {
                return fallback(atStep: routine.steps.count, reasonForModel)
            }
        } catch let templateError as RoutineTemplateError {
            return fallback(atStep: routine.steps.count, templateError.message)
        }
        return finished(.completed, "Replayed routine (\(routine.steps.count) steps).")
    }
}
