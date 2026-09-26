import AppKit
import Combine

struct TaskSessionControllerDependencies {
    var claudeTransport: ClaudeTransport
    var anthropicAPIKeyStore: AnthropicAPIKeyStore
    /// A fresh backend for each task, reporting to that task's cursor: its element ids, snapshot and held
    /// Accessibility modes are that task's alone.
    var makeActionBackend: @MainActor (CursorPresenting) -> ActionBackend
    /// A cursor, a visibility monitor and a window observer for each task.
    var makeSessionServices: @MainActor () -> TaskSessionServices
    var keyboardMonitor: GlobalKeyboardMonitor
    var pointerMovementObserver: PointerMovementObserver
    var userInputObserver: UserInputObserver
    var automatedTargetActivityRelay: AutomatedTargetActivityRelay
    var windowServerCapabilities: PrivateWindowServerCapabilities
    var attentionNotificationPoster: UserAttentionNotificationPoster
    var demonstrationRecorder: DemonstrationRecorder
    var routineLibraryStore: RoutineLibraryStore
    /// nil when the undo journal folder couldn't be created: direct routes are then off and every task uses the cursor.
    var directRouteExecutionDependencies: DirectRouteExecutionDependencies?
}

/// Everything a task owns from its first step on: its audit log, its Stop signal, the task-wide budget that planning,
/// teaching and the run all draw on, and its own action backend.
struct TaskStartResources {
    var taskIdentifier: String
    var auditLogWriter: AuditLogWriter
    var abortSignal: TaskAbortSignal
    var taskResourceBudget: TaskResourceBudget
    var actionBackend: ActionBackend
}

/// Composition-level coordinator for up to three tasks at once, each in a different app: owns their `TaskSession`s,
/// drives each one's planner and executor, answers its safety confirmations and keeps the command bar and each task's
/// checklist panel and cursor in sync.
/// Split per flow into `+Planning`, `+Run`, `+Decisions`, `+Pause`, `+ExecutionObserving`, `+Teaching`,
/// `+SavedRoutines`, `+Attention`, `+ForegroundAssist`, `+SummonHotkey`, `+SummonGesture`, `+AnthropicAPIKey` and `+DirectRoutes`. It deliberately conforms to none of the
/// executor's protocols: only a run-scoped `TaskRunDelegateBridge` is ever handed to Core.
@MainActor
final class TaskSessionController: ObservableObject {
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
    @Published var savedRoutines: [Routine] = []
    /// Routine files that weren't loaded (unsigned, edited outside Dotto, damaged, …), shown with the reason.
    @Published var skippedRoutineFiles: [SkippedRoutineFile] = []
    @Published var recordedDemonstrationEventCount: Int = 0
    /// What the recorder saw but couldn't record (typing in a web page, pasting an image), shown on the teaching card.
    @Published var demonstrationRecordingNotes: [String] = []
    /// Files and folders the user attached or dropped in the command bar; only these can be uploaded by the next task.
    @Published var attachedUploadGrants: [UploadFileGrant] = []
    @Published var cursorStyleConfiguration: CursorStyleConfiguration = .standard
    @Published var attentionPreferences: AttentionPreferences = .standard
    /// Background-first by default; the user can require a strict no-assist task before starting it.
    @Published var taskFocusPolicy: TaskFocusPolicy = .allowApprovedAssist
    @Published var liveViewCorner: ScreenCorner = .bottomRight
    /// The menu bar icon pulses while a decision waits for the user.
    @Published var isMenuBarIconPulsing = false
    let claudeTransport: ClaudeTransport
    let anthropicAPIKeyStore: AnthropicAPIKeyStore
    let makeActionBackend: @MainActor (CursorPresenting) -> ActionBackend
    let makeSessionServices: @MainActor () -> TaskSessionServices
    let userInputObserver: UserInputObserver
    let automatedTargetActivityRelay: AutomatedTargetActivityRelay
    let demonstrationRecorder: DemonstrationRecorder
    let routineLibraryStore: RoutineLibraryStore
    var commandBarPanelController: CommandBarPanelController?
    let attentionNotificationPoster: UserAttentionNotificationPoster
    let previousApplicationTracker = PreviousApplicationTracker()
    let keyboardMonitor: GlobalKeyboardMonitor
    let pointerMovementObserver: PointerMovementObserver
    var summonGestureController: SummonGestureController?
    let windowServerCapabilities: PrivateWindowServerCapabilities
    /// Where the user was when they summoned the command bar; the keyboard goes back there once the command is in.
    var applicationFrontmostWhenCommandBarWasSummoned: NSRunningApplication?
    /// Where the user last summoned Dotto, in top-left global points: the point the circle gesture fired at, or the
    /// pointer when the shortcut opened the command bar. The next command's task starts its cursor there.
    var summonOriginOfNextCommandInTopLeftGlobalPoints: CGPoint?
    /// The file system, journal, script and shortcut runners direct routes use; nil turns direct routes off.
    let directRouteExecutionDependencies: DirectRouteExecutionDependencies?

