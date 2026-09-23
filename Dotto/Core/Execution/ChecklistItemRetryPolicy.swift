import Foundation

struct ChecklistItemFailureDecisionRequest: Equatable, Sendable {
    var itemIdentifier: String
    var itemLabel: String
    var failureSummary: String
    var attemptCount: Int
}

enum ChecklistItemFailureDecision: Equatable, Sendable { case retry, skipItem, stopTask }
enum ChecklistItemAttemptFollowUp: Equatable, Sendable { case acceptResult, retryAutomatically, askUser }

enum ChecklistItemRetryPolicy {
    static let maximumAutomaticRetries = 2
    /// Once an attempt typed text or pressed a control, a retry starts from a UI that attempt already changed.
    static let maximumAutomaticRetriesAfterSideEffects = 1

    static func followUp(afterAttemptWith runStatus: ChecklistItemRunStatus, automaticRetriesUsed: Int,
                         itemIsIrreversible: Bool, itemPerformedUserConfirmedAction: Bool,
                         canAskUser: Bool, attemptFailedDeterministically: Bool = false,
                         itemPerformedSideEffectingAction: Bool = false) -> ChecklistItemAttemptFollowUp {
        let askUserIfPossible: ChecklistItemAttemptFollowUp = canAskUser ? .askUser : .acceptResult
        switch runStatus {
        case .completed, .skipped, .pending, .running:
            return .acceptResult
        case .needsUser:
            return attemptFailedDeterministically ? .acceptResult : askUserIfPossible
        case .failed:
            // Retrying a half-finished send or delete could do it twice, so those always go to the user. So do
            // failures that would only repeat: a denied step, an exhausted action budget, a password field.
            if itemIsIrreversible || itemPerformedUserConfirmedAction || attemptFailedDeterministically { return askUserIfPossible }
            let retryAllowance = itemPerformedSideEffectingAction ? maximumAutomaticRetriesAfterSideEffects : maximumAutomaticRetries
            return automaticRetriesUsed < retryAllowance ? .retryAutomatically : askUserIfPossible
        }
    }

    private static let navigationOnlyClickRoles: Set<String> = [
        "AXRow", "AXCell", "AXOutlineRow", "AXStaticText", "AXImage", "AXGroup", "AXDisclosureTriangle", "AXMenuBarItem",
        "AXPopUpButton", "AXMenuButton", "AXLink", "AXList", "AXOutline", "AXTable", "AXScrollArea", "AXWindow",
    ]
    private static let navigationKeyNames: Set<String> = ["tab", "escape", "up", "down", "left", "right", "home", "end", "page_up", "page_down"]

    /// Whether the action may have changed the user's data rather than only selection, focus or scroll position:
    /// typing, keys other than navigation keys, and clicks on anything but rows, cells, texts and menu openers.
    static func actionHasSideEffects(_ action: AgentAction, targetNode: AccessibilityElementNode?) -> Bool {
        switch action {
        case .scroll:
            return false
        case .typeText, .clickScreenshotPoint, .uploadFiles:
            return true
        case .pressKey(let keyName, let modifiers):
            let modifiersBeyondShift = Set(modifiers).subtracting([.shift])
            return !(modifiersBeyondShift.isEmpty && navigationKeyNames.contains(SafetyGate.canonicalKeyName(keyName)))
        case .clickElement(_, let clickType):
            guard let targetNode else { return true }
            if clickType == .right { return false }
            return !navigationOnlyClickRoles.contains(targetNode.role) && targetNode.subrole != "AXTabButton"
        }
    }
}
