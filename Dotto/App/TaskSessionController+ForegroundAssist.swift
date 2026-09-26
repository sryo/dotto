import AppKit

/// The App's side of ForegroundAssistReadinessPolicy, reached through the run's TaskRunDelegateBridge: Platform's
/// readings of the user's input and secure input, and the pill's "waiting for you to pause" and "Bringing <App>
/// forward…" countdown with Cancel. Core decides when the app may come forward; this only reports and shows.
extension TaskSessionController {
    func currentForegroundAssistReadinessInputs() -> ForegroundAssistReadinessInputs {
        ForegroundAssistReadinessProbe.currentInputs()
    }

    func foregroundAssistIsWaitingForUser() {
        cursorController.handle(.foregroundAssistWaitingForUser)
    }

    func runForegroundAssistCountdown(countdownSeconds: Double, abortSignal: TaskAbortSignal, in session: TaskSession) async -> Bool {
        session.foregroundAssistCountdownWasCancelled = false
        session.cursorController.handle(.foregroundAssistCountdownStarted)
        let countdownEndUptimeSeconds = ProcessInfo.processInfo.systemUptime + countdownSeconds
        while ProcessInfo.processInfo.systemUptime < countdownEndUptimeSeconds {
            if session.foregroundAssistCountdownWasCancelled || abortSignal.isAborted { return false }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return !session.foregroundAssistCountdownWasCancelled && !abortSignal.isAborted
    }

    func foregroundAssistPendingEnded() {
        cursorController.handle(.foregroundAssistPendingEnded)
    }

    func cancelForegroundAssistCountdown() {
        foregroundAssistCountdownWasCancelled = true
    }
}
