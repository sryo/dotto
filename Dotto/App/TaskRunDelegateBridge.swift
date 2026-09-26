import Foundation

/// The only object handed to Core for a run. Forwards executor callbacks into its own task's session, and only while
/// its run is that session's current, un-aborted run; a stale run gets `.stopTask` for any confirmation it still asks
/// for.
@MainActor
final class TaskRunDelegateBridge: UserConfirmationRequesting, TaskExecutionObserving, TaskExecutionInteractionHandling,
                                   ForegroundAssistReadinessGating {
    private weak var taskSessionController: TaskSessionController?
    private weak var session: TaskSession?
    private let runAbortSignal: TaskAbortSignal
    /// Shared by every task: whose app may come forward next.
    private let foregroundAssistTurnQueue: ForegroundAssistTurnQueue
    /// This run's place in that queue.
    private let foregroundAssistTurnOwnerIdentifier: String

    init(taskSessionController: TaskSessionController, session: TaskSession, runAbortSignal: TaskAbortSignal,
         foregroundAssistTurnQueue: ForegroundAssistTurnQueue) {
        self.taskSessionController = taskSessionController
        self.session = session
        self.runAbortSignal = runAbortSignal
        self.foregroundAssistTurnQueue = foregroundAssistTurnQueue
        self.foregroundAssistTurnOwnerIdentifier = session.sessionIdentifier
    }

    private var controllerAndSessionOfCurrentRun: (controller: TaskSessionController, session: TaskSession)? {
        guard let taskSessionController, let session,
              session.currentAbortSignal === runAbortSignal,
              !runAbortSignal.isAborted else { return nil }
        return (taskSessionController, session)
    }

    /// Runs `body` on this run's session, if the run is still current.
    private func inSessionOfCurrentRun(_ body: (TaskSessionController) -> Void) {
        guard let (controller, session) = controllerAndSessionOfCurrentRun else { return }
        controller.withSession(session) { body(controller) }
    }

    func requestSafetyConfirmation(_ request: SafetyConfirmationRequest) async -> SafetyConfirmationAnswer {
        guard let (controller, session) = controllerAndSessionOfCurrentRun else { return .stopTask }
        return await controller.requestSafetyConfirmation(request, in: session)
    }

    func taskExecutionDidStartItem(itemIdentifier: String) {
        inSessionOfCurrentRun { $0.taskExecutionDidStartItem(itemIdentifier: itemIdentifier) }
    }

    func taskExecutionDidReportProgress(itemIdentifier: String, progressDescription: String) {
        inSessionOfCurrentRun { $0.taskExecutionDidReportProgress(itemIdentifier: itemIdentifier, progressDescription: progressDescription) }
    }

    func taskExecutionDidFinishItem(itemIdentifier: String, runStatus: ChecklistItemRunStatus, resultSummary: String) {
        inSessionOfCurrentRun {
            $0.taskExecutionDidFinishItem(itemIdentifier: itemIdentifier, runStatus: runStatus, resultSummary: resultSummary)
        }
    }

    func requestItemFailureDecision(_ request: ChecklistItemFailureDecisionRequest) async -> ChecklistItemFailureDecision {
        guard let (controller, session) = controllerAndSessionOfCurrentRun else { return .stopTask }
        return await controller.requestItemFailureDecision(request, in: session)
    }

    func taskExecutionDidReportCursorActivity(_ cursorActivityEvent: CursorActivityEvent) {
        inSessionOfCurrentRun { $0.taskExecutionDidReportCursorActivity(cursorActivityEvent) }
    }

    func taskExecutionDidUpdateRoutine(_ routine: Routine, wasNewlyLearned: Bool) {
        inSessionOfCurrentRun { $0.taskExecutionDidUpdateRoutine(routine, wasNewlyLearned: wasNewlyLearned) }
    }

    func taskExecutionDidUpdateMetrics(_ metrics: TaskRunMetrics) {
        inSessionOfCurrentRun { $0.taskExecutionDidUpdateMetrics(metrics) }
    }

    // MARK: - ForegroundAssistReadinessGating

    /// A stale run never gets the go-ahead: unknown inputs count as "the user may be typing".
    func currentForegroundAssistReadinessInputs() -> ForegroundAssistReadinessInputs {
        guard let (controller, _) = controllerAndSessionOfCurrentRun else {
            return ForegroundAssistReadinessInputs(secondsSinceLastRealUserInput: nil, secureEventInputIsEnabled: nil,
                                                   secureEventInputProcessIdentifier: nil)
        }
        return controller.currentForegroundAssistReadinessInputs()
    }

    func foregroundAssistIsWaitingForUser() {
        inSessionOfCurrentRun { $0.foregroundAssistIsWaitingForUser() }
    }

    func runForegroundAssistCountdown(countdownSeconds: Double, abortSignal: TaskAbortSignal) async -> Bool {
        guard let (controller, session) = controllerAndSessionOfCurrentRun else { return false }
        return await controller.runForegroundAssistCountdown(countdownSeconds: countdownSeconds, abortSignal: abortSignal, in: session)
    }

    func foregroundAssistPendingEnded() {
        inSessionOfCurrentRun { $0.foregroundAssistPendingEnded() }
    }

    /// A stale run never gets a turn.
    func waitForForegroundAssistTurn(abortSignal: TaskAbortSignal) async -> Bool {
        guard controllerAndSessionOfCurrentRun != nil else { return false }
        return await foregroundAssistTurnQueue.waitForTurn(ownerIdentifier: foregroundAssistTurnOwnerIdentifier, abortSignal: abortSignal)
    }

    /// Always given back, also by a run that went stale while it held the turn: otherwise no other task could ever
    /// bring its app forward again.
    func foregroundAssistTurnEnded() {
        foregroundAssistTurnQueue.endTurn(ownerIdentifier: foregroundAssistTurnOwnerIdentifier)
    }
}
