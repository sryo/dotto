import Foundation
import CoreGraphics

enum UserTakeoverInputKind: String, Codable, Equatable, Sendable { case mouseClicked, scrolled, keyPressed, windowMovedOrResized, windowClosed }

struct ObservedUserInputEvent: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case mouseMoved
        case mouseDown(isRightButton: Bool, clickCount: Int)
        case scrollWheel
        case keyDown(virtualKeyCode: Int64, modifiers: [AgentKeyModifier], characters: String?)
    }
    var kind: Kind
    var topLeftGlobalLocation: CGPoint
    /// Seconds on the monotonic uptime clock (CLOCK_UPTIME_RAW), stamped when the event tap delivers the event.
    var timestampSeconds: TimeInterval
    var isSynthesizedByThisApp: Bool
    var frontmostProcessIdentifier: Int32? = nil
    /// Owner of the topmost window under the pointer (mouse and scroll events only).
    var windowOwnerProcessIdentifier: Int32? = nil
}

enum ObservedTargetWindowEventKind: Equatable, Sendable { case movedOrResized, closedOrMinimized }

struct ObservedTargetWindowEvent: Equatable, Sendable {
    var kind: ObservedTargetWindowEventKind
    var timestampSeconds: TimeInterval
    /// The target app reports moves, resizes and minimizes for every one of its windows. Only the window the task
    /// was pinned to at the start of the run counts: Get Info windows, inspectors and sheets that Dotto's own steps
    /// open come and go, resize themselves while they load, and are closed again by Dotto.
    var isOnPinnedTargetWindow: Bool = true
    /// The pinned window's frame read when the notification arrived (moves and resizes only). Apps also post these
    /// notifications when nothing about the frame changed, so the detector compares it with its baseline.
    var pinnedTargetWindowFrameInTopLeftGlobalPoints: CGRect? = nil
}

/// Something Dotto itself did to the target app, stamped on the same monotonic clock as observed events. Window
/// changes during or right after these are Dotto's, not the user's.
enum AutomatedTargetActivity: Equatable, Sendable {
    case actionStarted(AgentAction)
    case actionFinished
    case foregroundAssistStarted
    case foregroundAssistFinished
}

enum TargetWindowEventDecision: Equatable, Sendable {
    case ignore
    case takeover(UserTakeoverInputKind)
    /// Dotto's own step closed or minimized the pinned window (⌘W on the document, a click on a close button): the
    /// run goes on in the app's front window, which becomes the new pin.
    case repinTargetWindowToFrontWindow
}

/// Dotto works in the background, so only input aimed at the target app counts as the user taking over: clicks and
/// scrolls on its windows, keys while it is frontmost, and moving or closing the task's pinned window. Pointer travel,
/// everything the user does in other apps, and window changes Dotto's own steps cause never pause the run.
struct UserTakeoverDetector: Sendable {
    /// Windows keep animating, settling and re-laying out for a moment after Dotto's action or bring-forward ends
    /// (the restore re-activates the user's app, a Get Info window grows once it has read the file).
    var automatedActivityGraceSeconds: TimeInterval = 1.5
    /// A close or minimize this long after Dotto's own ⌘W, ⌘M, Esc, Return or click is taken as that action's effect;
    /// some apps animate or confirm before the window goes.
    var closingActionAttributionSeconds: TimeInterval = 5.0
    /// The user's click on Resume or on a pill answer can reach the event tap after the panel under it has already
    /// changed shape (the Resume button is gone), so the hit test no longer finds Dotto's content there.
    var thisAppPanelAnswerGraceSeconds: TimeInterval = 0.75
    /// Frames are read in points; a sub-point difference is rounding, not the user dragging.
    var frameChangeTolerancePoints: CGFloat = 1.0

    private var inProgressAutomatedActivityCount = 0
    private var lastAutomatedActivityBoundaryTimestamp: TimeInterval?
    private var lastAutomatedAction: AgentAction?
    private var lastAutomatedActionIsInProgress = false
    private var lastAutomatedActionFinishedTimestamp: TimeInterval?
    private var lastThisAppPanelAnswerTimestamp: TimeInterval?
    private var pinnedTargetWindowFrameBaseline: CGRect?

    mutating func noteAutomatedActivity(_ automatedActivity: AutomatedTargetActivity, atTimestampSeconds timestampSeconds: TimeInterval) {
        lastAutomatedActivityBoundaryTimestamp = timestampSeconds
        switch automatedActivity {
        case .actionStarted(let agentAction):
            inProgressAutomatedActivityCount += 1
            lastAutomatedAction = agentAction
            lastAutomatedActionIsInProgress = true
        case .foregroundAssistStarted:
            inProgressAutomatedActivityCount += 1
        case .actionFinished:
            inProgressAutomatedActivityCount = max(0, inProgressAutomatedActivityCount - 1)
            lastAutomatedActionIsInProgress = false
            lastAutomatedActionFinishedTimestamp = timestampSeconds
        case .foregroundAssistFinished:
            inProgressAutomatedActivityCount = max(0, inProgressAutomatedActivityCount - 1)
        }
    }

    /// The user pressed Resume or answered a question on one of Dotto's panels.
    mutating func noteUserAnsweredThisAppPanel(atTimestampSeconds timestampSeconds: TimeInterval) {
        lastThisAppPanelAnswerTimestamp = timestampSeconds
    }

    /// The pinned window's frame as it is now: at the start of the run, after Resume (the user may have moved it
    /// while paused) and after re-pinning.
    mutating func rebaselinePinnedTargetWindowFrame(_ pinnedTargetWindowFrameInTopLeftGlobalPoints: CGRect?) {
        pinnedTargetWindowFrameBaseline = pinnedTargetWindowFrameInTopLeftGlobalPoints
    }

