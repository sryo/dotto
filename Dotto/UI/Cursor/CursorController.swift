import AppKit
import SwiftUI
import Combine

@MainActor
final class CursorViewModel: ObservableObject {
    @Published var presentationState: CursorPresentationState = .hidden
    @Published var appearance = CursorAppearance()
    @Published var cursorPointInWindow: CGPoint = CGPoint(x: 40, y: 40)
    /// Past cursor positions for the replay trail, newest first; empty unless replaying.
    @Published var replayTrailPointsInWindow: [CGPoint] = []
    @Published var surface: CursorSurface = .hidden
    @Published var latestFrame: CGImage?
    @Published var targetWindowSizeInPoints: CGSize = CGSize(width: 800, height: 600)
    @Published var isCollapsed = false
    @Published var styleConfiguration: CursorStyleConfiguration = .standard
    @Published var targetApplicationName: String = ""
    /// The running item's place in the checklist; nil before the first item.
    @Published var itemPosition: Int?
    @Published var itemCount: Int?
    @Published var liveViewCorner: ScreenCorner = .bottomRight
    /// Bounces the live view: on each attention nudge and when it's collapsed or expanded.
    @Published var liveViewBounceCount = 0
    /// Whether the checklist popover is open beside the cursor; the pill's chevron points up while it is.
    @Published var checklistIsOpen = false
    /// Where the click-through pill may go: every screen's visible frame, and the points the overlay's and the parked
    /// cursor's tips are measured from, all in top-left global points.
    @Published var screenVisibleFramesInTopLeftGlobalPoints: [CGRect] = []
    @Published var targetWindowOriginInTopLeftGlobalPoints: CGPoint = .zero
    @Published var parkedTipInTopLeftGlobalPoints: CGPoint = .zero
    /// The corner of the clickable pill panel the pill is drawn in: the one that faces the cursor's tip.
    @Published var pillPanelHorizontalSide: PillHorizontalSide = .rightOfTip
    @Published var pillPanelVerticalSide: PillVerticalSide = .belowTip
    /// True for the one update in which the clickable pill takes over from the command pill's morph: that pill must
    /// appear exactly as the morph ended, not animate into place.
    @Published var pillAnimationsAreSuppressed = false

    /// The answers the pill shows compactly. Stop is left out here: it is the pill's own trailing button
    /// (`appearance.offersStop`) for the whole run, not only while a question is up.
    var pillDecisionOptions: [UserDecisionOption] {
        appearance.decisionOptions.filter { $0.identifier != .stop }
    }

    /// "12/49" while items run; nil before the first item.
    var itemPositionText: String? {
        guard let itemPosition, let itemCount else { return nil }
        return "\(itemPosition)/\(itemCount)"
    }

    /// The overlay can't take clicks, so a pill with any button moves into its own clickable panel. While planning
    /// or a run is live the pill always carries Stop (with Pause and the checklist chevron during a run), whatever the
    /// status style: in ring style, or once the quiet style's text has faded, the pill shows just its buttons.
    var pillIsClickable: Bool {
        !pillDecisionOptions.isEmpty || appearance.offersStop || appearance.offersChecklistToggle
    }

    /// Read while the buttons render, so a click answers the question they were drawn for even if another one has
    /// replaced it by the time the click lands.
    func decisionHandlerForDisplayedQuestion(_ onDecisionOptionChosen: @escaping DecisionOptionHandler)
        -> (UserDecisionOptionIdentifier) -> Void {
        let displayedAttentionRequestIdentifier = appearance.attentionRequestIdentifier
        return { decisionOptionIdentifier in
            onDecisionOptionChosen(decisionOptionIdentifier, displayedAttentionRequestIdentifier)
        }
    }
}

