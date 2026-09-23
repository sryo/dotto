import AppKit

/// The run's questions to the user: safety confirmations and item failure decisions. Each waits on its
/// PendingUserAnswer until the user answers from the checklist card, the cursor pill, the live view or a notification.
extension TaskSessionController {
    // MARK: - Safety confirmation

    func requestSafetyConfirmation(_ request: SafetyConfirmationRequest) async -> SafetyConfirmationAnswer {
        // The executor is sequential, so a second concurrent request means something is
        // wrong; declining it is the conservative answer.
        guard !pendingSafetyConfirmation.isPending else { return .skipItem }
        guard currentAbortSignal?.isAborted != true else { return .stopTask }
        leavePausedState()
        guard apply(.safetyConfirmationRequested(request)) else { return .stopTask }

        statusLine = "Waiting for your confirmation"
        showChecklistPanelIfCursorCannotCarryIt()
        cursorController.handle(.confirmationRequested(request))
        return await pendingSafetyConfirmation.waitForAnswer()
    }

    func answerPendingSafetyConfirmation(_ answer: SafetyConfirmationAnswer) {
        guard pendingSafetyConfirmation.isPending else { return }
        // Same path as the Stop button, so the run ends as `aborted` and its late events are dropped by the run proxy.
        if answer == .stopTask {
            stopTask()
            return
        }
        noteUserAnsweredThisAppPanel()
        apply(.safetyConfirmationAnswered)
        cursorController.handle(.confirmationAnswered)
        statusLine = TaskUserFacingMessages.continuingStatusLine
        pendingSafetyConfirmation.resume(with: answer)
    }

    // MARK: - Item failure decision

    func requestItemFailureDecision(_ request: ChecklistItemFailureDecisionRequest) async -> ChecklistItemFailureDecision {
        guard !pendingItemFailureDecision.isPending else { return .skipItem }
        guard currentAbortSignal?.isAborted != true else { return .stopTask }
        leavePausedState()
        guard apply(.itemFailureDecisionRequested(request)) else { return .stopTask }

        statusLine = "An item failed — Retry, Skip or Stop?"
        showChecklistPanelIfCursorCannotCarryIt()
        cursorController.handle(.itemFailureDecisionRequested(request))
        return await pendingItemFailureDecision.waitForAnswer()
    }

    func answerPendingItemFailureDecision(_ decision: ChecklistItemFailureDecision) {
        guard pendingItemFailureDecision.isPending else { return }
        if decision == .stopTask {
            stopTask()
            return
        }
        noteUserAnsweredThisAppPanel()
        apply(.itemFailureDecisionAnswered)
        cursorController.handle(.confirmationAnswered)
        statusLine = decision == .retry ? "Retrying…" : TaskUserFacingMessages.skippingThisItemStatusLine
        pendingItemFailureDecision.resume(with: decision)
    }
}
