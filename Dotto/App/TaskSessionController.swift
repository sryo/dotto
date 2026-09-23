import AppKit
import Combine

struct TaskSessionControllerDependencies {
    var claudeTransport: ClaudeTransport
    var anthropicAPIKeyStore: AnthropicAPIKeyStore
    var actionBackend: ActionBackend
    var keyboardMonitor: GlobalKeyboardMonitor
    var pointerMovementObserver: PointerMovementObserver
    var cursorController: CursorController
    var userInputObserver: UserInputObserver
    var targetWindowObserver: TargetWindowObserver
    var automatedTargetActivityRelay: AutomatedTargetActivityRelay
    var visibilityMonitor: TargetWindowVisibilityMonitor
    var windowServerCapabilities: PrivateWindowServerCapabilities
    var attentionNotificationPoster: UserAttentionNotificationPoster
    var demonstrationRecorder: DemonstrationRecorder
    var routineLibraryStore: RoutineLibraryStore
    /// nil when the undo journal folder couldn't be created: direct routes are then off and every task uses the cursor.
    var directRouteExecutionDependencies: DirectRouteExecutionDependencies?
}

/// Everything a task owns from its first step on: its audit log, its Stop signal and the task-wide budget that
/// planning, teaching and the run all draw on.
struct TaskStartResources {
    var taskIdentifier: String
    var auditLogWriter: AuditLogWriter
    var abortSignal: TaskAbortSignal
    var taskResourceBudget: TaskResourceBudget
}

/// Composition-level coordinator for one task at a time: owns the task session state, drives the planner and
/// executor, answers safety confirmations and keeps the command bar, checklist panel and acting cursor in sync.
/// Split per flow into `+Planning`, `+Run`, `+Decisions`, `+Pause`, `+ExecutionObserving`, `+Teaching`,
/// `+SavedRoutines`, `+Attention`, `+ForegroundAssist`, `+SummonHotkey`, `+SummonGesture`, `+AnthropicAPIKey` and `+DirectRoutes`. It deliberately conforms to none of the
/// executor's protocols: only a run-scoped `TaskRunDelegateBridge` is ever handed to Core.
@MainActor
final class TaskSessionController: ObservableObject {
    @Published private(set) var sessionState: TaskSessionState = .idle {
        didSet { summonGestureController?.refreshObservation() }
    }
    @Published private(set) var permissionStatus: SystemPermissionStatus
    @Published private(set) var summonHotkeyIsRegistered: Bool = false
    /// ⌃⌥Space unless the user recorded another shortcut in the menu bar panel.
    @Published var summonHotkey: SummonHotkey = .standard
    /// Set only when Platform's check finds the shortcut is likely taken by macOS or another app.
    @Published var summonHotkeyConflictDescription: String?
    /// Why the last recorded shortcut wasn't used, shown under the recorder until the next attempt.
    @Published var summonHotkeyRecordingProblem: String?
    /// The stored key in its masked form (`sk-ant-…a1b2`), or nil when no key is saved. The full key is never published.
    @Published var maskedAnthropicAPIKey: String?
    /// Why the Keychain couldn't be read or written, shown on the API key card.
    @Published var anthropicAPIKeyStoreProblem: String?
    /// Circle to summon: the defaults with the user's on/off, direction and loops needed, which are kept in UserDefaults.
    @Published var summonGestureConfiguration: SummonGestureConfiguration = .standard
    /// The user's additions to and removals from the default exclusion list, kept in UserDefaults.
    @Published var summonGestureExclusionAdjustments = SummonGestureExclusionAdjustments()
    /// Apps where circling the pointer never summons Dotto (drawing tools and games by default).
    var summonGestureExcludedBundleIdentifiers: [String] { summonGestureExclusionAdjustments.excludedBundleIdentifiers() }