/// The one cursor presenter. It folds executor, replay, safety and backend events into Core's
/// CursorPresentationState, animates flights in window-relative points, and shows the cursor on one of two surfaces:
/// a click-through overlay over the target window while it is visible, or a floating live view of the window while
/// it is covered, minimized or on another Space.
@MainActor
final class CursorController: CursorPresenting {
    let viewModel = CursorViewModel()
    /// The App starts the visibility monitor for each new task window.
    var onTargetWindowChanged: ((TargetWindowReference) -> Void)?
    /// A pill or live-view button was clicked (and wasn't ignored as too early); answered through the same path as
    /// the checklist card, which also checks the answer is still for the pending question.
    var onDecisionOptionChosen: ((UserDecisionAnswer) -> Void)?
    var onAttentionRequestChanged: ((UserAttentionRequest?) -> Void)?
    /// A decision still unanswered after `attentionNudgeIntervalSeconds`; the App replays the chime.
    var onAttentionNudge: ((UserAttentionRequest) -> Void)?
    /// The pill's or the live view's checklist chevron was clicked: the App opens or folds the checklist popover.
    var onChecklistToggleRequested: (() -> Void)?
    var attentionNudgeIntervalSeconds: TimeInterval = 15

    private(set) var isForegroundAssistActive = false
    private(set) var targetWindow: TargetWindowReference?

    private let frameStreamer: TargetWindowFrameStreaming
    private var placementPolicy = CursorSurfacePlacementPolicy()
    private var latestTargetWindowVisibility: TargetWindowVisibility?
    /// The window the live view should stream now: set while the expanded live view is showing, nil otherwise.
    private var desiredStreamingTargetWindow: TargetWindowReference?
    /// The window a started stream is capturing, as far as the serialized start/stop chain knows.
    private var activeStreamingWindowIdentifier: UInt32?
    /// Every start and stop runs after the previous one finished, so a slow startCapture can never race a stop and
    /// leave a stream running that nobody owns.
    private var streamLifecycleTask: Task<Void, Never>?
    private var decisionClickGuard = UserDecisionClickGuard()
    /// The run whose cursor this is; the backend's end-of-run hide only applies to it.
    private var owningRunAbortSignal: TaskAbortSignal?
    private var pausedStatusText: String?

    private var cursorFlightAnimationTask: Task<Void, Never>?
    private var pendingFlightArrivalContinuation: CheckedContinuation<Void, Never>?
    private var isFlying = false
    /// After a click lands the arrow stays pressed briefly, then returns to pointing.
    private var clickPressReleaseTask: Task<Void, Never>?
    private var isShowingClickPress = false
    private var quietPillHideTask: Task<Void, Never>?
    private var hideAfterRunFinishedTask: Task<Void, Never>?
    /// The placement policy only switches surfaces after a change has held for a while, but the monitor reports
    /// changes once, so the decision is re-evaluated on a timer while the cursor is up.
    private var surfaceReevaluationTask: Task<Void, Never>?
    /// Set once the cursor has been put away (run finished, stopped); only the next run brings it back, even though
    /// the finished state and its attention request stay readable for the live view's finished note.
    private var cursorIsPutAway = false
    /// From runStarted to runFinished (or a stop that hides the cursor): the pill and live view offer Stop.
    private var isRunLive = false
    /// From planningStarted until the checklist is ready (or planning stops): the pill offers Stop.
    private var isPlanningLive = false
    /// The parked cursor waits beside the checklist or the planner's question: its chevron still opens that popover.
    private var isWaitingOnUserBeforeRun = false
    /// Where the user summoned Dotto, in top-left global points. Planning and approval happen here, before the run
    /// knows its target window; the cursor leaves it once the run's window is adopted and its visibility is known.
    private var parkedTipInTopLeftGlobalPoints: CGPoint?
    private var attentionNudgeTask: Task<Void, Never>?

    private lazy var surfaces = CursorSurfaces(viewModel: viewModel, onDecisionOptionChosen: { [weak self] decisionOptionIdentifier, attentionRequestIdentifier in
        self?.handleDecisionButtonClick(decisionOptionIdentifier, attentionRequestIdentifier: attentionRequestIdentifier)
    }, onToggleLiveViewCollapsed: { [weak self] in
        self?.toggleLiveViewCollapsed()
    }, onToggleChecklist: { [weak self] in
        self?.onChecklistToggleRequested?()
    })

    init(frameStreamer: TargetWindowFrameStreaming) {
        self.frameStreamer = frameStreamer
        frameStreamer.onFrame = { [weak self] latestFrame in
            // A frame that was already in flight when its stream stopped must not repaint a collapsed or hidden view.
            guard let self, self.activeStreamingWindowIdentifier != nil, self.desiredStreamingTargetWindow != nil else { return }
            self.viewModel.latestFrame = latestFrame
        }
    }