    func takeoverKind(for observedEvent: ObservedUserInputEvent, targetProcessIdentifier: Int32) -> UserTakeoverInputKind? {
        if observedEvent.isSynthesizedByThisApp { return nil }
        let targetIsFrontmost = observedEvent.frontmostProcessIdentifier == targetProcessIdentifier
        // When the window under the pointer can't be resolved, the frontmost app is the best guess at what was hit.
        let pointerIsOverTarget = observedEvent.windowOwnerProcessIdentifier.map { $0 == targetProcessIdentifier } ?? targetIsFrontmost
        switch observedEvent.kind {
        case .mouseMoved:
            return nil
        case .mouseDown:
            if isWithinThisAppPanelAnswerGrace(observedEvent.timestampSeconds) { return nil }
            return pointerIsOverTarget ? .mouseClicked : nil
        case .scrollWheel:
            if isWithinThisAppPanelAnswerGrace(observedEvent.timestampSeconds) { return nil }
            return pointerIsOverTarget ? .scrolled : nil
        case .keyDown:
            return targetIsFrontmost ? .keyPressed : nil
        }
    }

    mutating func decision(for windowEvent: ObservedTargetWindowEvent) -> TargetWindowEventDecision {
        guard windowEvent.isOnPinnedTargetWindow else { return .ignore }
        let causedByAutomatedActivity = isAutomatedActivityInProgressOrRecent(at: windowEvent.timestampSeconds)
        switch windowEvent.kind {
        case .movedOrResized:
            let pinnedFrameChanged = pinnedTargetWindowFrameDiffersFromBaseline(windowEvent.pinnedTargetWindowFrameInTopLeftGlobalPoints)
            // Dotto's own moves become the new baseline too, so only the user's later drag is compared against them.
            if let reportedFrame = windowEvent.pinnedTargetWindowFrameInTopLeftGlobalPoints {
                pinnedTargetWindowFrameBaseline = reportedFrame
            }
            if causedByAutomatedActivity || !pinnedFrameChanged { return .ignore }
            return .takeover(.windowMovedOrResized)
        case .closedOrMinimized:
            if causedByAutomatedActivity || lastAutomatedActionMayHaveClosedWindow(at: windowEvent.timestampSeconds) {
                return .repinTargetWindowToFrontWindow
            }
            return .takeover(.windowClosed)
        }
    }

    mutating func reset() {
        inProgressAutomatedActivityCount = 0
        lastAutomatedActivityBoundaryTimestamp = nil
        lastAutomatedAction = nil
        lastAutomatedActionIsInProgress = false
        lastAutomatedActionFinishedTimestamp = nil
        lastThisAppPanelAnswerTimestamp = nil
        pinnedTargetWindowFrameBaseline = nil
    }

    /// Keys and clicks that close windows or dismiss sheets and dialogs. Any click may land on a close button.
    static func automatedActionMayCloseWindow(_ agentAction: AgentAction) -> Bool {
        switch agentAction {
        case .clickElement, .clickScreenshotPoint:
            return true
        case .typeText(_, _, _, let pressReturnAfter):
            return pressReturnAfter
        case .pressKey(let keyName, let modifiers):
            let canonicalKeyName = SafetyGate.canonicalKeyName(keyName)
            if canonicalKeyName == "escape" || canonicalKeyName == "return" { return true }
            return modifiers.contains(.command) && (canonicalKeyName == "w" || canonicalKeyName == "m")
        case .scroll, .uploadFiles, .replaceText:
            return false
        }
    }

    private func isAutomatedActivityInProgressOrRecent(at timestampSeconds: TimeInterval) -> Bool {
        if inProgressAutomatedActivityCount > 0 { return true }
        guard let lastAutomatedActivityBoundaryTimestamp else { return false }
        return timestampSeconds - lastAutomatedActivityBoundaryTimestamp <= automatedActivityGraceSeconds
    }

    private func lastAutomatedActionMayHaveClosedWindow(at timestampSeconds: TimeInterval) -> Bool {
        guard let lastAutomatedAction, Self.automatedActionMayCloseWindow(lastAutomatedAction) else { return false }
        if lastAutomatedActionIsInProgress { return true }
        guard let lastAutomatedActionFinishedTimestamp else { return false }
        return timestampSeconds - lastAutomatedActionFinishedTimestamp <= closingActionAttributionSeconds
    }

    private func isWithinThisAppPanelAnswerGrace(_ timestampSeconds: TimeInterval) -> Bool {
        guard let lastThisAppPanelAnswerTimestamp else { return false }
        let secondsSinceAnswer = timestampSeconds - lastThisAppPanelAnswerTimestamp
        return secondsSinceAnswer >= 0 && secondsSinceAnswer <= thisAppPanelAnswerGraceSeconds
    }

    /// Without a reported frame the change can't be ruled out, so it counts. Without a baseline there is nothing to
    /// compare with: an app launched in the background often reports no window until its first move notification,
    /// which is then pinned, and that first report becomes the baseline instead of a takeover.
    private func pinnedTargetWindowFrameDiffersFromBaseline(_ reportedFrame: CGRect?) -> Bool {
        guard let reportedFrame else { return true }
        guard let pinnedTargetWindowFrameBaseline else { return false }
        return abs(reportedFrame.minX - pinnedTargetWindowFrameBaseline.minX) > frameChangeTolerancePoints
            || abs(reportedFrame.minY - pinnedTargetWindowFrameBaseline.minY) > frameChangeTolerancePoints
            || abs(reportedFrame.width - pinnedTargetWindowFrameBaseline.width) > frameChangeTolerancePoints
            || abs(reportedFrame.height - pinnedTargetWindowFrameBaseline.height) > frameChangeTolerancePoints
    }
}