    // The members below are internal rather than private only because the per-flow extensions live in their own
    // files. Views read them and never assign them.
    @Published var currentRunMetrics: TaskRunMetrics?
    /// A routine Dotto learned (or patched) from its own run. It replays for the rest of this task either way; it is
    /// only written to the library once the user has reviewed its steps and chosen to save it.
    @Published var learnedRoutineAwaitingReview: Routine?
    @Published var statusLine: String = TaskUserFacingMessages.readyStatusLine
    @Published var targetApplication: TargetApplicationReference?
    @Published var savedRoutines: [Routine] = []
    /// Routine files that weren't loaded (unsigned, edited outside Dotto, damaged, …), shown with the reason.
    @Published var skippedRoutineFiles: [SkippedRoutineFile] = []
    @Published var attachedRoutine: Routine?
    @Published var recordedDemonstrationEventCount: Int = 0
    /// What the recorder saw but couldn't record (typing in a web page, pasting an image), shown on the teaching card.
    @Published var demonstrationRecordingNotes: [String] = []
    /// A taught routine is only saved and attached once the user has reviewed its steps and the text it will type.
    @Published var taughtRoutineAwaitingReview: Routine?
    /// Files and folders the user attached or dropped in the command bar; only these can be uploaded by the next task.
    @Published var attachedUploadGrants: [UploadFileGrant] = []
    @Published var cursorStyleConfiguration: CursorStyleConfiguration = .standard
    @Published var attentionPreferences: AttentionPreferences = .standard
    /// Background-first by default; the user can require a strict no-assist task before starting it.
    @Published var taskFocusPolicy: TaskFocusPolicy = .allowApprovedAssist
    var currentTaskFocusPolicy: TaskFocusPolicy = .allowApprovedAssist
    @Published var liveViewCorner: ScreenCorner = .bottomRight
    /// The menu bar icon pulses while a decision waits for the user.
    @Published var isMenuBarIconPulsing = false
    var currentAuditLogFileURL: URL?
    let claudeTransport: ClaudeTransport
    let anthropicAPIKeyStore: AnthropicAPIKeyStore
    let actionBackend: ActionBackend
    let userInputObserver: UserInputObserver
    let targetWindowObserver: TargetWindowObserver
    let automatedTargetActivityRelay: AutomatedTargetActivityRelay
    let visibilityMonitor: TargetWindowVisibilityMonitor
    let demonstrationRecorder: DemonstrationRecorder
    let routineLibraryStore: RoutineLibraryStore
    var checklistPanelController: ChecklistPanelController?
    var commandBarPanelController: CommandBarPanelController?
    var currentAuditLogWriter: AuditLogWriter?
    var currentAbortSignal: TaskAbortSignal?
    /// Created with the task, before planning, and shared by planning, teaching and the run (invariant 9).
    var currentTaskResourceBudget: TaskResourceBudget?
    /// Separate from the task's abort signal: cancelling teaching must not poison the run that follows it.
    var currentTeachingAbortSignal: TaskAbortSignal?
    /// The allowlist the current or next run uploads from: the command's attachments, or a routine's picked folder.
    var currentUploadFileAllowlist: UploadFileAllowlist = .empty
    let cursorController: CursorController
    let attentionNotificationPoster: UserAttentionNotificationPoster
    let previousApplicationTracker = PreviousApplicationTracker()
    /// Set by the countdown's Cancel button; read by the countdown that is running.
    var foregroundAssistCountdownWasCancelled = false
    let keyboardMonitor: GlobalKeyboardMonitor
    let pointerMovementObserver: PointerMovementObserver
    var summonGestureController: SummonGestureController?
    let windowServerCapabilities: PrivateWindowServerCapabilities
    /// Where the user was when they summoned the command bar; the keyboard goes back there once the command is in.
    var applicationFrontmostWhenCommandBarWasSummoned: NSRunningApplication?
    /// Where the user last summoned Dotto, in top-left global points: the point the circle gesture fired at, or the
    /// pointer when the shortcut opened the command bar. The next command's task starts its cursor there.
    var summonOriginOfNextCommandInTopLeftGlobalPoints: CGPoint?
    /// The current task's summon point: its cursor plans there and the checklist hangs from it. nil for a task that
    /// wasn't summoned (a saved routine run from the menu bar).
    var currentTaskSummonOriginInTopLeftGlobalPoints: CGPoint?
    var currentPlanningOrExecutionTask: Task<Void, Never>?
    /// Survives resetPerTaskResources: a stopped run may still be unwinding (finishTask, a slow AX call)
    /// after the user dismisses it, and the next run must not prepare the backend until it has.
    var mostRecentlyStartedRunTask: Task<Void, Never>?
    let pendingSafetyConfirmation = PendingUserAnswer<SafetyConfirmationAnswer>()
    let pendingItemFailureDecision = PendingUserAnswer<ChecklistItemFailureDecision>()
    var currentRunControl: TaskRunControl?
    var userTakeoverDetector = UserTakeoverDetector()
    var lastSubmittedCommandText: String = ""
    /// When and where the user submitted the current command, so a later planner question only takes the keyboard
    /// if they are still waiting on Dotto (same app in front, no clicks or keys since).
    var commandSubmittedAtSystemUptime: TimeInterval?
    var frontmostApplicationProcessIdentifierWhenCommandWasSubmitted: pid_t?
    /// What the planning thread shows: the command, Dotto's questions and the user's replies.
    @Published var plannerConversationTranscript = PlannerConversationTranscript()
    /// What the planner is doing while the thread waits on it; nil once it has answered.
    @Published var currentPlanningProgress: ChecklistPlanningProgress?
    /// The current task's planner, kept while it waits for the user's reply so the conversation can go on.
    var currentChecklistPlanner: ChecklistPlanner?
    /// The file system, journal, script and shortcut runners direct routes use; nil turns direct routes off.
    let directRouteExecutionDependencies: DirectRouteExecutionDependencies?
    let directRouteSessionState = DirectRouteSessionState()