    var styleConfiguration: CursorStyleConfiguration {
        get { viewModel.styleConfiguration }
        set { viewModel.styleConfiguration = newValue }
    }

    var targetApplicationName: String {
        get { viewModel.targetApplicationName }
        set { viewModel.targetApplicationName = newValue }
    }

    /// Where the live view docks; the menu bar panel's corner setting.
    var liveViewCorner: ScreenCorner {
        get { viewModel.liveViewCorner }
        set {
            guard newValue != viewModel.liveViewCorner else { return }
            viewModel.liveViewCorner = newValue
            surfaces.liveViewCornerDidChange()
        }
    }

    private var reducesMotion: Bool {
        viewModel.styleConfiguration.reducesMotion(systemReduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    /// Only flips the chevron; the pill's size doesn't change with it.
    var checklistIsOpen: Bool {
        get { viewModel.checklistIsOpen }
        set { if newValue != viewModel.checklistIsOpen { viewModel.checklistIsOpen = newValue } }
    }

    // MARK: - Planning

    /// Brings the cursor up where the user summoned Dotto, reading the target app, with Stop in its pill. There is no
    /// target window yet, so the cursor is parked at that point until the run adopts one. A command submitted from the
    /// pill at the pointer hands over its capsule: the status pill takes its place, and with `holdsStatusPillForMorph`
    /// it stays out until the command pill has morphed into it (`finishCommandPillHandoff`).
    func beginPlanning(atSummonOriginInTopLeftGlobalPoints summonOrigin: CGPoint, targetApplicationName: String,
                       commandPillHandoff: CommandPillHandoff? = nil, holdsStatusPillForMorph: Bool = false) {
        hideAfterRunFinishedTask?.cancel()
        hideAfterRunFinishedTask = nil
        owningRunAbortSignal = nil
        cursorIsPutAway = false
        isRunLive = false
        isPlanningLive = true
        isWaitingOnUserBeforeRun = false
        parkedTipInTopLeftGlobalPoints = summonOrigin
        targetWindow = nil
        placementPolicy = CursorSurfacePlacementPolicy()
        latestTargetWindowVisibility = nil
        viewModel.targetApplicationName = targetApplicationName
        viewModel.itemPosition = nil
        viewModel.itemCount = nil
        viewModel.isCollapsed = false
        surfaces.beginCommandPillHandoff(commandPillHandoff, holdsPillPanel: holdsStatusPillForMorph)
        handle(.planningStarted(targetApplicationName: targetApplicationName))
    }

    /// Where the held status pill will appear, in top-left global points: what the command pill morphs into.
    var heldStatusPillFrameForCommandPillHandoff: CGRect? {
        surfaces.heldPillFrameForCommandPillHandoff
    }

    /// The morph is over (or was cut short): the status pill panel shows now, in the same turn the morph goes away.
    func finishCommandPillHandoff() {
        surfaces.finishCommandPillHandoff(targetWindow: targetWindow)
    }

    func showPlanningProgress(_ planningProgress: ChecklistPlanningProgress) {
        guard isPlanningLive else { return }
        handle(.planningProgressed(planningProgress))
    }

    /// Planning is over; the parked cursor waits while the user reviews the checklist attached to it.
    func showChecklistReadyForReview() {
        isPlanningLive = false
        isWaitingOnUserBeforeRun = true
        handle(.checklistReadyForReview)
    }

    /// Planning ended with a question for the user; the parked cursor waits beside the thread that asks it.
    func showPlannerNeedsInput() {
        isPlanningLive = false
        isWaitingOnUserBeforeRun = true
        handle(.plannerAskedForInput)
    }

    /// The user answered the planner's question: the cursor thinks again, with Stop, where it waited.
    func resumePlanningAfterReply() {
        guard !cursorIsPutAway, viewModel.presentationState.activity != .hidden else { return }
        isPlanningLive = true
        isWaitingOnUserBeforeRun = false
        handle(.planningProgressed(.thinking))
    }

    /// Where a panel that belongs to the cursor (the checklist) should hang right now: beside the cursor's tip and pill,
    /// or beside the live view while the target window is covered. nil while the cursor isn't showing.
    func anchorForAttachedPanels() -> AttachedPanelAnchor? {
        guard !cursorIsPutAway, viewModel.presentationState.activity != .hidden else { return nil }
        return surfaces.anchorForAttachedPanels(targetWindow: targetWindow)
    }

    // MARK: - CursorPresenting

    /// Starts a run's cursor and remembers which run owns it. With a summon origin the cursor starts there (it may
    /// already be parked there from planning) and stays until the run's window is known.
    func beginRun(ownedByRunWith runAbortSignal: TaskAbortSignal, startingAtSummonOriginInTopLeftGlobalPoints summonOrigin: CGPoint?) {
        owningRunAbortSignal = runAbortSignal
        if let summonOrigin { parkedTipInTopLeftGlobalPoints = summonOrigin }
        handle(.runStarted(targetWindow: nil))
    }

    func handle(_ cursorActivityEvent: CursorActivityEvent) {
        switch cursorActivityEvent {
        case .runStarted(let startingTargetWindow):
            hideAfterRunFinishedTask?.cancel()
            hideAfterRunFinishedTask = nil
            cursorIsPutAway = false
            isRunLive = true
            isPlanningLive = false
            isWaitingOnUserBeforeRun = false
            // Every run adopts its window afresh, which (re)starts the visibility monitor for it.
            targetWindow = nil
            placementPolicy = CursorSurfacePlacementPolicy()
            latestTargetWindowVisibility = nil
            viewModel.itemPosition = nil
            viewModel.itemCount = nil
            viewModel.isCollapsed = false
            if let startingTargetWindow { adoptTargetWindow(startingTargetWindow) }
        case .targetWindowChanged(let changedTargetWindow):
            adoptTargetWindow(changedTargetWindow)
        case .itemStarted(_, let startedItemPosition, let startedItemCount):
            viewModel.itemPosition = startedItemPosition
            viewModel.itemCount = startedItemCount
        case .paused(let pauseReason):
            pausedStatusText = pauseReason.pausedStatusText(targetApplicationName: viewModel.targetApplicationName)
        case .foregroundAssistStarted:
            isForegroundAssistActive = true
        case .foregroundAssistFinished:
            isForegroundAssistActive = false
        case .runFinished:
            isRunLive = false
        default:
            break
        }

        let previousAttentionRequest = viewModel.presentationState.attentionRequest
        viewModel.presentationState = CursorPresentationStateMapper.nextState(from: viewModel.presentationState, on: cursorActivityEvent)
        applyPresentationState()
        if viewModel.presentationState.attentionRequest != previousAttentionRequest {
            onAttentionRequestChanged?(viewModel.presentationState.attentionRequest)
            restartAttentionNudges(for: viewModel.presentationState.attentionRequest)
        }

        if case .runFinished = cursorActivityEvent {
            // Presenter policy: the done check or the stuck shake stays readable for a moment, then the cursor goes.
            // The live view keeps its docked "finished" note up a little longer, as the lab does.
            let secondsBeforeHiding: Double = viewModel.surface == .liveViewPanel ? 4.2 : 1.2
            hideAfterRunFinishedTask?.cancel()
            hideAfterRunFinishedTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(secondsBeforeHiding * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                self.hideAfterRunFinishedTask = nil
                self.hideCursorKeepingAttention()
            }
        }
    }

    func flyCursor(toWindowRelativePoint windowRelativePoint: CGPoint, in flightTargetWindow: TargetWindowReference,
                   actionKind: CursorActionKind) async {
        if flightTargetWindow.windowIdentifier != targetWindow?.windowIdentifier {
            handle(.targetWindowChanged(flightTargetWindow))
        } else {
            targetWindow = flightTargetWindow
        }
        // Taken before the action event, which moves the presented cursor to the target and would make the flight zero length.
        let flightStartPoint = viewModel.cursorPointInWindow
        handle(.actionTargeted(actionKind, windowRelativePoint: windowRelativePoint))
        guard viewModel.presentationState.activity != .hidden, !cursorIsPutAway else { return }
        // A new flight supersedes the previous one; its caller must not wait forever.
        cancelCursorFlight()

        let flightPath = CursorFlightPath(startPoint: flightStartPoint, endPoint: windowRelativePoint,
                                          motionSpeed: viewModel.styleConfiguration.motionSpeed)
        let maximumFlightSeconds: Double = [.typing, .pressingKey].contains(actionKind) ? 0 : 0.35
        let flightDurationSeconds = reducesMotion ? 0 : min(flightPath.durationSeconds, maximumFlightSeconds)
        guard flightDurationSeconds > 0 else {
            viewModel.cursorPointInWindow = windowRelativePoint
            landFlight(actionKind: actionKind)
            return
        }

        isFlying = true
        applyPresentationState()
        let tracksReplayTrail = viewModel.presentationState.activity == .replaying
        await withCheckedContinuation { (arrivalContinuation: CheckedContinuation<Void, Never>) in
            pendingFlightArrivalContinuation = arrivalContinuation
            cursorFlightAnimationTask = Task { @MainActor [weak self] in
                let flightStartDate = Date()
                var recentCursorPoints: [CGPoint] = []
                while !Task.isCancelled {
                    guard let self else { return }
                    let linearProgress = min(Date().timeIntervalSince(flightStartDate) / flightDurationSeconds, 1.0)
                    self.viewModel.cursorPointInWindow = flightPath.point(atLinearProgress: linearProgress)
                    // The clickable pill lives in its own panel, which has to follow the tip frame by frame.
                    if self.viewModel.pillIsClickable { self.surfaces.refreshPillPanel(targetWindow: self.targetWindow) }
                    if tracksReplayTrail {
                        recentCursorPoints.append(self.viewModel.cursorPointInWindow)
                        self.viewModel.replayTrailPointsInWindow = Self.replayTrailPoints(fromRecentCursorPoints: recentCursorPoints)
                    }
                    if linearProgress >= 1.0 {
                        self.cursorFlightAnimationTask = nil
                        self.landFlight(actionKind: actionKind)
                        return
                    }
                    try? await Task.sleep(nanoseconds: 16_666_667)
                }
            }
        }
    }

    func cancelCursorFlight() {
        cursorFlightAnimationTask?.cancel()
        cursorFlightAnimationTask = nil
        if isFlying {
            isFlying = false
            applyPresentationState()
        }
        resumeFlightCaller()
    }

    func hideCursor() {
        hideCursor(ownedByRunWith: nil)
    }

    func hideCursor(ownedByRunWith runAbortSignal: TaskAbortSignal?) {
        if let runAbortSignal {
            guard runAbortSignal === owningRunAbortSignal else { return }
        } else if isRunLive || isPlanningLive {
            return
        }
        // The done check or stuck shake stays up for its moment; that timer puts the cursor away.
        guard hideAfterRunFinishedTask == nil else { return }
        isRunLive = false
        hideCursorKeepingAttention()
    }

    /// Stop, dismiss, teaching and quit: the cursor goes now, with any question it carried. Attention request ids
    /// keep counting, so a late answer to a question from before can never match a later one.
    func putCursorAway() {
        owningRunAbortSignal = nil
        isRunLive = false
        isPlanningLive = false
        hideCursorKeepingAttention()
        let previousAttentionRequest = viewModel.presentationState.attentionRequest
        viewModel.presentationState = viewModel.presentationState.hiddenKeepingAttentionRequestCount
        applyPresentationState()
        if previousAttentionRequest != nil { onAttentionRequestChanged?(nil) }
    }

    /// The App forwards the visibility monitor's output here, about four times a second.
    func updateTargetWindowVisibility(_ targetWindowVisibility: TargetWindowVisibility) {
        latestTargetWindowVisibility = targetWindowVisibility
        if let targetWindow, let currentFrame = ScreenGeometry.frameInTopLeftGlobalPoints(ofWindowIdentifier: targetWindow.windowIdentifier) {
            self.targetWindow?.frameInTopLeftGlobalPoints = currentFrame
            viewModel.targetWindowSizeInPoints = currentFrame.size
        }
        updateSurfaces()
    }

    func toggleLiveViewCollapsed() {
        viewModel.isCollapsed.toggle()
        viewModel.liveViewBounceCount += 1
        // Collapsed, the live view shows no picture, so it doesn't capture one either.
        updateStreamingIntent()
    }

    private func handleDecisionButtonClick(_ decisionOptionIdentifier: UserDecisionOptionIdentifier, attentionRequestIdentifier: String?) {
        guard decisionClickGuard.acceptsClick(on: decisionOptionIdentifier, atUptimeSeconds: ProcessInfo.processInfo.systemUptime) else {
            return
        }
        // Stop isn't an answer to the question beside it; it stops whatever runs now.
        let answeredAttentionRequestIdentifier = decisionOptionIdentifier == .stop ? nil : attentionRequestIdentifier
        onDecisionOptionChosen?(UserDecisionAnswer(optionIdentifier: decisionOptionIdentifier,
                                                   attentionRequestIdentifier: answeredAttentionRequestIdentifier))
    }

    // MARK: - Presentation

    /// The lab hops the pill (or bounces the live view) when a question appears, then chimes and hops again every
    /// 15 s until it's answered. Paused never nudges: the user caused it.
    private func restartAttentionNudges(for attentionRequest: UserAttentionRequest?) {
        attentionNudgeTask?.cancel()
        attentionNudgeTask = nil
        guard let attentionRequest, !attentionRequest.decisionOptions.isEmpty else { return }
        viewModel.appearance.attentionNudgeCount += 1
        viewModel.liveViewBounceCount += 1
        let nudgeIntervalNanoseconds = UInt64(max(attentionNudgeIntervalSeconds, 5) * 1_000_000_000)
        attentionNudgeTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: nudgeIntervalNanoseconds)
                guard let self, !Task.isCancelled, self.isRunLive, !self.cursorIsPutAway,
                      self.viewModel.presentationState.attentionRequest?.requestIdentifier == attentionRequest.requestIdentifier else { return }
                self.viewModel.appearance.attentionNudgeCount += 1
                self.viewModel.liveViewBounceCount += 1
                self.onAttentionNudge?(attentionRequest)
            }
        }
    }

    private func hideCursorKeepingAttention() {
        cursorIsPutAway = true
        isPlanningLive = false
        isWaitingOnUserBeforeRun = false
        parkedTipInTopLeftGlobalPoints = nil
        hideAfterRunFinishedTask?.cancel()
        hideAfterRunFinishedTask = nil
        attentionNudgeTask?.cancel()
        attentionNudgeTask = nil
        cursorFlightAnimationTask?.cancel()
        cursorFlightAnimationTask = nil
        isFlying = false
        resumeFlightCaller()
        clickPressReleaseTask?.cancel()
        isShowingClickPress = false
        quietPillHideTask?.cancel()
        isForegroundAssistActive = false
        pausedStatusText = nil
        viewModel.replayTrailPointsInWindow = []
        viewModel.surface = .hidden
        placementPolicy = CursorSurfacePlacementPolicy()
        surfaceReevaluationTask?.cancel()
        surfaceReevaluationTask = nil
        surfaces.show(.hidden, targetWindow: targetWindow, parkedTipInTopLeftGlobalPoints: nil, reducesMotion: true)
        updateStreamingIntent()
    }

    private func adoptTargetWindow(_ adoptedTargetWindow: TargetWindowReference) {
        let windowChanged = adoptedTargetWindow.windowIdentifier != targetWindow?.windowIdentifier
        targetWindow = adoptedTargetWindow
        if let parkedTipInTopLeftGlobalPoints {
            // The run's first flight starts where the user summoned Dotto.
            let windowOrigin = adoptedTargetWindow.frameInTopLeftGlobalPoints.origin
            viewModel.cursorPointInWindow = CGPoint(x: parkedTipInTopLeftGlobalPoints.x - windowOrigin.x,
                                                    y: parkedTipInTopLeftGlobalPoints.y - windowOrigin.y)
        }
        viewModel.targetWindowSizeInPoints = adoptedTargetWindow.frameInTopLeftGlobalPoints.size
        guard windowChanged else { return }
        latestTargetWindowVisibility = nil
        viewModel.latestFrame = nil
        onTargetWindowChanged?(adoptedTargetWindow)
        updateStreamingIntent()
    }

    private func landFlight(actionKind: CursorActionKind) {
        isFlying = false
        viewModel.replayTrailPointsInWindow = []
        if [.click, .doubleClick, .rightClick, .attachingFiles].contains(actionKind) {
            viewModel.appearance.clickRippleCount += 1
            isShowingClickPress = true
            clickPressReleaseTask?.cancel()
            clickPressReleaseTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard let self, !Task.isCancelled else { return }
                self.isShowingClickPress = false
                self.applyPresentationState()
            }
        }
        applyPresentationState()
        resumeFlightCaller()
    }

    private func resumeFlightCaller() {
        // Cleared before resuming so a re-entrant flyCursor from the resumed caller can't resume it twice.
        let arrivalContinuation = pendingFlightArrivalContinuation
        pendingFlightArrivalContinuation = nil
        arrivalContinuation?.resume()
    }

    private func applyPresentationState() {
        let presentationState = viewModel.presentationState
        guard presentationState.activity != .hidden, !cursorIsPutAway else {
            if viewModel.surface != .hidden { hideCursorKeepingAttention() }
            return
        }
        if !isFlying, let targetPointInWindow = presentationState.targetPointInWindow {
            viewModel.cursorPointInWindow = targetPointInWindow
        }

        var displayedActivity = presentationState.activity
        if isFlying && displayedActivity == .clicking { displayedActivity = .pointing }
        if displayedActivity == .clicking && !isShowingClickPress { displayedActivity = .pointing }

        var nextAppearance = viewModel.appearance
        if displayedActivity == .error && nextAppearance.activity != .error {
            nextAppearance.errorShakeCount += 1
        }
        nextAppearance.activity = displayedActivity
        nextAppearance.pillText = CursorPillText.text(for: presentationState, targetApplicationName: viewModel.targetApplicationName,
                                                      pausedStatusText: pausedStatusText, itemPosition: viewModel.itemPosition,
                                                      itemCount: viewModel.itemCount)
        nextAppearance.showsTypingCaret = displayedActivity == .typing
        nextAppearance.replayProgress = presentationState.replayStepProgress.map { replayStepProgress in
            replayStepProgress.stepCount > 0 ? Double(replayStepProgress.completedStepCount) / Double(replayStepProgress.stepCount) : 0
        } ?? presentationState.progress ?? 0
        nextAppearance.decisionOptions = presentationState.decisionOptions
        nextAppearance.attentionRequestIdentifier = presentationState.attentionRequest?.requestIdentifier
        nextAppearance.offersStop = isRunLive || isPlanningLive
        // Pause only while Dotto is working: not while it waits on the user, is paused, or has finished.
        nextAppearance.offersPause = isRunLive && presentationState.decisionOptions.isEmpty
            && ![.waiting, .paused, .done, .error].contains(presentationState.activity)
        // Only while the popover has something to show: the planning thread, the checklist under review, or the run's.
        nextAppearance.offersChecklistToggle = isRunLive || isPlanningLive || isWaitingOnUserBeforeRun
        nextAppearance.readingRingText = viewModel.targetApplicationName.isEmpty
            ? "reading · reading" : "reading \(viewModel.targetApplicationName)"
        if nextAppearance.pillText != viewModel.appearance.pillText || nextAppearance.activity != viewModel.appearance.activity {
            nextAppearance.isPillQuietlyHidden = false
            scheduleQuietPillHide()
        }
        if nextAppearance != viewModel.appearance { viewModel.appearance = nextAppearance }
        noteDisplayedQuestion()
        updateSurfaces()
    }

    /// Re-arms the click delay whenever the buttons start answering something else: a new request, new wording or
    /// new options.
    private func noteDisplayedQuestion() {
        let displayedAnswerOptions = viewModel.pillDecisionOptions
        let questionSignature = displayedAnswerOptions.isEmpty ? nil : [
            viewModel.appearance.attentionRequestIdentifier ?? "none", viewModel.appearance.pillText,
            displayedAnswerOptions.map(\.identifier.rawValue).joined(separator: ","),
        ].joined(separator: "|")
        decisionClickGuard.noteDisplayedQuestion(signature: questionSignature, atUptimeSeconds: ProcessInfo.processInfo.systemUptime)
    }

    private func scheduleQuietPillHide() {
        quietPillHideTask?.cancel()
        guard viewModel.styleConfiguration.statusStyle == .quiet else { return }
        quietPillHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_700_000_000)
            guard let self, !Task.isCancelled else { return }
            self.viewModel.appearance.isPillQuietlyHidden = true
            self.surfaces.refreshPillPanel(targetWindow: self.targetWindow)
        }
    }

    /// The lab keeps the last 24 frames and draws ghosts 6, 12 and 18 frames back.
    private static func replayTrailPoints(fromRecentCursorPoints recentCursorPoints: [CGPoint]) -> [CGPoint] {
        [6, 12, 18].map { framesBack in recentCursorPoints[max(0, recentCursorPoints.count - 1 - framesBack)] }
    }

    // MARK: - Surfaces

    private func updateSurfaces() {
        let cursorIsShowable = viewModel.presentationState.activity != .hidden && !cursorIsPutAway
        let cursorIsActive = cursorIsShowable && targetWindow != nil
        let nextSurface: CursorSurface
        if cursorIsShowable, parkedTipInTopLeftGlobalPoints != nil, targetWindow == nil || latestTargetWindowVisibility == nil {
            // Planning, approval, and a run that hasn't reported its window (or its window's visibility) yet.
            nextSurface = .parkedAtSummonOrigin
        } else if let latestTargetWindowVisibility {
            var visibilityWithCurrentPoint = latestTargetWindowVisibility
            visibilityWithCurrentPoint.observedAtUptimeSeconds = ProcessInfo.processInfo.systemUptime
            nextSurface = placementPolicy.surface(for: visibilityWithCurrentPoint, cursorIsActive: cursorIsActive)
            if nextSurface != .hidden { parkedTipInTopLeftGlobalPoints = nil }
        } else {
            // Until the monitor reports, nothing is known about the window: show nothing rather than guess.
            nextSurface = cursorIsActive && viewModel.surface != .parkedAtSummonOrigin ? viewModel.surface : .hidden
        }

        viewModel.surface = nextSurface
        surfaces.show(nextSurface, targetWindow: targetWindow, parkedTipInTopLeftGlobalPoints: parkedTipInTopLeftGlobalPoints,
                      reducesMotion: reducesMotion)
        updateStreamingIntent()
        if cursorIsActive && surfaceReevaluationTask == nil {
            surfaceReevaluationTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    guard let self, !Task.isCancelled else { return }
                    self.updateSurfaces()
                }
            }
        }
    }

    // MARK: - Live view stream

    /// Streams only while the expanded live view is showing; records the intent and lets the chain catch up.
    private func updateStreamingIntent() {
        let streamingIsWanted = viewModel.surface == .liveViewPanel && !viewModel.isCollapsed && !cursorIsPutAway
        let nextDesiredStreamingTargetWindow = streamingIsWanted ? targetWindow : nil
        guard nextDesiredStreamingTargetWindow?.windowIdentifier != desiredStreamingTargetWindow?.windowIdentifier else {
            desiredStreamingTargetWindow = nextDesiredStreamingTargetWindow
            return
        }
        desiredStreamingTargetWindow = nextDesiredStreamingTargetWindow
        let previousStreamLifecycleTask = streamLifecycleTask
        streamLifecycleTask = Task { @MainActor [weak self] in
            await previousStreamLifecycleTask?.value
            await self?.reconcileStreamWithIntent()
        }
    }

    /// Runs inside the serialized chain. The intent can change while startStreaming is suspended, so it is read again
    /// after every step until the running stream matches it.
    private func reconcileStreamWithIntent() async {
        while true {
            let desiredWindow = desiredStreamingTargetWindow
            if activeStreamingWindowIdentifier == desiredWindow?.windowIdentifier { return }
            if activeStreamingWindowIdentifier != nil {
                await frameStreamer.stopStreaming()
                activeStreamingWindowIdentifier = nil
                continue
            }
            guard let desiredWindow else { return }
            do {
                try await frameStreamer.startStreaming(desiredWindow, framesPerSecond: 8)
                activeStreamingWindowIdentifier = desiredWindow.windowIdentifier
            } catch {
                // A start that failed partway may still hold a capture; stopping is harmless when there is none.
                await frameStreamer.stopStreaming()
                print("Dotto: live view stream failed: \(error)")
                // Tried once for this intent; the next change of window, surface or collapse tries again.
                return
            }
        }
    }
}