    /// Only one task's app may be brought forward at a time; every task's run takes its turn here.
    let foregroundAssistTurnQueue = ForegroundAssistTurnQueue()
    /// Every task Dotto holds (one today).
    private(set) var sessions: [TaskSession] = []
    /// The session the code running right now works on. Its state is forwarded below under the names the flows and
    /// views already use; every entry point that belongs to a particular task sets it first (`withSession`).
    private(set) var currentSession: TaskSession
    private var sessionChangeSubscriptions: [ObjectIdentifier: AnyCancellable] = [:]
    /// Which covered task's live view is expanded; the others are chips stacked from the same corner.
    var liveViewStack = LiveViewStack()

    private var permissionPollingTimer: Timer?

    init(dependencies: TaskSessionControllerDependencies) {
        self.claudeTransport = dependencies.claudeTransport
        self.anthropicAPIKeyStore = dependencies.anthropicAPIKeyStore
        self.makeActionBackend = dependencies.makeActionBackend
        self.makeSessionServices = dependencies.makeSessionServices
        self.keyboardMonitor = dependencies.keyboardMonitor
        self.pointerMovementObserver = dependencies.pointerMovementObserver
        self.automatedTargetActivityRelay = dependencies.automatedTargetActivityRelay
        self.windowServerCapabilities = dependencies.windowServerCapabilities
        self.attentionNotificationPoster = dependencies.attentionNotificationPoster
        self.userInputObserver = dependencies.userInputObserver
        self.demonstrationRecorder = dependencies.demonstrationRecorder
        self.routineLibraryStore = dependencies.routineLibraryStore
        self.directRouteExecutionDependencies = dependencies.directRouteExecutionDependencies
        self.permissionStatus = SystemPermissions.readCurrentStatus()
        let firstSession = TaskSession(services: dependencies.makeSessionServices())
        self.currentSession = firstSession
        refreshAnthropicAPIKeyState()
        adoptSession(firstSession)
    }

    // MARK: - Sessions

    /// Runs `body` on `session`'s state. Everything a particular task triggers (its pill, its checklist, its run's
    /// callbacks, an observer event for its app, its async work after each suspension) comes through here.
    @discardableResult
    func withSession<Result>(_ session: TaskSession, _ body: () -> Result) -> Result {
        let previousSession = currentSession
        currentSession = session
        defer { currentSession = previousSession }
        return body()
    }

    /// Makes `session` the one the command bar, the menu bar and the next command work on. Called only from entry
    /// points outside any `withSession`, which would otherwise put the previous session back.
    func focus(_ session: TaskSession) {
        currentSession = session
    }

    var sessionSummaries: [TaskSessionSummary] {
        sessions.map { session in
            var isRecordingDemonstration = false
            var isShowingResult = false
            switch session.sessionState {
            case .demonstrating: isRecordingDemonstration = true
            case .finished, .failed, .aborted: isShowingResult = true
            default: break
            }
            return TaskSessionSummary(isActive: session.sessionState != .idle && !isShowingResult, isShowingResult: isShowingResult,
                                      isRecordingDemonstration: isRecordingDemonstration,
                                      targetProcessIdentifier: session.targetApplication?.processIdentifier)
        }
    }

    /// Sessions holding a task (going, or a result not yet dismissed), in the order they were made.
    var sessionsWithTasks: [TaskSession] { sessions.filter { $0.sessionState != .idle } }
    var anySessionIsBusy: Bool { sessions.contains { $0.sessionState.isBusy } }
    var anotherTaskCanStart: Bool { ConcurrentTaskPolicy.anotherTaskCanStart(sessions: sessionSummaries) }

    /// The session a new task for the app with `targetProcessIdentifier` starts in: an idle one, or a new one while
    /// fewer than three tasks are going. nil after showing the task that app already has (one task per app), or when
    /// three tasks are already going.
    func sessionForNewTask(targetProcessIdentifier: pid_t?) -> TaskSession? {
        switch ConcurrentTaskPolicy.decision(forSummoningInto: targetProcessIdentifier, sessions: sessionSummaries) {
        case .useSession(let index):
            return sessions[index]
        case .createSession:
            let newSession = TaskSession(services: makeSessionServices())
            adoptSession(newSession)
            wireSessionServices(newSession)
            return newSession
        case .showExistingTask(let index):
            withSession(sessions[index]) { checklistPanelController?.showChecklistPanel(makeKey: false) }
            return nil
        case .refuseBecauseTaskLimitReached:
            NSSound.beep()
            return nil
        }
    }

