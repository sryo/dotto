import Foundation

struct ActionOutcome: Equatable, Sendable {
    var descriptionForModel: String
    /// nil when no input was posted.
    var deliveryTier: InputDeliveryTier?
    var usedForegroundAssist: Bool = false
    /// The input was posted but no visible change followed, which the description notes with `noVisibleChangeNote`.
    var noVisibleChangeWasSeen: Bool = false

    static let noVisibleChangeNote = " (nothing visibly changed; read the UI to check)"
}

struct ActionBackendTaskConfiguration: Equatable, Sendable {
    var targetApplication: TargetApplicationReference
    var uploadFileAllowlist: UploadFileAllowlist = .empty
}

enum ActionBackendError: Error, Equatable, Sendable {
    case staleOrUnknownElementIdentifier(String)
    case elementNotActionable(String)
    case secureFieldTypingDenied
    case targetIsThisAppWindow
    case noScreenshotForPixelCoordinates
    case unknownKeyName(String)
    case applicationNotFound(String)
    case applicationNotAllowed(String)
    case accessibilityPermissionMissing
    case accessibilityCallFailed(String)
    case aborted
    case pausedBeforeThisAction
    /// `foregroundAssistMayHelp` is false when bringing the app forward wouldn't change the outcome.
    case inputNotDelivered(String, foregroundAssistMayHelp: Bool)
    case foregroundAssistFailed(String)
    case uploadNotAllowed(String)
    /// replace_text's `find` isn't in the field. The detail names the field and shows its text, both from the app.
    case textToReplaceNotFound(String)
    case screenshotUnavailable(ScreenshotUnavailableReason)

    static let inputNotDeliveredText = "Dotto's input didn't take effect in the app while it stayed in the background."
    static let pausedBeforeThisActionText = "The task was paused before this action ran and the user may have changed the UI. Read the UI again and repeat the action if it is still needed."

    /// Dotto's own wording, plus the text that came from the app, the page or the browser when there is any.
    private var appAuthoredTextAndUntrustedDetail: (appAuthoredText: String, untrustedDetail: String?) {
        switch self {
        case .staleOrUnknownElementIdentifier(let elementIdentifier):
            return ("Element \(elementIdentifier) is not in the latest outline. Call read_ui and use an id from the new outline.", nil)
        case .elementNotActionable(let explanation):
            return ("That element can't be acted on. Reason (from the app or page):", explanation)
        case .secureFieldTypingDenied:
            return ("Typing into password fields is not allowed.", nil)
        case .targetIsThisAppWindow:
            return ("That point is on Dotto's own window. Click inside the target app instead.", nil)
        case .noScreenshotForPixelCoordinates:
            return ("click_point needs a screenshot first. Call screenshot, then use its pixel coordinates.", nil)
        case .unknownKeyName(let keyName):
            return ("Unknown key name \"\(keyName)\". Use a name from the press_key description.", nil)
        case .applicationNotFound(let applicationName):
            return ("No running app has this name:", applicationName)
        case .applicationNotAllowed(let applicationName):
            return ("Dotto doesn't operate this app. Terminals, password managers, System Settings, Keychain Access and system security prompts are off-limits. App:", applicationName)
        case .accessibilityPermissionMissing:
            return ("Dotto doesn't have Accessibility permission, so it can't read or operate the UI.", nil)
        case .accessibilityCallFailed(let explanation):
            return ("The Accessibility call failed:", explanation)
        case .aborted:
            return ("The user stopped the task.", nil)
        case .pausedBeforeThisAction:
            return (Self.pausedBeforeThisActionText, nil)
        case .inputNotDelivered(let detail, _):
            return (Self.inputNotDeliveredText, detail)
        case .foregroundAssistFailed(let detail):
            return ("Bringing the app forward didn't work:", detail)
        case .uploadNotAllowed(let reason):
            // Dotto's own wording, naming files by basename only.
            return (reason, nil)
        case .textToReplaceNotFound(let fieldDescriptionAndText):
            return ("Nothing changed: the text in `find` isn't in that field. Matching is exact and case-sensitive, so copy "
                        + "the text from the field's current value. The field and its text:", fieldDescriptionAndText)
        case .screenshotUnavailable(let reason):
            return (reason.guidanceForModel, nil)
        }
    }

    /// Plain text: status lines also show it to the user.
    var messageForModel: String {
        let (appAuthoredText, untrustedDetail) = appAuthoredTextAndUntrustedDetail
        return untrustedDetail.map { appAuthoredText + " " + $0 } ?? appAuthoredText
    }

    /// For tool results: any text that came from the app, the page or the browser goes inside <untrusted_ui>, so a
    /// hostile label or page text can't pose as Dotto's instructions. Dotto's own wording stays outside the fence.
    var fencedMessageForModel: String {
        let (appAuthoredText, untrustedDetail) = appAuthoredTextAndUntrustedDetail
        return untrustedDetail.map { appAuthoredText + "\n" + PromptLibrary.untrustedUserInterfaceBlock($0) } ?? appAuthoredText
    }
}

protocol ActionBackend: AnyObject {
    /// Never activates or launches the app. Sets per-task accessibility modes, resets the element-id counter and
    /// cached snapshot, and keeps the upload allowlist for this task.
    func prepareForTask(_ taskConfiguration: ActionBackendTaskConfiguration) async throws
    /// Walks must check abortSignal between elements so Stop interrupts a slow or hung target app.
    func readUserInterface(_ request: ReadUserInterfaceRequest, abortSignal: TaskAbortSignal) async throws -> AccessibilityTreeSnapshot
    /// The task window only, also when other windows cover it, with its interactive elements boxed and labeled by id.
    /// Reads the window's elements first, so the marked ids become the latest outline's ids.
    func captureMarkedScreenshot(markLimits: ScreenshotMarkLimits, abortSignal: TaskAbortSignal) async throws -> MarkedScreenshotCapture
    /// Background only; never takes focus. Must check abortSignal before every posted input event and throw
    /// ActionBackendError.aborted.
    func perform(_ action: AgentAction, abortSignal: TaskAbortSignal) async throws -> ActionOutcome
    /// Only after the user approved bringing the app forward (or approved the upload). Restores the user's app,
    /// window and cursor afterwards.
    func performWithForegroundAssist(_ action: AgentAction, abortSignal: TaskAbortSignal) async throws -> ActionOutcome
    func finishTask() async
}
