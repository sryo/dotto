import Foundation
import CoreGraphics

/// What Dotto knows about each session when the user summons it for a new task.
struct TaskSessionSummary: Equatable, Sendable {
    /// Planning, waiting for approval or answers, running, paused or being taught: the task is still going.
    var isActive: Bool
    /// Showing a finished, failed or stopped task's summary the user hasn't dismissed. A new task may take its place.
    var isShowingResult: Bool
    /// Teach mode records every click and key the user makes, so no other task may start meanwhile.
    var isRecordingDemonstration: Bool
    var targetProcessIdentifier: Int32?
}

enum TaskSummonDecision: Equatable, Sendable {
    /// Start the new task in the session at this index (idle, or showing a result the new task replaces).
    case useSession(index: Int)
    /// No session is free and there is room for one more: make a new session.
    case createSession
    /// The app already has a task going (one task per app), or a demonstration is being recorded: show that task.
    case showExistingTask(index: Int)
    /// Dotto is already running as many tasks as it allows.
    case refuseBecauseTaskLimitReached
}

/// Several tasks may run at once, each in a different app: their input, takeover detection, Accessibility modes and
/// cursors are all told apart by the app's process. Three at most, so the cursors, questions and model budgets stay
/// something the user can follow.
enum ConcurrentTaskPolicy {
    static let maximumConcurrentTaskCount = 3

    static func decision(forSummoningInto targetProcessIdentifier: Int32?, sessions: [TaskSessionSummary]) -> TaskSummonDecision {
        if let recordingSessionIndex = sessions.firstIndex(where: \.isRecordingDemonstration) {
            return .showExistingTask(index: recordingSessionIndex)
        }
        if let targetProcessIdentifier, let sameApplicationSessionIndex = sessions.firstIndex(where: { session in
            session.isActive && session.targetProcessIdentifier == targetProcessIdentifier
        }) {
            return .showExistingTask(index: sameApplicationSessionIndex)
        }
        if sessions.filter(\.isActive).count >= maximumConcurrentTaskCount { return .refuseBecauseTaskLimitReached }
        // The same app's old summary is replaced by its new task, as when Dotto ran one task at a time.
        if let targetProcessIdentifier, let sameApplicationResultIndex = sessions.firstIndex(where: { session in
            session.isShowingResult && session.targetProcessIdentifier == targetProcessIdentifier
        }) {
            return .useSession(index: sameApplicationResultIndex)
        }
        if let idleSessionIndex = sessions.firstIndex(where: { !$0.isActive && !$0.isShowingResult }) {
            return .useSession(index: idleSessionIndex)
        }
        if sessions.count < maximumConcurrentTaskCount { return .createSession }
        if let oldestResultIndex = sessions.firstIndex(where: \.isShowingResult) { return .useSession(index: oldestResultIndex) }
        return .refuseBecauseTaskLimitReached
    }

    /// Whether any new task could start at all, whatever app it is for: the summon gesture stops observing otherwise.
    static func anotherTaskCanStart(sessions: [TaskSessionSummary]) -> Bool {
        !sessions.contains(where: \.isRecordingDemonstration) && sessions.filter(\.isActive).count < maximumConcurrentTaskCount
    }
}
