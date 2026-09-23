import Foundation

struct ForegroundAssistContext: Sendable {
    var itemIdentifier: String
    var itemLabel: String
    var itemParameters: [ChecklistItemParameter]
    var targetApplicationName: String
    var riskCategoryConfirmedForThisItem: SafetyRiskCategory?
    var targetProcessIdentifier: Int32? = nil
    var readinessPolicy = ForegroundAssistReadinessPolicy()
    var focusPolicy: TaskFocusPolicy = .allowApprovedAssist

    func confirmationRequest(reason: String, riskCategory: SafetyRiskCategory) -> SafetyConfirmationRequest {
        SafetyConfirmationRequest(itemIdentifier: itemIdentifier, itemLabel: itemLabel, reason: reason, isActionLevel: true,
                                  riskCategory: riskCategory, itemParameters: itemParameters)
    }
}

enum ForegroundAssistingPerformResult: Equatable, Sendable {
    case performed(ActionOutcome)
    case userDeclinedForegroundAssist
    case userStoppedTask
    case blockedByBackgroundOnly
}

/// Runs an action in the background and, only when that input provably didn't land and bringing the app forward
/// could help, asks the user before retrying it with the app in front. Bringing an app forward is a safety
/// decision like any other: it needs its own `.bringingAppForward` confirmation or grant.
enum ForegroundAssistingActionPerformer {
    static func perform(_ action: AgentAction, actionBackend: ActionBackend,
                        confirmationRequester: UserConfirmationRequesting, auditLogWriter: AuditLogWriter,
                        context: ForegroundAssistContext,
                        riskCategoriesAllowedForRestOfTask: inout Set<SafetyRiskCategory>,
                        abortSignal: TaskAbortSignal,
                        readinessGate: ForegroundAssistReadinessGating? = nil) async throws -> ForegroundAssistingPerformResult {
        if context.focusPolicy == .backgroundOnly, BackgroundActionPolicy.requiresForeground(action, targetNode: nil) {
            auditLogWriter.append(eventKind: .safetyDecision, itemIdentifier: context.itemIdentifier,
                                  message: "foreground action blocked by background-only setting", details: [:])
            return .blockedByBackgroundOnly
        }
        // Uploads were confirmed under `.uploadingFiles`, whose card already says the app comes forward.
        if action.requiresForegroundAssist {
            switch try await waitUntilUserHasPaused(riskCategory: .uploadingFiles, confirmationRequester: confirmationRequester,
                                                    auditLogWriter: auditLogWriter, context: context,
                                                    riskCategoriesAllowedForRestOfTask: &riskCategoriesAllowedForRestOfTask,
                                                    abortSignal: abortSignal, readinessGate: readinessGate) {
            case .proceed: break
            case .declined: return .userDeclinedForegroundAssist
            case .stopped: return .userStoppedTask
            }
            return .performed(try await performWithAudit(action, actionBackend: actionBackend, auditLogWriter: auditLogWriter,
                                                         context: context, abortSignal: abortSignal))
        }
        let backgroundFailureDetail: String
        do {
            return .performed(try await actionBackend.perform(action, abortSignal: abortSignal))
        } catch ActionBackendError.inputNotDelivered(let detail, foregroundAssistMayHelp: true) {
            backgroundFailureDetail = detail
        }

        if !context.focusPolicy.allowsForegroundAssist {
            auditLogWriter.append(eventKind: .safetyDecision, itemIdentifier: context.itemIdentifier,
                                  message: "foreground assist blocked by background-only setting",
                                  details: ["background_detail": backgroundFailureDetail])
            return .blockedByBackgroundOnly
        }

        let failedActionDescription = AgentActionDescriptions.foregroundAssistActionDescription(of: action)
        switch SafetyGate.evaluateForegroundAssist(failedActionDescription: failedActionDescription,
                                                   targetApplicationName: context.targetApplicationName,
                                                   riskCategoryConfirmedForThisItem: context.riskCategoryConfirmedForThisItem,
                                                   riskCategoriesAllowedForRestOfTask: riskCategoriesAllowedForRestOfTask) {
        case .allow:
            break
        case .deny(let reason):
            // Fails closed: a bring-forward the gate refuses is handled like the user declining it.
            auditLogWriter.append(eventKind: .safetyDecision, itemIdentifier: context.itemIdentifier,
                                  message: "bring forward denied", details: ["reason": reason, "background_detail": backgroundFailureDetail])
            return .userDeclinedForegroundAssist
        case .requireUserConfirmation(let reason, let riskCategory):
            let backgroundAuditDetails = ["background_detail": backgroundFailureDetail]
            auditLogWriter.append(eventKind: .safetyDecision, itemIdentifier: context.itemIdentifier, message: "confirmation required",
                                  details: ["reason": reason, "risk_category": riskCategory.rawValue].merging(backgroundAuditDetails) { $1 })
            switch await SafetyConfirmationFlow.askUser(
                context.confirmationRequest(reason: reason, riskCategory: riskCategory), confirmationRequester: confirmationRequester,
                auditLogWriter: auditLogWriter, additionalAuditDetails: backgroundAuditDetails,
                riskCategoriesAllowedForRestOfTask: &riskCategoriesAllowedForRestOfTask, abortSignal: abortSignal) {
            case .allowed: break
            case .declined: return .userDeclinedForegroundAssist
            case .stopped: return .userStoppedTask
            }
        }
        try abortSignal.throwIfAborted()
        switch try await waitUntilUserHasPaused(riskCategory: .bringingAppForward, confirmationRequester: confirmationRequester,
                                                auditLogWriter: auditLogWriter, context: context,
                                                riskCategoriesAllowedForRestOfTask: &riskCategoriesAllowedForRestOfTask,
                                                abortSignal: abortSignal, readinessGate: readinessGate) {
        case .proceed: break
        case .declined: return .userDeclinedForegroundAssist
        case .stopped: return .userStoppedTask
        }
        return .performed(try await performWithAudit(action, actionBackend: actionBackend, auditLogWriter: auditLogWriter,
                                                     context: context, abortSignal: abortSignal))
    }

