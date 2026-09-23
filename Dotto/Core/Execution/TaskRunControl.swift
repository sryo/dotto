import Foundation

enum TaskPauseReason: Equatable, Sendable {
    case requestedByUser
    case userTookOver(UserTakeoverInputKind)

    var bannerText: String {
        switch self {
        case .requestedByUser: return "Paused."
        case .userTookOver(.mouseClicked): return "Paused: you clicked in the app Dotto is using. Resume?"
        case .userTookOver(.scrolled): return "Paused: you scrolled in the app Dotto is using. Resume?"
        case .userTookOver(.keyPressed): return "Paused: you typed in the app Dotto is using. Resume?"
        case .userTookOver(.windowMovedOrResized): return "Paused: you moved or resized the window Dotto is using. Resume?"
        case .userTookOver(.windowClosed): return "Paused: the window Dotto is using was closed or minimized. Resume?"
        }
    }
}

enum TaskRunCheckpointOutcome: Equatable, Sendable { case proceed, resumedAfterPause, skipCurrentItem }

/// Pause and skip requests from the UI, observed by the executor only at checkpoints (before each action or
/// replay step, and between items), so a pause never lands in the middle of an input sequence.
final class TaskRunControl: @unchecked Sendable {
    private let stateLock = NSLock()
    private let pollIntervalNanoseconds: UInt64
    private var pauseReason: TaskPauseReason?
    private var skipWasRequested = false
    /// A skip pressed while paused is meant for the item the user is looking at, even when the pause landed
    /// between items, so it is kept for the next item instead of being dropped.
    private var skipWasRequestedWhilePaused = false

    init(pollIntervalNanoseconds: UInt64 = 100_000_000) {
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
    }

    func requestPause(reason: TaskPauseReason) {
        stateLock.withLock {
            if pauseReason == nil { pauseReason = reason }
        }
    }

    func resume() {
        stateLock.withLock { pauseReason = nil }
    }

    func requestSkipCurrentItem() {
        stateLock.withLock {
            skipWasRequested = true
            if pauseReason != nil { skipWasRequestedWhilePaused = true }
            pauseReason = nil
        }
    }

    var currentPauseReason: TaskPauseReason? { stateLock.withLock { pauseReason } }

    /// Blocks while paused. Throws ActionBackendError.aborted on abort or Task cancellation.
    func checkpoint(abortSignal: TaskAbortSignal) async throws -> TaskRunCheckpointOutcome {
        try await waitAtCheckpoint(abortSignal: abortSignal) { _, _ in true }
    }

    /// The checkpoint before an item starts. Blocks while paused. Returns `.skipCurrentItem` when the user skipped
    /// while paused (before or during this wait): that skip belongs to the item about to start. A skip that was
    /// pending without a pause targeted the item that just finished, so it is dropped.
    func checkpointBetweenItems(abortSignal: TaskAbortSignal) async throws -> TaskRunCheckpointOutcome {
        try await waitAtCheckpoint(abortSignal: abortSignal) { skipWasRequestedWhilePaused, hasWaitedWhilePaused in
            skipWasRequestedWhilePaused || hasWaitedWhilePaused
        }
    }

    /// Every pass consumes any pending skip, checks the abort signal first, and only then looks at the pause, so a
    /// Stop pressed while paused ends the wait within one poll interval.
    private func waitAtCheckpoint(abortSignal: TaskAbortSignal,
                                  pendingSkipAppliesHere: (_ skipWasRequestedWhilePaused: Bool, _ hasWaitedWhilePaused: Bool) -> Bool)
        async throws -> TaskRunCheckpointOutcome {
        var hasWaitedWhilePaused = false
        while true {
            try abortSignal.throwIfAborted()
            let (skipAppliesHere, isPaused): (Bool, Bool) = stateLock.withLock {
                let skipAppliesHere = skipWasRequested && pendingSkipAppliesHere(skipWasRequestedWhilePaused, hasWaitedWhilePaused)
                skipWasRequested = false
                skipWasRequestedWhilePaused = false
                return (skipAppliesHere, pauseReason != nil)
            }
            if skipAppliesHere { return .skipCurrentItem }
            if !isPaused { return hasWaitedWhilePaused ? .resumedAfterPause : .proceed }
            hasWaitedWhilePaused = true
            do {
                try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
            } catch {
                throw ActionBackendError.aborted
            }
        }
    }
}
