import Foundation

/// Actions whose current UI route is known to need a frontmost target. Refuse these before asking for action consent.
/// Other actions still attempt the background tier and stop if delivery cannot be verified.
enum BackgroundActionPolicy {
    static func requiresForeground(_ step: RoutineStep) -> Bool {
        switch step.action {
        case .uploadFiles:
            return true
        case .click(let clickType):
            if clickType != .single { return true }
            return step.targetLocator?.role == "AXMenuButton" || step.targetLocator?.role == "AXPopUpButton"
        case .typeText, .pressKey, .waitForText:
            return false
        }
    }

    static func requiresForeground(_ action: AgentAction, targetNode: AccessibilityElementNode?) -> Bool {
        switch action {
        case .uploadFiles, .clickScreenshotPoint:
            return true
        case .clickElement(_, let clickType):
            if clickType != .single { return true }
            return targetNode?.role == "AXMenuButton" || targetNode?.role == "AXPopUpButton"
        case .typeText, .pressKey, .scroll:
            return false
        }
    }
}