    func stopAllTasks() {
        for session in sessions { withSession(session) { stopTask() } }
    }

    /// The session holding the pending question or answer with this identifier, if any.
    func session(owningAttentionRequestIdentifier attentionRequestIdentifier: String?) -> TaskSession? {
        guard let attentionRequestIdentifier else { return nil }
        return sessions.first { $0.cursorController.viewModel.presentationState.attentionRequest?.requestIdentifier == attentionRequestIdentifier }
    }

    private func adoptSession(_ session: TaskSession) {
        sessions.append(session)
        // Views observe the controller; a change inside a session must redraw them.
        sessionChangeSubscriptions[ObjectIdentifier(session)] = session.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        session.onSessionStateDidChange = { [weak self] in
            self?.summonGestureController?.refreshObservation()
        }
    }

    /// The per-task services report back into their own session.
    private func wireSessionServices(_ session: TaskSession) {
        let sessionScope = TaskSessionScope(taskSessionController: self, session: session)
        session.scope = sessionScope
        let checklistPanelController = ChecklistPanelController(sessionScope: sessionScope)
        session.checklistPanelController = checklistPanelController
        session.targetWindowObserver.onTargetWindowEvent = { [weak self, weak session] targetWindowEvent in
            guard let self, let session else { return }
            self.withSession(session) { self.routeTargetWindowEvent(targetWindowEvent) }
        }
        session.visibilityMonitor.onVisibilityChanged = { [weak session] targetWindowVisibility in
            session?.cursorController.updateTargetWindowVisibility(targetWindowVisibility)
        }
        session.cursorController.onTargetWindowChanged = { [weak session] changedTargetWindow in
            guard let session else { return }
            session.visibilityMonitor.startMonitoring(changedTargetWindow, targetPointInWindow: { [weak session] in
                session?.cursorController.viewModel.presentationState.targetPointInWindow
            })
        }
        checklistPanelController.onVisibilityChanged = { [weak session] checklistIsOpen in
            session?.cursorController.checklistIsOpen = checklistIsOpen
        }
        session.cursorController.onChecklistToggleRequested = { [weak self, weak session] in
            guard let self, let session else { return }
            self.withSession(session) { self.toggleChecklistBesideCursor() }
        }
        wireLiveViewStacking(for: session)
        wireAttentionDelivery(for: session)
    }

    // MARK: - Lifecycle

