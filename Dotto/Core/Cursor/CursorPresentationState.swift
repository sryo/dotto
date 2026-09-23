import Foundation
import CoreGraphics

/// The owner's cursor states. `pointing` is the flight to the next target; `waiting` is a question for the user.
enum CursorActivity: String, Codable, Equatable, Sendable {
    case hidden, pointing, reading, thinking, clicking, typing, replaying, waiting, paused, done, error
}

enum CursorActionKind: String, Equatable, Sendable {
    case click, doubleClick, rightClick, typing, pressingKey, scrolling, attachingFiles

    var cursorActivity: CursorActivity {
        switch self {
        case .click, .doubleClick, .rightClick, .attachingFiles: return .clicking
        case .typing, .pressingKey: return .typing
        case .scrolling: return .pointing
        }
    }
}

struct CursorReplayStepProgress: Equatable, Sendable {
    var completedStepCount: Int
    var stepCount: Int
}

struct CursorPresentationState: Equatable, Sendable {
    static let maximumStatusTextLength = 60

    var activity: CursorActivity
    /// The item label or a status; never typed text.
    var statusText: String?
    /// 0…1: replay step progress while replaying, else the item's position in the checklist.
    var progress: Double?
    var replayStepProgress: CursorReplayStepProgress?
    /// A direct route's operation count ("12 / 23"), kept apart from routine replay so the pill never reads one as
    /// the other.
    var directOperationProgress: CursorReplayStepProgress? = nil
    var targetPointInWindow: CGPoint?
    var targetWindowIdentifier: UInt32?
    /// Buttons inside the status pill while waiting, paused or stuck.
    var decisionOptions: [UserDecisionOption] = []
    var attentionRequest: UserAttentionRequest? = nil
    /// Where a question or a pause returns to.
    var activityBeforeInterruption: CursorActivity? = nil
    var statusTextBeforeInterruption: String? = nil
    /// Where the cursor returns once a pending bring-forward (waiting for the user to pause, then the countdown) ends.
    var activityBeforeForegroundAssist: CursorActivity? = nil
    var statusTextBeforeForegroundAssist: String? = nil
    var foregroundAssistIsPending = false
    /// Numbers attention requests, so each one gets a fresh identifier for the whole app session: an answer (or a
    /// notification action) meant for an earlier request can never match a later one.
    var attentionRequestCount = 0

    static let hidden = CursorPresentationState(activity: .hidden, statusText: nil, progress: nil, replayStepProgress: nil,
                                                targetPointInWindow: nil, targetWindowIdentifier: nil)

    /// Hidden, but still counting: hiding must never restart the attention request numbering.
    var hiddenKeepingAttentionRequestCount: CursorPresentationState {
        var hiddenState = CursorPresentationState.hidden
        hiddenState.attentionRequestCount = attentionRequestCount
        return hiddenState
    }
}

enum CursorActivityEvent: Equatable, Sendable {
    /// The cursor comes up at the point where the user summoned Dotto, before any checklist exists: it reads the
    /// target app, then thinks, until the plan is ready for review.
    case planningStarted(targetApplicationName: String)
    case planningProgressed(ChecklistPlanningProgress)
    /// The plan is waiting for the user's approval in the checklist attached to the cursor.
    case checklistReadyForReview
    /// The planner asked the user for more detail, in the card attached to the cursor.
    case plannerAskedForInput
    case runStarted(targetWindow: TargetWindowReference?)
    case targetWindowChanged(TargetWindowReference)
    case itemStarted(itemLabel: String, itemPosition: Int, itemCount: Int)
    case userInterfaceReadStarted
    case modelTurnStarted
    case replayStepStarted(stepIndex: Int, stepCount: Int)
    /// A direct route (file operations, a script or a shortcut) finished another operation. The cursor stays parked:
    /// nothing is clicked, so there is no flight.
    case directOperationProgressed(completedCount: Int, totalCount: Int, operationDescription: String)
    case actionTargeted(CursorActionKind, windowRelativePoint: CGPoint?)
    case confirmationRequested(SafetyConfirmationRequest)
    case itemFailureDecisionRequested(ChecklistItemFailureDecisionRequest)
    /// Answers either question above.
    case confirmationAnswered
    case paused(TaskPauseReason)
    case resumed
    /// Before a bring-forward: Dotto waits until the user pauses (no clicks or keys for a moment, no password field
    /// active), then counts down with Cancel. `foregroundAssistPendingEnded` returns the cursor to what it was doing.
    case foregroundAssistWaitingForUser
    case foregroundAssistCountdownStarted
    case foregroundAssistPendingEnded
    case foregroundAssistStarted
    case foregroundAssistFinished
    case itemFinished(ChecklistItemRunStatus)
    case runFinished(succeeded: Bool)
}

