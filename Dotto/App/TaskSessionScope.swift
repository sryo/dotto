import AppKit
import Combine

/// The coordinator as one task's own panels see it. Reads (`scope.sessionState`, `scope.plannerConversationTranscript`,
/// and every other coordinator property) are answered for this scope's session, and every action a panel button takes
/// runs on this session, so with several tasks each checklist only ever shows and changes its own task.
@dynamicMemberLookup
@MainActor
final class TaskSessionScope: ObservableObject {
    let taskSessionController: TaskSessionController
    let session: TaskSession
    private var controllerChangeSubscription: AnyCancellable?

    init(taskSessionController: TaskSessionController, session: TaskSession) {
        self.taskSessionController = taskSessionController
        self.session = session
        // The coordinator already republishes every session's changes.
        controllerChangeSubscription = taskSessionController.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    subscript<Value>(dynamicMember keyPath: KeyPath<TaskSessionController, Value>) -> Value {
        taskSessionController.withSession(session) { taskSessionController[keyPath: keyPath] }
    }

    private func inSession(_ action: (TaskSessionController) -> Void) {
        taskSessionController.withSession(session) { action(taskSessionController) }
    }

    // MARK: - Actions

    func checklistPanelAnchor() -> AttachedPanelAnchor {
        taskSessionController.withSession(session) { taskSessionController.checklistPanelAnchor() }
    }

    func approveChecklistAndRun() { inSession { $0.approveChecklistAndRun() } }
    func cancelChecklist() { inSession { $0.cancelChecklist() } }
    func setItemIncluded(itemIdentifier: String, isIncluded: Bool) {
        inSession { $0.setItemIncluded(itemIdentifier: itemIdentifier, isIncluded: isIncluded) }
    }
    func editItemLabel(itemIdentifier: String, newLabel: String) {
        inSession { $0.editItemLabel(itemIdentifier: itemIdentifier, newLabel: newLabel) }
    }
    func sendPlannerReply(_ replyText: String) { inSession { $0.sendPlannerReply(replyText) } }
    /// The pill that opens submits into this session, so the session is focused (outside any `withSession`) first.
    func reopenCommandBarWithPreviousCommand() {
        taskSessionController.focus(session)
        taskSessionController.reopenCommandBarWithPreviousCommand()
    }
    func replanUsingCursorInstead() { inSession { $0.replanUsingCursorInstead() } }
    func planAgainAfterDirectRouteValidationFailure() { inSession { $0.planAgainAfterDirectRouteValidationFailure() } }
    func revealDirectRouteScopeInFinder() { inSession { $0.revealDirectRouteScopeInFinder() } }
    func undoDirectRouteTask(journalIdentifier: String) { inSession { $0.undoDirectRouteTask(journalIdentifier: journalIdentifier) } }

    func pauseTask() { inSession { $0.pauseTask() } }
    func resumeTask() { inSession { $0.resumeTask() } }
    func skipCurrentItem() { inSession { $0.skipCurrentItem() } }
    func stopTask() { inSession { $0.stopTask() } }
    func dismissFinishedTask() { inSession { $0.dismissFinishedTask() } }
    func answerPendingSafetyConfirmation(_ answer: SafetyConfirmationAnswer) { inSession { $0.answerPendingSafetyConfirmation(answer) } }
    func answerPendingItemFailureDecision(_ decision: ChecklistItemFailureDecision) {
        inSession { $0.answerPendingItemFailureDecision(decision) }
    }

    func startTeachingFirstItem() { inSession { $0.startTeachingFirstItem() } }
    func finishTeaching() { inSession { $0.finishTeaching() } }
    func cancelTeaching() { inSession { $0.cancelTeaching() } }
    func saveTaughtRoutine() { inSession { $0.saveTaughtRoutine() } }
    func discardTaughtRoutine() { inSession { $0.discardTaughtRoutine() } }
    func saveLearnedRoutine() { inSession { $0.saveLearnedRoutine() } }
    func discardLearnedRoutine() { inSession { $0.discardLearnedRoutine() } }
    func openCurrentAuditLog() { inSession { $0.openCurrentAuditLog() } }
    func showChecklist() { inSession { $0.showChecklist() } }
}
