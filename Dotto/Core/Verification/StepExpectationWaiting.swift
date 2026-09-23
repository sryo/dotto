import Foundation

enum StepExpectationWaiting {
    /// Polls the focused window until StepExpectationChecker passes or the timeout elapses (at least one check).
    /// Pass the snapshot read just before the action so text_appears can't pass on text that was already there;
    /// without one, a text_appears check waits one poll interval before its first read so the action can land.
    static func waitForExpectation(_ expectation: StepExpectation, actionBackend: ActionBackend,
                                   timeoutSeconds: Double, pollIntervalNanoseconds: UInt64,
                                   abortSignal: TaskAbortSignal, preActionSnapshot: AccessibilityTreeSnapshot? = nil) async throws
        -> (verdict: StepExpectationVerdict, latestSnapshot: AccessibilityTreeSnapshot?) {
        let comparableSnapshot = preActionSnapshot?.scope == .focusedWindow ? preActionSnapshot : nil
        if expectation.kind == .textAppears, comparableSnapshot == nil {
            try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
        let waitDeadline = Date().addingTimeInterval(timeoutSeconds)
        var latestSnapshot: AccessibilityTreeSnapshot?
        while true {
            var verdict: StepExpectationVerdict
            do {
                let snapshot = try await actionBackend.readUserInterface(
                    ReadUserInterfaceRequest(scope: .focusedWindow, applicationName: nil, query: nil), abortSignal: abortSignal)
                latestSnapshot = snapshot
                verdict = StepExpectationChecker.evaluate(expectation, in: snapshot, preActionSnapshot: comparableSnapshot)
            } catch {
                if ClaudeToolResultBuilding.isAbort(error, abortSignal: abortSignal) { throw error }
                verdict = .unsatisfied(reasonForModel: ClaudeToolResultBuilding.fencedMessageForModel(describing: error))
            }
            if verdict == .satisfied || Date() >= waitDeadline { return (verdict, latestSnapshot) }
            try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
    }
}
