import Foundation
import CoreGraphics

@MainActor final class ScriptedConfirmationRequester: UserConfirmationRequesting {
    var scriptedAnswers: [SafetyConfirmationAnswer]
    var receivedRequests: [SafetyConfirmationRequest] = []

    nonisolated init(scriptedAnswers: [SafetyConfirmationAnswer]) { self.scriptedAnswers = scriptedAnswers }

    func requestSafetyConfirmation(_ request: SafetyConfirmationRequest) async -> SafetyConfirmationAnswer {
        receivedRequests.append(request)
        return scriptedAnswers.isEmpty ? .allowOnce : scriptedAnswers.removeFirst()
    }
}

@MainActor final class RecordingExecutionObserver: TaskExecutionObserving {
    var startedItemIdentifiers: [String] = []
    var finishedItems: [(itemIdentifier: String, runStatus: ChecklistItemRunStatus)] = []
    var reportedCursorActivityEvents: [CursorActivityEvent] = []

    nonisolated init() {}

    func taskExecutionDidStartItem(itemIdentifier: String) { startedItemIdentifiers.append(itemIdentifier) }
    func taskExecutionDidReportProgress(itemIdentifier: String, progressDescription: String) {}
    func taskExecutionDidFinishItem(itemIdentifier: String, runStatus: ChecklistItemRunStatus, resultSummary: String) {
        finishedItems.append((itemIdentifier, runStatus))
    }
    func taskExecutionDidReportCursorActivity(_ cursorActivityEvent: CursorActivityEvent) {
        reportedCursorActivityEvents.append(cursorActivityEvent)
    }
}

@MainActor final class ScriptedInteractionHandler: TaskExecutionInteractionHandling {
    var scriptedDecisions: [ChecklistItemFailureDecision]
    var receivedDecisionRequests: [ChecklistItemFailureDecisionRequest] = []
    var updatedRoutines: [(routine: Routine, wasNewlyLearned: Bool)] = []

    nonisolated init(scriptedDecisions: [ChecklistItemFailureDecision] = []) { self.scriptedDecisions = scriptedDecisions }

    func requestItemFailureDecision(_ request: ChecklistItemFailureDecisionRequest) async -> ChecklistItemFailureDecision {
        receivedDecisionRequests.append(request)
        return scriptedDecisions.isEmpty ? .skipItem : scriptedDecisions.removeFirst()
    }
    func taskExecutionDidUpdateRoutine(_ routine: Routine, wasNewlyLearned: Bool) { updatedRoutines.append((routine, wasNewlyLearned)) }
    func taskExecutionDidUpdateMetrics(_ metrics: TaskRunMetrics) {}
}

/// Hands out scripted readiness inputs (the last one repeats) and records what the pill was told.
@MainActor final class ScriptedForegroundAssistReadinessGate: ForegroundAssistReadinessGating {
    var scriptedInputs: [ForegroundAssistReadinessInputs]
    var countdownResults: [Bool]
    var recordedCalls: [String] = []

    nonisolated static let idleInputs = ForegroundAssistReadinessInputs(secondsSinceLastRealUserInput: 5, secureEventInputIsEnabled: false,
                                                            secureEventInputProcessIdentifier: nil)
    nonisolated static let typingInputs = ForegroundAssistReadinessInputs(secondsSinceLastRealUserInput: 0.2, secureEventInputIsEnabled: false,
                                                              secureEventInputProcessIdentifier: nil)

    nonisolated init(scriptedInputs: [ForegroundAssistReadinessInputs], countdownResults: [Bool] = []) {
        self.scriptedInputs = scriptedInputs
        self.countdownResults = countdownResults
    }

    func currentForegroundAssistReadinessInputs() -> ForegroundAssistReadinessInputs {
        recordedCalls.append("inputs")
        return scriptedInputs.count > 1 ? scriptedInputs.removeFirst() : scriptedInputs[0]
    }
    func foregroundAssistIsWaitingForUser() { recordedCalls.append("waiting") }
    func runForegroundAssistCountdown(countdownSeconds: Double, abortSignal: TaskAbortSignal) async -> Bool {
        recordedCalls.append("countdown")
        return countdownResults.isEmpty ? true : countdownResults.removeFirst()
    }
    func foregroundAssistPendingEnded() { recordedCalls.append("ended") }

    /// Kept apart from `recordedCalls`: "turn" when the turn was asked for, "turnEnded" when it was given back.
    var turnCalls: [String] = []
    /// False plays a task stopped while it waited in the queue.
    var grantsTurn = true
    /// How many readiness-input reads had happened when the turn was granted.
    var inputReadsBeforeTurn: Int?
    func waitForForegroundAssistTurn(abortSignal: TaskAbortSignal) async -> Bool {
        turnCalls.append("turn")
        inputReadsBeforeTurn = recordedCalls.filter { $0 == "inputs" }.count
        return grantsTurn
    }
    func foregroundAssistTurnEnded() { turnCalls.append("turnEnded") }
}
