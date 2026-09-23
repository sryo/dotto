import Foundation

enum TaskSessionState: Equatable, Sendable {
    case idle
    case planning(command: String)
    /// The planner asked the user something (or, when the question takes no reply, said why it can't plan).
    case plannerNeedsInput(command: String, question: PlannerQuestion)
    case awaitingApproval(checklist: Checklist)
    case executing(checklist: Checklist, currentItemIdentifier: String?)
    case awaitingSafetyConfirmation(checklist: Checklist, request: SafetyConfirmationRequest)
    case finished(checklist: Checklist, summary: TaskRunSummary)
    case failed(checklist: Checklist?, reason: String)
    case aborted(checklist: Checklist?)
    case paused(checklist: Checklist, currentItemIdentifier: String?, reason: TaskPauseReason)
    case awaitingItemFailureDecision(checklist: Checklist, request: ChecklistItemFailureDecisionRequest)
    case demonstrating(checklist: Checklist, itemIdentifier: String, isCompilingRoutine: Bool)

    /// True while Dotto is planning, running, or waiting on the user mid-run. Not while demonstrating: then the user
    /// is the one working.
    var isBusy: Bool {
        switch self {
        case .planning, .executing, .awaitingSafetyConfirmation, .paused, .awaitingItemFailureDecision: return true
        default: return false
        }
    }

    var currentChecklist: Checklist? {
        switch self {
        case .idle, .planning, .plannerNeedsInput: return nil
        case .awaitingApproval(let checklist), .executing(let checklist, _), .awaitingSafetyConfirmation(let checklist, _), .finished(let checklist, _):
            return checklist
        case .paused(let checklist, _, _), .awaitingItemFailureDecision(let checklist, _), .demonstrating(let checklist, _, _):
            return checklist
        case .failed(let checklist, _), .aborted(let checklist):
            return checklist
        }
    }
}

enum TaskSessionEvent: Equatable, Sendable {
    case commandSubmitted(String)
    case checklistProduced(Checklist)
    case plannerAskedForInput(PlannerQuestion)
    /// The user answered the planner's question; planning carries on in the same conversation.
    case plannerReplySent
    case planningFailed(String)
    case checklistEdited(Checklist)
    case checklistApproved(Checklist)
    case itemStarted(itemIdentifier: String)
    case itemProgressed(itemIdentifier: String)
    case itemFinished(itemIdentifier: String, runStatus: ChecklistItemRunStatus, resultSummary: String)
    case safetyConfirmationRequested(SafetyConfirmationRequest)
    case safetyConfirmationAnswered
    case executionFinished(TaskRunSummary)
    case abortRequested
    case dismissed
    case pauseRequested(TaskPauseReason)
    case resumeRequested
    case itemFailureDecisionRequested(ChecklistItemFailureDecisionRequest)
    case itemFailureDecisionAnswered
    case demonstrationStarted(itemIdentifier: String)
    case demonstrationRecordingStopped
    /// Carries the plan with the demonstrated item marked completed.
    case demonstrationFinished(Checklist)
    case demonstrationCancelled
    /// "Run on a list": a plan built from a saved routine, which skips planning.
    case routineChecklistPrepared(Checklist)
}