enum CursorPresentationStateMapper {
    static let bringingAppForwardStatusText = "Bringing the app forward for a moment"
    static let waitingForUserBeforeBringingAppForwardStatusText = "Waiting for you to pause before bringing the app forward"
    static let bringingAppForwardCountdownStatusText = "Bringing the app forward…"
    static let cancelBringingAppForwardOption = UserDecisionOption(identifier: .cancel, title: "Cancel", isPrimary: false)
    static let planningStatusText = "Planning…"
    static let reviewChecklistStatusText = "Review the checklist"
    static let plannerNeedsInputStatusText = "Waiting for you"
    static let bringAppForwardQuestionText = "Let Dotto bring the app forward when it needs to?"

    static func bringAppForwardQuestionText(targetApplicationName: String) -> String {
        targetApplicationName.isEmpty ? bringAppForwardQuestionText
            : "Let Dotto bring \(targetApplicationName) forward when it needs to?"
    }

    /// Total: every event maps to a state, and a hidden cursor stays hidden until planning or a run starts.
    /// Presenters hide the cursor 1.2 s after `runFinished`; that timing is theirs.
    static func nextState(from currentState: CursorPresentationState, on event: CursorActivityEvent) -> CursorPresentationState {
        if currentState.activity == .hidden, !bringsCursorUp(event) { return currentState }
        var nextState = currentState
        func setStatusText(_ rawText: String?) {
            nextState.statusText = rawText.map { UserFacingTextSanitizing.singleLine($0, maximumLength: CursorPresentationState.maximumStatusTextLength) }
        }
        /// Events that arrive while a question or pause is showing only update what the cursor returns to.
        func setWorkingActivity(_ workingActivity: CursorActivity) {
            if [.waiting, .paused].contains(nextState.activity) {
                nextState.activityBeforeInterruption = workingActivity
            } else {
                nextState.activity = workingActivity
            }
        }
        func interrupt(with interruptionActivity: CursorActivity, statusText: String, decisionOptions: [UserDecisionOption]) {
            if ![.waiting, .paused].contains(nextState.activity) {
                nextState.activityBeforeInterruption = nextState.activity
                nextState.statusTextBeforeInterruption = nextState.statusText
            }
            nextState.activity = interruptionActivity
            setStatusText(statusText)
            nextState.decisionOptions = decisionOptions
        }
        func endInterruption(returningTo fallbackActivity: CursorActivity?) {
            nextState.activity = fallbackActivity ?? nextState.activityBeforeInterruption ?? .reading
            nextState.statusText = nextState.statusTextBeforeInterruption
            nextState.activityBeforeInterruption = nil
            nextState.statusTextBeforeInterruption = nil
            nextState.decisionOptions = []
            nextState.attentionRequest = nil
        }
        func beginPendingForegroundAssist(statusText: String, decisionOptions: [UserDecisionOption]) {
            if !nextState.foregroundAssistIsPending {
                nextState.foregroundAssistIsPending = true
                nextState.activityBeforeForegroundAssist = nextState.activity
                nextState.statusTextBeforeForegroundAssist = nextState.statusText
            }
            nextState.activity = .pointing
            setStatusText(statusText)
            nextState.decisionOptions = decisionOptions
        }
        func requestAttention(_ kind: UserAttentionKind, title: String, bodyText: String, decisionOptions: [UserDecisionOption]) {
            nextState.attentionRequestCount += 1
            nextState.attentionRequest = UserAttentionRequest(
                requestIdentifier: "attention-\(nextState.attentionRequestCount)", kind: kind,
                title: UserFacingTextSanitizing.singleLine(title, maximumLength: UserAttentionRequest.maximumTitleLength),
                bodyText: UserFacingTextSanitizing.singleLine(bodyText, maximumLength: UserAttentionRequest.maximumBodyTextLength),
                decisionOptions: decisionOptions)
        }

        switch event {
        case .planningStarted(let targetApplicationName):
            nextState = .hidden
            nextState.attentionRequestCount = currentState.attentionRequestCount
            nextState.activity = .reading
            setStatusText(targetApplicationName.isEmpty
                ? planningStatusText
                : ChecklistPlanningProgress.readingApplication(applicationName: targetApplicationName).statusLineText)
        case .planningProgressed(let planningProgress):
            switch planningProgress {
            case .readingApplication, .takingScreenshot, .readingFolder:
                nextState.activity = .reading
                setStatusText(planningProgress.statusLineText)
            case .thinking:
                nextState.activity = .thinking
                setStatusText(planningStatusText)
            case .writingChecklist:
                nextState.activity = .thinking
                setStatusText(planningProgress.statusLineText)
            }
        case .checklistReadyForReview, .plannerAskedForInput:
            nextState.activity = .waiting
            setStatusText(event == .checklistReadyForReview ? reviewChecklistStatusText : plannerNeedsInputStatusText)
            nextState.decisionOptions = []
            nextState.attentionRequest = nil
        case .runStarted(let targetWindow):
            nextState = .hidden
            nextState.attentionRequestCount = currentState.attentionRequestCount
            nextState.activity = .reading
            nextState.targetWindowIdentifier = targetWindow?.windowIdentifier
        case .targetWindowChanged(let targetWindow):
            nextState.targetWindowIdentifier = targetWindow.windowIdentifier
            nextState.targetPointInWindow = nil
        case .itemStarted(let itemLabel, let itemPosition, let itemCount):
            setWorkingActivity(.reading)
            setStatusText(itemLabel)
            nextState.progress = itemCount > 0 ? Double(max(0, itemPosition - 1)) / Double(itemCount) : nil
            nextState.replayStepProgress = nil
            nextState.directOperationProgress = nil
        case .userInterfaceReadStarted:
            setWorkingActivity(.reading)
        case .modelTurnStarted:
            setWorkingActivity(.thinking)
        case .replayStepStarted(let stepIndex, let stepCount):
            setWorkingActivity(.replaying)
            nextState.progress = stepCount > 0 ? Double(stepIndex) / Double(stepCount) : nil
            nextState.replayStepProgress = CursorReplayStepProgress(completedStepCount: stepIndex, stepCount: stepCount)
            nextState.directOperationProgress = nil
        case .directOperationProgressed(let completedCount, let totalCount, let operationDescription):
            // Replaying styling already means "working without model calls".
            setWorkingActivity(.replaying)
            setStatusText(operationDescription)
            nextState.progress = totalCount > 0 ? Double(completedCount) / Double(totalCount) : nil
            nextState.replayStepProgress = nil
            nextState.directOperationProgress = CursorReplayStepProgress(completedStepCount: completedCount, stepCount: totalCount)
        case .actionTargeted(let actionKind, let windowRelativePoint):
            if let windowRelativePoint { nextState.targetPointInWindow = windowRelativePoint }
            if nextState.activity != .replaying { setWorkingActivity(actionKind.cursorActivity) }
        case .confirmationRequested(let confirmationRequest):
            let (attentionKind, title, decisionOptions) = confirmationPresentation(for: confirmationRequest)
            interrupt(with: .waiting, statusText: title, decisionOptions: decisionOptions)
            requestAttention(attentionKind, title: title, bodyText: "“\(confirmationRequest.itemLabel)”: \(confirmationRequest.reason)",
                             decisionOptions: decisionOptions)
        case .itemFailureDecisionRequested(let failureDecisionRequest):
            let decisionOptions = [UserDecisionOption(identifier: .retry, title: "Retry", isPrimary: true),
                                   UserDecisionOption(identifier: .skip, title: "Skip item", isPrimary: false),
                                   UserDecisionOption(identifier: .stop, title: "Stop", isPrimary: false)]
            let attemptText = failureDecisionRequest.attemptCount == 1 ? "1 attempt" : "\(failureDecisionRequest.attemptCount) attempts"
            interrupt(with: .error, statusText: "Stuck on “\(failureDecisionRequest.itemLabel)”", decisionOptions: decisionOptions)
            requestAttention(.stuck, title: "Dotto is stuck",
                             bodyText: "“\(failureDecisionRequest.itemLabel)” didn't work after \(attemptText). Retry, skip it, or stop?",
                             decisionOptions: decisionOptions)
        case .confirmationAnswered:
            endInterruption(returningTo: nil)
        case .paused(let pauseReason):
            interrupt(with: .paused, statusText: pauseReason.bannerText,
                      decisionOptions: [UserDecisionOption(identifier: .resume, title: "Resume", isPrimary: true)])
        case .resumed:
            endInterruption(returningTo: .reading)
        case .foregroundAssistWaitingForUser:
            beginPendingForegroundAssist(statusText: waitingForUserBeforeBringingAppForwardStatusText, decisionOptions: [])
        case .foregroundAssistCountdownStarted:
            beginPendingForegroundAssist(statusText: bringingAppForwardCountdownStatusText,
                                         decisionOptions: [cancelBringingAppForwardOption])
        case .foregroundAssistPendingEnded:
            guard nextState.foregroundAssistIsPending else { break }
            nextState.activity = nextState.activityBeforeForegroundAssist ?? .reading
            nextState.statusText = nextState.statusTextBeforeForegroundAssist
            nextState.activityBeforeForegroundAssist = nil
            nextState.statusTextBeforeForegroundAssist = nil
            nextState.foregroundAssistIsPending = false
            nextState.decisionOptions = []
        case .foregroundAssistStarted:
            nextState.statusTextBeforeInterruption = nextState.statusText
            setStatusText(bringingAppForwardStatusText)
            nextState.activity = .pointing
        case .foregroundAssistFinished:
            nextState.statusText = nextState.statusTextBeforeInterruption
            nextState.statusTextBeforeInterruption = nil
            nextState.activity = .reading
        case .itemFinished(let runStatus):
            switch runStatus {
            case .completed: setWorkingActivity(.done)
            case .failed: setWorkingActivity(.error)
            case .pending, .running, .needsUser, .skipped: break
            }
        case .runFinished(let succeeded):
            endInterruption(returningTo: succeeded ? .done : .error)
            nextState.foregroundAssistIsPending = false
            nextState.activityBeforeForegroundAssist = nil
            nextState.statusTextBeforeForegroundAssist = nil
            setStatusText(succeeded ? "Done" : "Stopped")
            nextState.replayStepProgress = nil
            nextState.directOperationProgress = nil
            requestAttention(.finished, title: succeeded ? "Dotto finished" : "Dotto stopped",
                             bodyText: succeeded ? "The task is done. The checklist shows what changed."
                                                 : "The task stopped before every item was done. The checklist shows where.",
                             decisionOptions: [])
        }
        return nextState
    }

