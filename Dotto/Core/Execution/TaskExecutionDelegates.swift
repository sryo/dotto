import Foundation
import CoreGraphics

@MainActor protocol CursorPresenting: AnyObject {
    func handle(_ cursorActivityEvent: CursorActivityEvent)
    /// Returns on arrival (≤ the flight's duration), or at once when hidden or cancelled; the caller fires input afterwards.
    func flyCursor(toWindowRelativePoint windowRelativePoint: CGPoint, in targetWindow: TargetWindowReference,
                   actionKind: CursorActionKind) async
    func cancelCursorFlight()
    /// Same as `hideCursor(ownedByRunWith: nil)`.
    func hideCursor()
    /// The backend's end-of-run hide. Ignored when a newer run owns the cursor, and when this run already reported
    /// runFinished (the presenter keeps its done or stuck state up briefly, then hides it itself). A nil signal means
    /// the run is unknown: ignored while any run is live.
    func hideCursor(ownedByRunWith runAbortSignal: TaskAbortSignal?)
}

/// Frames of the task window for the live view shown while the window is covered.
@MainActor protocol TargetWindowFrameStreaming: AnyObject {
    var onFrame: ((CGImage) -> Void)? { get set }
    func startStreaming(_ targetWindow: TargetWindowReference, framesPerSecond: Int) async throws
    func stopStreaming() async
}

@MainActor protocol UserConfirmationRequesting: AnyObject {
    func requestSafetyConfirmation(_ request: SafetyConfirmationRequest) async -> SafetyConfirmationAnswer
}

@MainActor protocol TaskExecutionObserving: AnyObject {
    func taskExecutionDidStartItem(itemIdentifier: String)
    func taskExecutionDidReportProgress(itemIdentifier: String, progressDescription: String)
    func taskExecutionDidFinishItem(itemIdentifier: String, runStatus: ChecklistItemRunStatus, resultSummary: String)
    func taskExecutionDidReportCursorActivity(_ cursorActivityEvent: CursorActivityEvent)
}

/// The run's questions and results that need the session, not just a display: failure decisions, learned routines
/// and metrics.
@MainActor protocol TaskExecutionInteractionHandling: AnyObject {
    func requestItemFailureDecision(_ request: ChecklistItemFailureDecisionRequest) async -> ChecklistItemFailureDecision
    /// A routine learned or patched during this task. The executor replays it for the rest of this task and never
    /// writes it to disk: saving it to the library is up to the user after reviewing its steps.
    func taskExecutionDidUpdateRoutine(_ routine: Routine, wasNewlyLearned: Bool)
    func taskExecutionDidUpdateMetrics(_ metrics: TaskRunMetrics)
}
