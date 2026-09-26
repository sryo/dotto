import AppKit
import Combine

/// What each task gets for itself: the cursor that shows its work (with its overlay, pill and live view), the monitor
/// that tells whether its window is covered, and the observer that notices the user moving or closing its window.
struct TaskSessionServices {
    var cursorController: CursorController
    var visibilityMonitor: TargetWindowVisibilityMonitor
    var targetWindowObserver: TargetWindowObserver
}

/// Everything that belongs to one task, from the command (or saved routine) that starts it to the moment its checklist
/// is dismissed: its state, its target app, its audit log, Stop signal and budget, its planner conversation, its run
/// control and pending questions, and its takeover detector. `TaskSessionController` holds one today; it is the unit
/// several concurrent tasks (each in a different app) will each get.
@MainActor
final class TaskSession: ObservableObject {
    let cursorController: CursorController
    let visibilityMonitor: TargetWindowVisibilityMonitor
    let targetWindowObserver: TargetWindowObserver
    /// Created once the coordinator starts, because the panel reads the coordinator.
    var checklistPanelController: ChecklistPanelController?

    init(services: TaskSessionServices) {
        cursorController = services.cursorController
        visibilityMonitor = services.visibilityMonitor
        targetWindowObserver = services.targetWindowObserver
    }

    /// Names this task's leases on shared observers (the user-input tap).
    let sessionIdentifier = UUID().uuidString
    var runInputObservationHolderIdentifier: String { "run-" + sessionIdentifier }
    var demonstrationInputObservationHolderIdentifier: String { "demonstration-" + sessionIdentifier }

    @Published var sessionState: TaskSessionState = .idle {
        didSet { onSessionStateDidChange?() }
    }
    /// The app the task works in. Captured when the user summons Dotto, before the task itself starts.
    @Published var targetApplication: TargetApplicationReference?
    @Published var statusLine: String = TaskUserFacingMessages.readyStatusLine
    @Published var currentRunMetrics: TaskRunMetrics?
    @Published var attachedRoutine: Routine?
    /// A routine Dotto learned (or patched) from its own run. It replays for the rest of this task either way; it is
    /// only written to the library once the user has reviewed its steps and chosen to save it.
    @Published var learnedRoutineAwaitingReview: Routine?
    /// A taught routine is only saved and attached once the user has reviewed its steps and the text it will type.
    @Published var taughtRoutineAwaitingReview: Routine?
    @Published var currentAuditLogFileURL: URL?
    /// What the planning thread shows: the command, Dotto's questions and the user's replies.
    @Published var plannerConversationTranscript = PlannerConversationTranscript()
    /// What the planner is doing while the thread waits on it; nil once it has answered.
    @Published var currentPlanningProgress: ChecklistPlanningProgress?

    var currentTaskFocusPolicy: TaskFocusPolicy = .allowApprovedAssist
    var currentAuditLogWriter: AuditLogWriter?
    var currentAbortSignal: TaskAbortSignal?
    /// Created with the task, before planning, and shared by planning, teaching and the run (invariant 9).
    var currentTaskResourceBudget: TaskResourceBudget?
    /// Separate from the task's abort signal: cancelling teaching must not poison the run that follows it.
    var currentTeachingAbortSignal: TaskAbortSignal?
    /// The allowlist the current or next run uploads from: the command's attachments, or a routine's picked folder.
    var currentUploadFileAllowlist: UploadFileAllowlist = .empty
    /// Set by the countdown's Cancel button; read by the countdown that is running.
    var foregroundAssistCountdownWasCancelled = false
    /// The task's summon point: its cursor plans there and the checklist hangs from it. nil for a task that wasn't
    /// summoned (a saved routine run from the menu bar).
    var currentTaskSummonOriginInTopLeftGlobalPoints: CGPoint?
    var currentPlanningOrExecutionTask: Task<Void, Never>?
    let pendingSafetyConfirmation = PendingUserAnswer<SafetyConfirmationAnswer>()
    let pendingItemFailureDecision = PendingUserAnswer<ChecklistItemFailureDecision>()
    var currentRunControl: TaskRunControl?
    var userTakeoverDetector = UserTakeoverDetector()
    var lastSubmittedCommandText: String = ""
    /// When and where the user submitted the command, so a later planner question only takes the keyboard if they
    /// are still waiting on Dotto (same app in front, no clicks or keys since).
    var commandSubmittedAtSystemUptime: TimeInterval?
    var frontmostApplicationProcessIdentifierWhenCommandWasSubmitted: pid_t?
    /// The task's planner, kept while it waits for the user's reply so the conversation can go on.
    var currentChecklistPlanner: ChecklistPlanner?
    /// This task wants the menu bar icon pulsing (a question of its is waiting); the icon pulses while any task does.
    var wantsMenuBarIconPulse = false
    /// The view of the coordinator this task's own panels use, made once the coordinator wires the session.
    var scope: TaskSessionScope?
    /// The color this task's cursor, pill and checklist accents are drawn in (`TaskColorPalette`); nil until it starts.
    var taskColorHex: String?
    /// Survives resetPerTaskResources: a stopped run may still be unwinding (finishTask, a slow AX call) after the
    /// user dismisses it, and this session's next task must not take over its cursor until it has.
    var mostRecentlyStartedRunTask: Task<Void, Never>?
    /// What this task's direct-route views show: its planner context, live count, run report and any undo.
    let directRouteSessionState = DirectRouteSessionState()
    /// This task's own backend. A stopped task that is still unwinding keeps using the one it started with.
    var actionBackend: ActionBackend?

    /// Called after every state change (the summon gesture re-checks whether it may observe the pointer).
    var onSessionStateDidChange: (() -> Void)?

    /// Clears what a finished or dismissed task leaves behind. The state, the target app, the status line and the
    /// command text stay: they describe what the user last saw and summoned over.
    func resetPerTaskResources(taskFocusPolicyForNextTask: TaskFocusPolicy) {
        currentPlanningOrExecutionTask = nil
        currentAbortSignal = nil
        currentAuditLogWriter = nil
        currentTaskResourceBudget = nil
        currentRunControl = nil
        currentRunMetrics = nil
        attachedRoutine = nil
        learnedRoutineAwaitingReview = nil
        currentUploadFileAllowlist = .empty
        currentTaskFocusPolicy = taskFocusPolicyForNextTask
        currentTaskSummonOriginInTopLeftGlobalPoints = nil
        currentChecklistPlanner = nil
        actionBackend = nil
        taskColorHex = nil
        currentPlanningProgress = nil
        plannerConversationTranscript = PlannerConversationTranscript()
        userTakeoverDetector.reset()
    }
}