enum TaskSessionStateMachine {
    /// nil = event is invalid in this state; callers ignore it (e.g. a late itemFinished after abort).
    static func nextState(from currentState: TaskSessionState, on event: TaskSessionEvent) -> TaskSessionState? {
        switch (currentState, event) {
        case (.idle, .commandSubmitted(let command)), (.plannerNeedsInput, .commandSubmitted(let command)),
             (.finished, .commandSubmitted(let command)), (.failed, .commandSubmitted(let command)),
             (.aborted, .commandSubmitted(let command)):
            let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedCommand.isEmpty ? nil : .planning(command: trimmedCommand)

        case (.planning, .checklistProduced(let checklist)):
            return .awaitingApproval(checklist: checklist)
        case (.planning(let command), .plannerAskedForInput(let plannerQuestion)):
            return .plannerNeedsInput(command: command, question: plannerQuestion)
        case (.plannerNeedsInput(let command, let plannerQuestion), .plannerReplySent):
            return plannerQuestion.acceptsReply ? .planning(command: command) : nil
        case (.planning, .planningFailed(let reason)):
            return .failed(checklist: nil, reason: reason)
        case (.planning, .abortRequested):
            return .aborted(checklist: nil)

        case (.awaitingApproval, .checklistEdited(let editedChecklist)):
            return .awaitingApproval(checklist: editedChecklist)
        case (.awaitingApproval, .checklistApproved(let approvedChecklist)):
            guard !approvedChecklist.includedItems.isEmpty else { return nil }
            var checklistWithExcludedItemsSkipped = approvedChecklist
            for itemIndex in checklistWithExcludedItemsSkipped.items.indices where !checklistWithExcludedItemsSkipped.items[itemIndex].isIncludedByUser {
                checklistWithExcludedItemsSkipped.items[itemIndex].runStatus = .skipped
            }
            return .executing(checklist: checklistWithExcludedItemsSkipped, currentItemIdentifier: nil)

        case (.executing(let checklist, _), .itemStarted(let itemIdentifier)):
            guard checklistContainsItem(checklist, itemIdentifier: itemIdentifier) else { return nil }
            let updatedChecklist = checklist.updatingItem(withIdentifier: itemIdentifier) { $0.runStatus = .running }
            return .executing(checklist: updatedChecklist, currentItemIdentifier: itemIdentifier)
        case (.executing(let checklist, _), .itemProgressed(let itemIdentifier)):
            guard checklistContainsItem(checklist, itemIdentifier: itemIdentifier) else { return nil }
            return .executing(checklist: checklist, currentItemIdentifier: itemIdentifier)
        case (.executing(let checklist, _), .itemFinished(let itemIdentifier, let runStatus, let resultSummary)):
            guard checklistContainsItem(checklist, itemIdentifier: itemIdentifier) else { return nil }
            let updatedChecklist = checklist.updatingItem(withIdentifier: itemIdentifier) { item in
                item.runStatus = runStatus
                item.resultSummary = resultSummary
            }
            return .executing(checklist: updatedChecklist, currentItemIdentifier: nil)
        case (.executing(let checklist, _), .safetyConfirmationRequested(let confirmationRequest)):
            return .awaitingSafetyConfirmation(checklist: checklist, request: confirmationRequest)
        case (.awaitingSafetyConfirmation(let checklist, let confirmationRequest), .safetyConfirmationAnswered):
            return .executing(checklist: checklist, currentItemIdentifier: confirmationRequest.itemIdentifier)
        case (.executing(let checklist, _), .abortRequested), (.awaitingSafetyConfirmation(let checklist, _), .abortRequested),
             (.paused(let checklist, _, _), .abortRequested), (.awaitingItemFailureDecision(let checklist, _), .abortRequested):
            var abortedChecklist = checklist
            for itemIndex in abortedChecklist.items.indices where abortedChecklist.items[itemIndex].runStatus == .running {
                abortedChecklist.items[itemIndex].runStatus = .skipped
            }
            return .aborted(checklist: abortedChecklist)
        case (.executing(let checklist, _), .executionFinished(let runSummary)), (.paused(let checklist, _, _), .executionFinished(let runSummary)):
            return .finished(checklist: checklist, summary: runSummary)

        case (.executing(let checklist, let currentItemIdentifier), .pauseRequested(let pauseReason)):
            return .paused(checklist: checklist, currentItemIdentifier: currentItemIdentifier, reason: pauseReason)
        case (.paused(let checklist, let currentItemIdentifier, _), .resumeRequested):
            return .executing(checklist: checklist, currentItemIdentifier: currentItemIdentifier)
        // The executor only notices a pause at its next checkpoint, so item events keep arriving while paused.
        case (.paused(let checklist, let currentItemIdentifier, let pauseReason), .itemStarted),
             (.paused(let checklist, let currentItemIdentifier, let pauseReason), .itemProgressed),
             (.paused(let checklist, let currentItemIdentifier, let pauseReason), .itemFinished):
            let executingState = TaskSessionState.executing(checklist: checklist, currentItemIdentifier: currentItemIdentifier)
            guard case .executing(let updatedChecklist, let updatedItemIdentifier)? = nextState(from: executingState, on: event) else { return nil }
            return .paused(checklist: updatedChecklist, currentItemIdentifier: updatedItemIdentifier, reason: pauseReason)
        // A request raised just after the last checkpoint must still reach the user, or its continuation would hang.
        case (.paused(let checklist, _, _), .safetyConfirmationRequested(let confirmationRequest)):
            return .awaitingSafetyConfirmation(checklist: checklist, request: confirmationRequest)
        case (.executing(let checklist, _), .itemFailureDecisionRequested(let decisionRequest)),
             (.paused(let checklist, _, _), .itemFailureDecisionRequested(let decisionRequest)):
            return .awaitingItemFailureDecision(checklist: checklist, request: decisionRequest)
        case (.awaitingItemFailureDecision(let checklist, let decisionRequest), .itemFailureDecisionAnswered):
            return .executing(checklist: checklist, currentItemIdentifier: decisionRequest.itemIdentifier)

        case (.awaitingApproval(let checklist), .demonstrationStarted(let itemIdentifier)):
            let demonstrableItem = checklist.items.first { $0.itemIdentifier == itemIdentifier }
            guard let demonstrableItem, demonstrableItem.isIncludedByUser, demonstrableItem.runStatus == .pending else { return nil }
            return .demonstrating(checklist: checklist, itemIdentifier: itemIdentifier, isCompilingRoutine: false)
        case (.demonstrating(let checklist, let itemIdentifier, false), .demonstrationRecordingStopped):
            return .demonstrating(checklist: checklist, itemIdentifier: itemIdentifier, isCompilingRoutine: true)
        case (.demonstrating(_, _, true), .demonstrationFinished(let checklistAfterDemonstration)):
            return .awaitingApproval(checklist: checklistAfterDemonstration)
        case (.demonstrating(let checklist, _, _), .demonstrationCancelled):
            return .awaitingApproval(checklist: checklist)

        case (.idle, .routineChecklistPrepared(let checklist)), (.plannerNeedsInput, .routineChecklistPrepared(let checklist)),
             (.awaitingApproval, .routineChecklistPrepared(let checklist)), (.finished, .routineChecklistPrepared(let checklist)),
             (.failed, .routineChecklistPrepared(let checklist)), (.aborted, .routineChecklistPrepared(let checklist)):
            return checklist.items.isEmpty ? nil : .awaitingApproval(checklist: checklist)

        case (.awaitingApproval, .dismissed), (.plannerNeedsInput, .dismissed), (.finished, .dismissed),
             (.failed, .dismissed), (.aborted, .dismissed), (.demonstrating, .dismissed):
            return .idle

        default:
            return nil
        }
    }

    private static func checklistContainsItem(_ checklist: Checklist, itemIdentifier: String) -> Bool {
        checklist.items.contains { $0.itemIdentifier == itemIdentifier }
    }
}