    private enum ReadinessWaitOutcome { case proceed, declined, stopped }

    /// Waits until the user has paused (ForegroundAssistReadinessPolicy), shows the countdown, and re-checks right
    /// before the app comes forward. Waiting in vain asks the user again, whatever grant is in effect.
    private static func waitUntilUserHasPaused(riskCategory: SafetyRiskCategory, confirmationRequester: UserConfirmationRequesting,
                                               auditLogWriter: AuditLogWriter, context: ForegroundAssistContext,
                                               riskCategoriesAllowedForRestOfTask: inout Set<SafetyRiskCategory>,
                                               abortSignal: TaskAbortSignal,
                                               readinessGate: ForegroundAssistReadinessGating?) async throws -> ReadinessWaitOutcome {
        guard let readinessGate else { return .proceed }
        let readinessPolicy = context.readinessPolicy
        func currentReadiness() async -> ForegroundAssistReadiness {
            readinessPolicy.readiness(for: await readinessGate.currentForegroundAssistReadinessInputs(),
                                      targetProcessIdentifier: context.targetProcessIdentifier)
        }
        do {
            while true {
                var readiness = await currentReadiness()
                var secondsWaited: TimeInterval = 0
                if readiness != .ready { await readinessGate.foregroundAssistIsWaitingForUser() }
                while readiness != .ready && secondsWaited < readinessPolicy.maximumWaitSeconds {
                    try abortSignal.throwIfAborted()
                    try await Task.sleep(nanoseconds: UInt64(readinessPolicy.pollIntervalSeconds * 1_000_000_000))
                    secondsWaited += readinessPolicy.pollIntervalSeconds
                    readiness = await currentReadiness()
                }
                try abortSignal.throwIfAborted()
                if readiness == .ready {
                    let countdownFinished = await readinessGate.runForegroundAssistCountdown(
                        countdownSeconds: readinessPolicy.countdownSeconds, abortSignal: abortSignal)
                    try abortSignal.throwIfAborted()
                    guard countdownFinished else {
                        await readinessGate.foregroundAssistPendingEnded()
                        auditLogWriter.append(eventKind: .userConfirmation, itemIdentifier: context.itemIdentifier,
                                              message: "bring forward cancelled during the countdown", details: [:])
                        return .declined
                    }
                    // The user may have started typing during the countdown.
                    if await currentReadiness() == .ready {
                        await readinessGate.foregroundAssistPendingEnded()
                        return .proceed
                    }
                    continue
                }

                await readinessGate.foregroundAssistPendingEnded()
                let reason = ForegroundAssistReadinessPolicy.reaskReason(after: readiness, targetApplicationName: context.targetApplicationName)
                auditLogWriter.append(eventKind: .safetyDecision, itemIdentifier: context.itemIdentifier,
                                      message: "confirmation required", details: ["reason": reason, "risk_category": riskCategory.rawValue])
                switch await SafetyConfirmationFlow.askUser(
                    context.confirmationRequest(reason: reason, riskCategory: riskCategory), confirmationRequester: confirmationRequester,
                    auditLogWriter: auditLogWriter, riskCategoriesAllowedForRestOfTask: &riskCategoriesAllowedForRestOfTask,
                    abortSignal: abortSignal) {
                case .allowed: continue
                case .declined: return .declined
                case .stopped: return .stopped
                }
            }
        } catch {
            await readinessGate.foregroundAssistPendingEnded()
            throw error
        }
    }

    /// The audit names the action by its summary only, never typed text or full file paths.
    private static func performWithAudit(_ action: AgentAction, actionBackend: ActionBackend, auditLogWriter: AuditLogWriter,
                                         context: ForegroundAssistContext, abortSignal: TaskAbortSignal) async throws -> ActionOutcome {
        let actionSummary = AgentActionDescriptions.foregroundAssistActionDescription(of: action)
        auditLogWriter.append(eventKind: .foregroundAssist, itemIdentifier: context.itemIdentifier, message: "assist started",
                              details: ["action": actionSummary, "application": context.targetApplicationName])
        do {
            var actionOutcome = try await actionBackend.performWithForegroundAssist(action, abortSignal: abortSignal)
            actionOutcome.usedForegroundAssist = true
            auditLogWriter.append(eventKind: .foregroundAssist, itemIdentifier: context.itemIdentifier, message: "assist finished",
                                  details: ["action": actionSummary])
            return actionOutcome
        } catch {
            auditLogWriter.append(eventKind: .foregroundAssist, itemIdentifier: context.itemIdentifier, message: "assist failed",
                                  details: ["action": actionSummary, "error": ClaudeToolResultBuilding.messageForModel(describing: error)])
            throw error
        }
    }
}
