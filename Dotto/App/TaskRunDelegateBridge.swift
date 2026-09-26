import Foundation

/// The only object handed to Core for a run. Forwards executor callbacks only while its run is the controller's
/// current, un-aborted run; a stale run gets `.stopTask` for any confirmation it still asks for.
@MainActor
final class TaskRunDelegateBridge: UserConfirmationRequesting, TaskExecutionObserving, TaskExecutionInteractionHandling,
                                   ForegroundAssistReadinessGating {
    private weak var taskSessionController: TaskSessionController?
    private let runAbortSignal: TaskAbortSignal
    /// Shared by every task: whose app may come forward next.
    private let foregroundAssistTurnQueue: ForegroundAssistTurnQueue
    /// This run's place in that queue.
    private let foregroundAssistTurnOwnerIdentifier: String

    init(taskSessionController: TaskSessionController, runAbortSignal: TaskAbortSignal,
         foregroundAssistTurnQueue: ForegroundAssistTurnQueue, foregroundAssistTurnOwnerIdentifier: String) {
        self.taskSessionController = taskSessionController
        self.runAbortSignal = runAbortSignal
        self.foregroundAssistTurnQueue = foregroundAssistTurnQueue
        self.foregroundAssistTurnOwnerIdentifier = foregroundAssistTurnOwnerIdentifier
    }

    private var sessionControllerOfCurrentRun: TaskSessionController? {
        guard let taskSessionController,
              taskSessionController.currentAbortSignal === runAbortSignal,
              !runAbortSignal.isAborted else { return nil }
        return taskSessionController
    }

    func requestSafetyConfirmation(_ request: SafetyConfirmationRequest) async -> SafetyConfirmationAnswer {
        guard let sessionControllerOfCurrentRun else { return .stopTask }
        return await sessionControllerOfCurrentRun.requestSafetyConfirmation(request)
    }

    func taskExecutionDidStartItem(itemIdentifier: String) {
        sessionControllerOfCurrentRun?.taskExecutionDidStartItem(itemIdentifier: itemIdentifier)
    }

    func taskExecutionDidReportProgress(itemIdentifier: String, progressDescription: String) {
        sessionControllerOfCurrentRun?.taskExecutionDidReportProgress(itemIdentifier: itemIdentifier, progressDescription: progressDescription)
    }

    func taskExecutionDidFinishItem(itemIdentifier: String, runStatus: ChecklistItemRunStatus, resultSummary: String) {
        sessionControllerOfCurrentRun?.taskExecutionDidFinishItem(itemIdentifier: itemIdentifier, runStatus: runStatus,
                                                         resultSummary: resultSummary)
    }

    func requestItemFailureDecision(_ request: ChecklistItemFailureDecisionRequest) async -> ChecklistItemFailureDecision {
        guard let sessionControllerOfCurrentRun else { return .stopTask }
        return await sessionControllerOfCurrentRun.requestItemFailureDecision(request)
    }

    func taskExecutionDidReportCursorActivity(_ cursorActivityEvent: CursorActivityEvent) {
        sessionControllerOfCurrentRun?.taskExecutionDidReportCursorActivity(cursorActivityEvent)
    }

    func taskExecutionDidUpdateRoutine(_ routine: Routine, wasNewlyLearned: Bool) {
        sessionControllerOfCurrentRun?.taskExecutionDidUpdateRoutine(routine, wasNewlyLearned: wasNewlyLearned)
    }

    func taskExecutionDidUpdateMetrics(_ metrics: TaskRunMetrics) {
        sessionControllerOfCurrentRun?.taskExecutionDidUpdateMetrics(metrics)
    }

    // MARK: - ForegroundAssistReadinessGating

    /// A stale run never gets the go-ahead: unknown inputs count as "the user may be typing".
    func currentForegroundAssistReadinessInputs() -> ForegroundAssistReadinessInputs {
        guard let sessionControllerOfCurrentRun else {
            return ForegroundAssistReadinessInputs(secondsSinceLastRealUserInput: nil, secureEventInputIsEnabled: nil,
                                                   secureEventInputProcessIdentifier: nil)
        }
        return sessionControllerOfCurrentRun.currentForegroundAssistReadinessInputs()
    }

    func foregroundAssistIsWaitingForUser() {
        sessionControllerOfCurrentRun?.foregroundAssistIsWaitingForUser()
    }

    func runForegroundAssistCountdown(countdownSeconds: Double, abortSignal: TaskAbortSignal) async -> Bool {
        guard let sessionControllerOfCurrentRun else { return false }
        return await sessionControllerOfCurrentRun.runForegroundAssistCountdown(countdownSeconds: countdownSeconds, abortSignal: abortSignal)
    }

    func foregroundAssistPendingEnded() {
        sessionControllerOfCurrentRun?.foregroundAssistPendingEnded()
    }

    /// A stale run never gets a turn.
    func waitForForegroundAssistTurn(abortSignal: TaskAbortSignal) async -> Bool {
        guard sessionControllerOfCurrentRun != nil else { return false }
        return await foregroundAssistTurnQueue.waitForTurn(ownerIdentifier: foregroundAssistTurnOwnerIdentifier, abortSignal: abortSignal)
    }

    /// Always given back, also by a run that went stale while it held the turn: otherwise no other task could ever
    /// bring its app forward again.
    func foregroundAssistTurnEnded() {
        foregroundAssistTurnQueue.endTurn(ownerIdentifier: foregroundAssistTurnOwnerIdentifier)
    }
}
