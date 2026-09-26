import Foundation

/// What Platform observes right before a bring-forward.
struct ForegroundAssistReadinessInputs: Equatable, Sendable {
    /// Seconds since the last real (hardware) click, scroll or key press anywhere; Dotto's own synthesized input never
    /// counts. nil when unknown, which counts as "the user may be typing".
    var secondsSinceLastRealUserInput: TimeInterval?
    /// Whether secure event input is on (a password field is focused somewhere). nil when unknown, which counts as on.
    var secureEventInputIsEnabled: Bool?
    /// The process holding secure event input, when known.
    var secureEventInputProcessIdentifier: Int32?
}

enum ForegroundAssistReadiness: Equatable, Sendable {
    case ready
    /// The user clicked, scrolled or typed moments ago (or input can't be observed).
    case userIsActive
    /// Another app has a password field focused (or secure input can't be checked).
    case secureInputHeldByAnotherProcess
}

/// Bringing the target forward takes the keyboard from whatever the user is doing, so it only happens while the
/// user has paused: no real input for `minimumSecondsWithoutUserInput` and no password field active in another app.
/// This holds for every assist, including under a rest-of-task grant. Dotto waits up to `maximumWaitSeconds`, then
/// asks the user again instead of waiting forever.
struct ForegroundAssistReadinessPolicy: Equatable, Sendable {
    var minimumSecondsWithoutUserInput: TimeInterval = 1.5
    var maximumWaitSeconds: TimeInterval = 20
    var pollIntervalSeconds: TimeInterval = 0.25
    /// The pill's "Bringing <App> forward…" countdown, with Cancel, right before the app comes forward.
    var countdownSeconds: Double = 1.0

    func readiness(for readinessInputs: ForegroundAssistReadinessInputs, targetProcessIdentifier: Int32?) -> ForegroundAssistReadiness {
        switch readinessInputs.secureEventInputIsEnabled {
        case nil:
            return .secureInputHeldByAnotherProcess
        case true?:
            // The target's own password field isn't someone else's typing; any other holder, or an unknown one, is.
            let secureInputIsTargets = targetProcessIdentifier != nil
                && readinessInputs.secureEventInputProcessIdentifier == targetProcessIdentifier
            if !secureInputIsTargets { return .secureInputHeldByAnotherProcess }
        case false?:
            break
        }
        guard let secondsSinceLastRealUserInput = readinessInputs.secondsSinceLastRealUserInput,
              secondsSinceLastRealUserInput >= minimumSecondsWithoutUserInput else { return .userIsActive }
        return .ready
    }

    /// The re-ask after waiting in vain. Dotto's own wording plus the app name only.
    static func reaskReason(after readiness: ForegroundAssistReadiness, targetApplicationName: String) -> String {
        let waitingCause = readiness == .secureInputHeldByAnotherProcess
            ? "a password field is active in another app"
            : "you're still using your Mac"
        return "Dotto waited to bring \(targetApplicationName) forward because \(waitingCause); bringing it forward now "
            + "would take the keyboard from you. Bring it forward once you've paused?"
    }
}

/// App's side of the wait: Platform's inputs and the pill's waiting text and countdown.
@MainActor protocol ForegroundAssistReadinessGating: AnyObject {
    func currentForegroundAssistReadinessInputs() -> ForegroundAssistReadinessInputs
    /// The pill says Dotto is waiting for the user to pause.
    func foregroundAssistIsWaitingForUser()
    /// Shows "Bringing <App> forward…" with Cancel for `countdownSeconds`. False when the user cancelled or the run stopped.
    func runForegroundAssistCountdown(countdownSeconds: Double, abortSignal: TaskAbortSignal) async -> Bool
    /// The wait or countdown is over: the assist starts next, the user is asked again, or it was called off.
    func foregroundAssistPendingEnded()
    /// Waits for this task's turn to bring its app forward (`ForegroundAssistTurnQueue`). False when the task was
    /// stopped while waiting.
    func waitForForegroundAssistTurn(abortSignal: TaskAbortSignal) async -> Bool
    /// The assist is over (or never happened): the next task may take its turn.
    func foregroundAssistTurnEnded()
}