    private var permissionPollingTimer: Timer?

    init(dependencies: TaskSessionControllerDependencies) {
        self.claudeTransport = dependencies.claudeTransport
        self.anthropicAPIKeyStore = dependencies.anthropicAPIKeyStore
        self.actionBackend = dependencies.actionBackend
        self.keyboardMonitor = dependencies.keyboardMonitor
        self.pointerMovementObserver = dependencies.pointerMovementObserver
        self.cursorController = dependencies.cursorController
        self.targetWindowObserver = dependencies.targetWindowObserver
        self.automatedTargetActivityRelay = dependencies.automatedTargetActivityRelay
        self.visibilityMonitor = dependencies.visibilityMonitor
        self.windowServerCapabilities = dependencies.windowServerCapabilities
        self.attentionNotificationPoster = dependencies.attentionNotificationPoster
        self.userInputObserver = dependencies.userInputObserver
        self.demonstrationRecorder = dependencies.demonstrationRecorder
        self.routineLibraryStore = dependencies.routineLibraryStore
        self.directRouteExecutionDependencies = dependencies.directRouteExecutionDependencies
        self.permissionStatus = SystemPermissions.readCurrentStatus()
        refreshAnthropicAPIKeyState()
    }

    // MARK: - Lifecycle

    func start() {
        loadTaskFocusPolicy()
        commandBarPanelController = CommandBarPanelController(taskSessionController: self)
        checklistPanelController = ChecklistPanelController(taskSessionController: self)
        previousApplicationTracker.shouldIgnoreActivation = { [weak self] activatedApplication in
            // The target coming forward for an approved assist isn't where the user was.
            guard let self else { return false }
            return self.cursorController.isForegroundAssistActive
                && activatedApplication.processIdentifier == self.targetApplication?.processIdentifier
        }
        previousApplicationTracker.start()
        loadSummonHotkey()

        keyboardMonitor.onSummonHotkeyPressed = { [weak self] in
            self?.showCommandBar()
        }
        startKeyboardMonitor()
        userInputObserver.onUserInputObserved = { [weak self] observedEvent in
            self?.routeObservedUserInput(observedEvent)
        }
        targetWindowObserver.onTargetWindowEvent = { [weak self] targetWindowEvent in
            self?.routeTargetWindowEvent(targetWindowEvent)
        }
        automatedTargetActivityRelay.onAutomatedTargetActivity = { [weak self] automatedActivity, timestampSeconds in
            self?.userTakeoverDetector.noteAutomatedActivity(automatedActivity, atTimestampSeconds: timestampSeconds)
        }
        visibilityMonitor.onVisibilityChanged = { [weak self] targetWindowVisibility in
            self?.cursorController.updateTargetWindowVisibility(targetWindowVisibility)
        }
        cursorController.onTargetWindowChanged = { [weak self] changedTargetWindow in
            guard let self else { return }
            self.visibilityMonitor.startMonitoring(changedTargetWindow, targetPointInWindow: { [weak self] in
                self?.cursorController.viewModel.presentationState.targetPointInWindow
            })
        }
        startAttentionDelivery()
        startSummonGesture()
        checklistPanelController?.onVisibilityChanged = { [weak self] checklistIsOpen in
            self?.cursorController.checklistIsOpen = checklistIsOpen
        }
        cursorController.onChecklistToggleRequested = { [weak self] in
            self?.toggleChecklistBesideCursor()
        }

        permissionPollingTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshPermissionStatus()
            }
        }
    }

    func stop() {
        permissionPollingTimer?.invalidate()
        permissionPollingTimer = nil
        if sessionState.isBusy {
            stopTask()
        }
        keyboardMonitor.stop()
        summonGestureController?.stop()
        stopRunObservers()
        cursorController.putCursorAway()
        commandBarPanelController?.hideCommandBar()
        checklistPanelController?.hideChecklistPanel()
    }

    // MARK: - Command bar

    /// After Dotto's own file picker: the command bar takes the keyboard again, without activating Dotto.
    func returnKeyboardToCommandBar() {
        commandBarPanelController?.makeCommandBarKeyIfVisible()
    }

    func showCommandBar() {
        if sessionState.isBusy || isAwaitingApproval || isDemonstrating {
            checklistPanelController?.showChecklistPanel(makeKey: false)
            return
        }
        captureFrontmostApplicationAsTarget()
        applicationFrontmostWhenCommandBarWasSummoned = NSWorkspace.shared.frontmostApplication
        summonOriginOfNextCommandInTopLeftGlobalPoints = ScreenGeometry.mouseLocationInTopLeftGlobalPoints
        commandBarPanelController?.showCommandBar(prefilledCommandText: "")
    }

    func reopenCommandBarWithPreviousCommand() {
        commandBarPanelController?.showCommandBar(prefilledCommandText: lastSubmittedCommandText)
    }

    func showChecklist() {
        checklistPanelController?.showChecklistPanel(makeKey: false)
    }

    // MARK: - Checklist placement

    /// What the checklist popover hangs from right now: the cursor (or the live view while the target window is
    /// covered); without a cursor, the point the task was summoned at; without that either (a saved routine run from
    /// the menu bar), the top-right corner inside the target window, or of the screen when no window is known.
    func checklistPanelAnchor() -> AttachedPanelAnchor {
        if let cursorAnchor = cursorController.anchorForAttachedPanels() {
            return cursorAnchor
        }
        if let summonOrigin = currentTaskSummonOriginInTopLeftGlobalPoints {
            return .besideCursor(anchorPoint: summonOrigin,
                                 keepClearFrame: CGRect(x: summonOrigin.x - 12, y: summonOrigin.y - 12, width: 24, height: 24))
        }
        if let targetApplication,
           let targetWindowFrame = ScreenGeometry.frontmostNormalWindowFrameInTopLeftGlobalPoints(
               ownedByProcessIdentifier: targetApplication.processIdentifier) {
            return .insideTopRightCorner(containerFrame: targetWindowFrame)
        }
        return .insideTopRightCorner(containerFrame: ScreenGeometry.visibleFrameInTopLeftGlobalPoints(
            ofScreenContainingTopLeftGlobalPoint: ScreenGeometry.mouseLocationInTopLeftGlobalPoints))
    }

    /// The pill's (or the live view's) chevron: opens the checklist next to where the cursor is now, or folds it back.
    func toggleChecklistBesideCursor() {
        guard let checklistPanelController else { return }
        if checklistPanelController.isVisible {
            checklistPanelController.collapseIntoCursor()
        } else if isWaitingForPlannerReply {
            // Opened by the user to answer: the reply field takes the keyboard, as when the question arrived.
            checklistPanelController.showPlannerReplyField(anchor: checklistPanelAnchor())
        } else {
            checklistPanelController.showChecklistPanel(makeKey: false, anchor: checklistPanelAnchor())
        }
    }

    /// Questions and pauses ride the cursor's pill (or the live view's docked pill). The checklist opens for them
    /// only when no cursor is showing to carry them.
    func showChecklistPanelIfCursorCannotCarryIt() {
        guard cursorController.anchorForAttachedPanels() == nil else { return }
        checklistPanelController?.showChecklistPanel(makeKey: false)
    }

    func openCurrentAuditLog() {
        guard let currentAuditLogFileURL else { return }
        // .jsonl often has no default app; revealing it in Finder is the useful fallback.
        if !NSWorkspace.shared.open(currentAuditLogFileURL) {
            NSWorkspace.shared.activateFileViewerSelecting([currentAuditLogFileURL])
        }
    }

    // MARK: - Permissions

    func requestAccessibilityPermission() {
        SystemPermissions.requestAccessibilityPermission()
    }

    func requestScreenRecordingPermission() {
        SystemPermissions.requestScreenRecordingPermission()
    }

    private func refreshPermissionStatus() {
        let latestPermissionStatus = SystemPermissions.readCurrentStatus()
        guard latestPermissionStatus != permissionStatus else { return }
        let accessibilityWasJustGranted = latestPermissionStatus.hasAccessibilityPermission
            && !permissionStatus.hasAccessibilityPermission
        permissionStatus = latestPermissionStatus
        if accessibilityWasJustGranted {
            startKeyboardMonitor()
        }
    }

    func startKeyboardMonitor() {
        let keyboardMonitorStartResult = keyboardMonitor.start(summonHotkey: summonHotkey)
        summonHotkeyIsRegistered = keyboardMonitorStartResult.summonHotkeyRegistered
        summonHotkeyConflictDescription = keyboardMonitorStartResult.conflictDescription
    }

    // MARK: - State

    /// Every state change funnels through the pure state machine so an invalid late
    /// event (e.g. an item finishing after an abort) is dropped instead of corrupting state.
    @discardableResult
    func apply(_ event: TaskSessionEvent) -> Bool {
        guard let nextState = TaskSessionStateMachine.nextState(from: sessionState, on: event) else {
            print("Dotto: ignored \(event) in state \(sessionState)")
            return false
        }
        sessionState = nextState
        return true
    }

    var isAwaitingApproval: Bool {
        if case .awaitingApproval = sessionState { return true }
        return false
    }

    /// Dotto asked a question the user can answer in the thread.
    var isWaitingForPlannerReply: Bool {
        if case .plannerNeedsInput(_, let plannerQuestion) = sessionState { return plannerQuestion.acceptsReply }
        return false
    }

    var isDemonstrating: Bool {
        if case .demonstrating = sessionState { return true }
        return false
    }

    var isExecutingOrPaused: Bool {
        switch sessionState {
        case .executing, .paused: return true
        default: return false
        }
    }

    // MARK: - Per-task resources

    /// Creates the audit log (writing its first entry), the Stop signal and the task-wide budget. Nothing is
    /// adopted as the current task until `adoptTaskStartResources` runs.
    func makeTaskStartResources(targetApplication: TargetApplicationReference, auditMessage: String,
                                additionalAuditDetails: [String: String] = [:]) throws -> TaskStartResources {
        let taskIdentifier = Self.makeNewTaskIdentifier()
        let auditLogWriter = try AuditLogWriter(taskIdentifier: taskIdentifier)
        auditLogWriter.append(eventKind: .taskStarted, itemIdentifier: nil, message: auditMessage,
                              details: ["targetApplication": targetApplication.applicationName,
                                        "windowServerCapabilities": windowServerCapabilities.auditDescription]
                                  .merging(additionalAuditDetails) { _, additionalDetail in additionalDetail })
        return TaskStartResources(taskIdentifier: taskIdentifier, auditLogWriter: auditLogWriter, abortSignal: TaskAbortSignal(),
                                  taskResourceBudget: TaskResourceBudget(safetyLimits: .standard))
    }

    func adoptTaskStartResources(_ taskStartResources: TaskStartResources) {
        currentAuditLogWriter = taskStartResources.auditLogWriter
        currentAuditLogFileURL = taskStartResources.auditLogWriter.logFileURL
        currentAbortSignal = taskStartResources.abortSignal
        currentTaskResourceBudget = taskStartResources.taskResourceBudget
    }

    func resetPerTaskResources() {
        currentPlanningOrExecutionTask = nil
        currentAbortSignal = nil
        currentAuditLogWriter = nil
        currentTaskResourceBudget = nil
        currentRunControl = nil
        currentRunMetrics = nil
        attachedRoutine = nil
        learnedRoutineAwaitingReview = nil
        currentUploadFileAllowlist = .empty
        currentTaskFocusPolicy = taskFocusPolicy
        currentTaskSummonOriginInTopLeftGlobalPoints = nil
        currentChecklistPlanner = nil
        currentPlanningProgress = nil
        plannerConversationTranscript = PlannerConversationTranscript()
        directRouteSessionState.clearTaskResult()
        userTakeoverDetector.reset()
    }

    func captureFrontmostApplicationAsTarget() {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else { return }
        // Summoning from our own menu bar panel must not make Dotto its own target;
        // keep the previously captured app instead.
        guard frontmostApplication.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        targetApplication = TargetApplicationReference(
            processIdentifier: frontmostApplication.processIdentifier,
            applicationName: frontmostApplication.localizedName ?? "the frontmost app",
            bundleIdentifier: frontmostApplication.bundleIdentifier
        )
    }

    static func makeNewTaskIdentifier() -> String {
        let randomTaskIdentifierSuffix = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6)).lowercased()
        return TaskIdentifierFactory.makeTaskIdentifier(now: Date(), randomSuffix: randomTaskIdentifierSuffix)
    }
}