    private static func bringsCursorUp(_ event: CursorActivityEvent) -> Bool {
        switch event {
        case .runStarted, .planningStarted: return true
        default: return false
        }
    }

    private static func confirmationPresentation(for confirmationRequest: SafetyConfirmationRequest)
        -> (UserAttentionKind, title: String, decisionOptions: [UserDecisionOption]) {
        let restOfTaskOption = UserDecisionOption(identifier: .allowRestOfTask, title: "Allow for the rest of this task", isPrimary: false)
        let stopOption = UserDecisionOption(identifier: .stop, title: "Stop", isPrimary: false)
        switch confirmationRequest.riskCategory {
        case .bringingAppForward:
            // The same app comes forward for many steps of one task, so the task-wide grant leads. It still covers
            // only this category, and every bring-forward still waits for the user to pause and counts down first.
            return (.needsBringForward, bringAppForwardQuestionText,
                    [UserDecisionOption(identifier: .allowRestOfTask, title: "Allow for this task", isPrimary: true),
                     UserDecisionOption(identifier: .allow, title: "Just this once", isPrimary: false),
                     UserDecisionOption(identifier: .skip, title: "Skip", isPrimary: false), stopOption])
        case .uploadingFiles:
            return (.needsDecision, "Attach files?",
                    [UserDecisionOption(identifier: .allow, title: "Attach", isPrimary: true), restOfTaskOption,
                     UserDecisionOption(identifier: .skip, title: "Don't attach (skip item)", isPrimary: false), stopOption])
        case .runningShortcut:
            // A shortcut can do anything its actions allow, so every run asks: there is no rest-of-task grant.
            return (.needsDecision, "Run your shortcut?",
                    [UserDecisionOption(identifier: .allow, title: "Run shortcut", isPrimary: true),
                     UserDecisionOption(identifier: .skip, title: "Don't run", isPrimary: false), stopOption])
        case .runningScript:
            return (.needsDecision, "Run the script?",
                    [UserDecisionOption(identifier: .allow, title: "Run script", isPrimary: true), restOfTaskOption,
                     UserDecisionOption(identifier: .skip, title: "Don't run", isPrimary: false), stopOption])
        default:
            let allowOption = UserDecisionOption(identifier: .allow, title: "Allow", isPrimary: true)
            let skipOption = UserDecisionOption(identifier: .skip, title: "Skip item", isPrimary: false)
            let decisionOptions = confirmationRequest.riskCategory.offersRestOfTaskGrant
                ? [allowOption, restOfTaskOption, skipOption, stopOption] : [allowOption, skipOption, stopOption]
            return (.needsDecision, "Dotto needs your OK", decisionOptions)
        }
    }
}
