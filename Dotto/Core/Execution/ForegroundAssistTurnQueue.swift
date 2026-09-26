import Foundation
import CoreGraphics

/// Bringing an app forward uses the one front app, the one key window and the one saved "where the user was", so only
/// one task's assist may be under way at a time. Tasks take turns in the order they asked. A task holds its turn from
/// before its readiness wait and countdown until the user's app, window and cursor are back, then there is a short
/// gap so the user's screen doesn't whip from one app to the next.
@MainActor final class ForegroundAssistTurnQueue {
    static let standardGapBetweenTurnsSeconds: TimeInterval = 0.5
    static let standardPollIntervalSeconds: TimeInterval = 0.05

    private(set) var currentTurnOwnerIdentifier: String?
    private(set) var waitingOwnerIdentifiers: [String] = []
    private var lastTurnEndedUptimeSeconds: TimeInterval?
    private let gapBetweenTurnsSeconds: TimeInterval
    private let pollIntervalSeconds: TimeInterval
    private let currentUptimeSeconds: () -> TimeInterval

    init(gapBetweenTurnsSeconds: TimeInterval = standardGapBetweenTurnsSeconds,
         pollIntervalSeconds: TimeInterval = standardPollIntervalSeconds,
         currentUptimeSeconds: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.gapBetweenTurnsSeconds = gapBetweenTurnsSeconds
        self.pollIntervalSeconds = pollIntervalSeconds
        self.currentUptimeSeconds = currentUptimeSeconds
    }

    /// Returns true once `ownerIdentifier` holds the turn, false when its task was stopped while waiting (it then
    /// leaves the queue). Asking again while already holding the turn returns true at once.
    func waitForTurn(ownerIdentifier: String, abortSignal: TaskAbortSignal) async -> Bool {
        if currentTurnOwnerIdentifier == ownerIdentifier { return true }
        if !waitingOwnerIdentifiers.contains(ownerIdentifier) { waitingOwnerIdentifiers.append(ownerIdentifier) }
        while true {
            if abortSignal.isAborted || Task.isCancelled {
                waitingOwnerIdentifiers.removeAll { $0 == ownerIdentifier }
                return false
            }
            if currentTurnOwnerIdentifier == nil, waitingOwnerIdentifiers.first == ownerIdentifier, gapHasPassed {
                waitingOwnerIdentifiers.removeFirst()
                currentTurnOwnerIdentifier = ownerIdentifier
                return true
            }
            try? await Task.sleep(nanoseconds: UInt64(pollIntervalSeconds * 1_000_000_000))
        }
    }

    /// Ends the turn if `ownerIdentifier` holds it, and takes it out of the queue if it was still waiting.
    func endTurn(ownerIdentifier: String) {
        waitingOwnerIdentifiers.removeAll { $0 == ownerIdentifier }
        guard currentTurnOwnerIdentifier == ownerIdentifier else { return }
        currentTurnOwnerIdentifier = nil
        lastTurnEndedUptimeSeconds = currentUptimeSeconds()
    }

    private var gapHasPassed: Bool {
        guard let lastTurnEndedUptimeSeconds else { return true }
        return currentUptimeSeconds() - lastTurnEndedUptimeSeconds >= gapBetweenTurnsSeconds
    }
}
