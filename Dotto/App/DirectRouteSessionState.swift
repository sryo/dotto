import Combine
import Foundation

/// The journal "Undo last task" in the menu bar offers: the newest undoable direct-route task.
struct UndoableJournalSummary: Equatable, Sendable {
    var journalIdentifier: String
    var taskTitle: String
    var changeCount: Int
    /// When its last change was made (or when it started, if it made none).
    var finishedAt: Date
    /// Dotto quit or crashed while the task was running; the row asks whether to undo what it did.
    var wasInterrupted: Bool
    /// An earlier undo reverted part of it; `changeCount` counts what is left.
    var wasPartiallyUndone: Bool = false

    /// Undo is offered for a day; after that the files have likely moved on.
    static let maximumOfferedAgeSeconds: TimeInterval = 24 * 60 * 60
}

/// The running direct route's latest count, as the cursor's pill shows it ("12 / 23 · Moving IMG_2041").
struct DirectRouteRunProgress: Equatable, Sendable {
    var completedCount: Int
    var totalCount: Int
    var operationDescription: String
}

/// What the direct-route views show beyond the task session state: the planner context the preview explains, the
/// live operation count, the run's report, and an undo in progress. Owned by `TaskSessionController`, and observed
/// directly by the views that show it.
@MainActor
final class DirectRouteSessionState: ObservableObject {
    /// What the planner was told for the current task; the script preview reads the Automation state from it.
    @Published var currentPlannerContext: PlannerDirectRouteContext = .disabled
    /// The latest operation count of the running direct route, for the panel's progress view.
    @Published var runProgress: DirectRouteRunProgress?
    /// The finished (or stopped) run's report; nil until the run ends and again once the task is dismissed.
    @Published var lastRunReport: DirectRouteRunReport?
    /// True from the Undo click until the undo ends, including before its first progress report.
    @Published var undoIsRunning = false
    @Published var undoProgress: FileOperationProgress?
    @Published var lastUndoReport: FileOperationUndoReport?
    /// Why the undo couldn't start or stopped early (the journal couldn't be read, …), in Dotto's words.
    @Published var undoFailureMessage: String?
    /// The journal the undo in progress (or the last finished one) works on.
    @Published var undoJournalIdentifier: String?
    @Published var mostRecentUndoableJournal: UndoableJournalSummary?

    /// Set by "Use the cursor instead": the next planning of this command offers only the checklist route.
    var directRoutesAreDisabledForNextPlanning = false
    /// Awaited before a new direct run starts, so a run never moves files while an undo is still putting them back.
    var currentUndoTask: Task<Void, Never>?
    /// Set while an undo runs, so its Stop button can end it between steps.
    var currentUndoAbortSignal: TaskAbortSignal?

    var isUndoInProgress: Bool { undoIsRunning }

    /// Stop on an undo in progress: the step under way finishes, the rest stays as it is and is offered again.
    func stopUndo() {
        currentUndoAbortSignal?.abort()
    }

    /// The undo of this journal finished during this app session with nothing left behind. After a partial undo
    /// (stopped, or some items left as they were) "Undo task" stays, to undo the rest.
    func hasFinishedUndo(ofJournal journalIdentifier: String) -> Bool {
        undoJournalIdentifier == journalIdentifier && !undoIsRunning && lastUndoReport.map { $0.skippedCount == 0 } == true
    }

    func beginRun() {
        runProgress = nil
        lastRunReport = nil
        clearUndoResult()
    }

    /// The task is over for the user: what its panel showed goes, the menu bar row stays.
    func clearTaskResult() {
        runProgress = nil
        lastRunReport = nil
        currentPlannerContext = .disabled
        if !undoIsRunning { clearUndoResult() }
    }

    private func clearUndoResult() {
        undoProgress = nil
        lastUndoReport = nil
        undoFailureMessage = nil
        undoJournalIdentifier = nil
    }
}