    func start() {
        loadTaskFocusPolicy()
        commandBarPanelController = CommandBarPanelController(taskSessionController: self)
        previousApplicationTracker.shouldIgnoreActivation = { [weak self] activatedApplication in
            // A target coming forward for an approved assist isn't where the user was.
            guard let self else { return false }
            return self.sessions.contains { session in
                session.cursorController.isForegroundAssistActive
                    && activatedApplication.processIdentifier == session.targetApplication?.processIdentifier
            }
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
        automatedTargetActivityRelay.onAutomatedTargetActivity = { [weak self] automatedActivity, timestampSeconds, targetProcessIdentifier in
            self?.routeAutomatedTargetActivity(automatedActivity, atTimestampSeconds: timestampSeconds,
                                               targetProcessIdentifier: targetProcessIdentifier)
        }
        startAttentionDelivery()
        for session in sessions { wireSessionServices(session) }
        startSummonGesture()

        permissionPollingTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshPermissionStatus()
            }
        }
    }

    func stop() {
        permissionPollingTimer?.invalidate()
        permissionPollingTimer = nil
        stopAllTasks()
        keyboardMonitor.stop()
        summonGestureController?.stop()
        for session in sessions {
            withSession(session) {
                stopRunObservers()
                cursorController.putCursorAway()
                checklistPanelController?.hideChecklistPanel()
            }
        }
        userInputObserver.stopObservingForEveryHolder()
        commandBarPanelController?.hideCommandBar()
    }

    // MARK: - Command bar

    /// After Dotto's own file picker: the command bar takes the keyboard again, without activating Dotto.
    func returnKeyboardToCommandBar() {
        commandBarPanelController?.makeCommandBarKeyIfVisible()
    }

    /// A new task for the app in front, unless that app already has one (its checklist opens instead) or three tasks
    /// are already going.
    func showCommandBar() {
        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        let frontmostProcessIdentifier = frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
            ? nil : frontmostApplication?.processIdentifier
        guard let sessionForCommand = sessionForNewTask(targetProcessIdentifier: frontmostProcessIdentifier) else { return }
        focus(sessionForCommand)
        assignTaskColor(to: sessionForCommand)
        captureFrontmostApplicationAsTarget()
        applicationFrontmostWhenCommandBarWasSummoned = NSWorkspace.shared.frontmostApplication
        showCommandPillAtPointer(prefilledCommandText: "")
    }

    /// Edit command, on a failed task: the pill opens again at the pointer with the task's command in it, for the same
    /// session (which the caller has focused).
    func reopenCommandBarWithPreviousCommand() {
        showCommandPillAtPointer(prefilledCommandText: lastSubmittedCommandText)
    }

    private func showCommandPillAtPointer(prefilledCommandText: String) {
        let pointerLocation = ScreenGeometry.mouseLocationInTopLeftGlobalPoints
        summonOriginOfNextCommandInTopLeftGlobalPoints = pointerLocation
        commandBarPanelController?.showCommandPill(
            atTopLeftGlobalPoint: pointerLocation, reducesMotion: summonGestureReducesMotion,
            prefilledCommandText: prefilledCommandText,
            onDismiss: { [weak self] in self?.previousApplicationTracker.handActivationBackIfThisAppIsActive() })
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
        currentSession.sessionState = nextState
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
                                  taskResourceBudget: TaskResourceBudget(safetyLimits: .standard),
                                  actionBackend: makeActionBackend(currentSession.cursorController))
    }

    func adoptTaskStartResources(_ taskStartResources: TaskStartResources) {
        currentAuditLogWriter = taskStartResources.auditLogWriter
        currentAuditLogFileURL = taskStartResources.auditLogWriter.logFileURL
        currentAbortSignal = taskStartResources.abortSignal
        currentTaskResourceBudget = taskStartResources.taskResourceBudget
        currentSession.actionBackend = taskStartResources.actionBackend
        assignTaskColor(to: currentSession)
    }

    /// The owner's style with this session's own task color.
    func styleConfiguration(for session: TaskSession) -> CursorStyleConfiguration {
        var sessionStyleConfiguration = cursorStyleConfiguration
        if let taskColorHex = session.taskColorHex { sessionStyleConfiguration.taskColorHex = taskColorHex }
        return sessionStyleConfiguration
    }

    /// The current session's style, for its own panels.
    var taskStyleConfiguration: CursorStyleConfiguration { styleConfiguration(for: currentSession) }

    /// A color no other task that is still going uses, so the user can tell running tasks apart. Assigned when the
    /// command bar opens for the task, so the bar is already in the color the task will run in.
    func assignTaskColor(to session: TaskSession) {
        let colorHexesInUse = sessions.filter { $0 !== session && $0.sessionState != .idle }.compactMap(\.taskColorHex)
        session.taskColorHex = TaskColorPalette.colorHex(forNewTaskWithOwnerTaskColorHex: cursorStyleConfiguration.taskColorHex,
                                                         colorHexesInUse: colorHexesInUse)
        session.cursorController.styleConfiguration = styleConfiguration(for: session)
    }

    func resetPerTaskResources() {
        currentSession.resetPerTaskResources(taskFocusPolicyForNextTask: taskFocusPolicy)
        liveViewStack.forgetUserChoice(currentSession.sessionIdentifier)
        directRouteSessionState.clearTaskResult()
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

// MARK: - The current session's state

/// Forwarded to `currentSession` under the names the per-flow extensions and the views already use, so moving the state
/// into `TaskSession` changes no behavior. Flows move to explicit sessions as Dotto learns to run several at once.
extension TaskSessionController {
    var sessionState: TaskSessionState { currentSession.sessionState }
    var targetApplication: TargetApplicationReference? {
        get { currentSession.targetApplication }
        set { currentSession.targetApplication = newValue }
    }
    var statusLine: String {
        get { currentSession.statusLine }
        set { currentSession.statusLine = newValue }
    }
    var currentRunMetrics: TaskRunMetrics? {
        get { currentSession.currentRunMetrics }
        set { currentSession.currentRunMetrics = newValue }
    }
    var attachedRoutine: Routine? {
        get { currentSession.attachedRoutine }
        set { currentSession.attachedRoutine = newValue }
    }
    var learnedRoutineAwaitingReview: Routine? {
        get { currentSession.learnedRoutineAwaitingReview }
        set { currentSession.learnedRoutineAwaitingReview = newValue }
    }
    var taughtRoutineAwaitingReview: Routine? {
        get { currentSession.taughtRoutineAwaitingReview }
        set { currentSession.taughtRoutineAwaitingReview = newValue }
    }
    var currentAuditLogFileURL: URL? {
        get { currentSession.currentAuditLogFileURL }
        set { currentSession.currentAuditLogFileURL = newValue }
    }
    var plannerConversationTranscript: PlannerConversationTranscript {
        get { currentSession.plannerConversationTranscript }
        set { currentSession.plannerConversationTranscript = newValue }
    }
    var currentPlanningProgress: ChecklistPlanningProgress? {
        get { currentSession.currentPlanningProgress }
        set { currentSession.currentPlanningProgress = newValue }
    }
    var currentTaskFocusPolicy: TaskFocusPolicy {
        get { currentSession.currentTaskFocusPolicy }
        set { currentSession.currentTaskFocusPolicy = newValue }
    }
    var currentAuditLogWriter: AuditLogWriter? {
        get { currentSession.currentAuditLogWriter }
        set { currentSession.currentAuditLogWriter = newValue }
    }
    var currentAbortSignal: TaskAbortSignal? {
        get { currentSession.currentAbortSignal }
        set { currentSession.currentAbortSignal = newValue }
    }
    var currentTaskResourceBudget: TaskResourceBudget? {
        get { currentSession.currentTaskResourceBudget }
        set { currentSession.currentTaskResourceBudget = newValue }
    }
    var currentTeachingAbortSignal: TaskAbortSignal? {
        get { currentSession.currentTeachingAbortSignal }
        set { currentSession.currentTeachingAbortSignal = newValue }
    }
    var currentUploadFileAllowlist: UploadFileAllowlist {
        get { currentSession.currentUploadFileAllowlist }
        set { currentSession.currentUploadFileAllowlist = newValue }
    }
    var foregroundAssistCountdownWasCancelled: Bool {
        get { currentSession.foregroundAssistCountdownWasCancelled }
        set { currentSession.foregroundAssistCountdownWasCancelled = newValue }
    }
    var currentTaskSummonOriginInTopLeftGlobalPoints: CGPoint? {
        get { currentSession.currentTaskSummonOriginInTopLeftGlobalPoints }
        set { currentSession.currentTaskSummonOriginInTopLeftGlobalPoints = newValue }
    }
    var currentPlanningOrExecutionTask: Task<Void, Never>? {
        get { currentSession.currentPlanningOrExecutionTask }
        set { currentSession.currentPlanningOrExecutionTask = newValue }
    }
    var currentRunControl: TaskRunControl? {
        get { currentSession.currentRunControl }
        set { currentSession.currentRunControl = newValue }
    }
    var userTakeoverDetector: UserTakeoverDetector {
        get { currentSession.userTakeoverDetector }
        set { currentSession.userTakeoverDetector = newValue }
    }
    var lastSubmittedCommandText: String {
        get { currentSession.lastSubmittedCommandText }
        set { currentSession.lastSubmittedCommandText = newValue }
    }
    var commandSubmittedAtSystemUptime: TimeInterval? {
        get { currentSession.commandSubmittedAtSystemUptime }
        set { currentSession.commandSubmittedAtSystemUptime = newValue }
    }
    var frontmostApplicationProcessIdentifierWhenCommandWasSubmitted: pid_t? {
        get { currentSession.frontmostApplicationProcessIdentifierWhenCommandWasSubmitted }
        set { currentSession.frontmostApplicationProcessIdentifierWhenCommandWasSubmitted = newValue }
    }
    var actionBackend: ActionBackend? { currentSession.actionBackend }
    var mostRecentlyStartedRunTask: Task<Void, Never>? {
        get { currentSession.mostRecentlyStartedRunTask }
        set { currentSession.mostRecentlyStartedRunTask = newValue }
    }
    var directRouteSessionState: DirectRouteSessionState { currentSession.directRouteSessionState }
    var cursorController: CursorController { currentSession.cursorController }
    var visibilityMonitor: TargetWindowVisibilityMonitor { currentSession.visibilityMonitor }
    var targetWindowObserver: TargetWindowObserver { currentSession.targetWindowObserver }
    var checklistPanelController: ChecklistPanelController? { currentSession.checklistPanelController }
    var currentChecklistPlanner: ChecklistPlanner? {
        get { currentSession.currentChecklistPlanner }
        set { currentSession.currentChecklistPlanner = newValue }
    }
    var pendingSafetyConfirmation: PendingUserAnswer<SafetyConfirmationAnswer> { currentSession.pendingSafetyConfirmation }
    var pendingItemFailureDecision: PendingUserAnswer<ChecklistItemFailureDecision> { currentSession.pendingItemFailureDecision }
}
