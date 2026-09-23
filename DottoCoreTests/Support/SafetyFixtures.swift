import Foundation

func riskCategory(of verdict: SafetyVerdict) -> SafetyRiskCategory? {
    if case .requireUserConfirmation(_, let riskCategory) = verdict { return riskCategory }
    return nil
}

func confirmationReason(of verdict: SafetyVerdict) throws -> String {
    guard case .requireUserConfirmation(let reason, _) = verdict else { throw CoreTestFailure(description: "expected a confirmation, got \(verdict)") }
    return reason
}

/// SafetyGate's verdict with no confirmed item and no rest-of-task grants.
func ungrantedVerdict(_ action: AgentAction, targetNode: AccessibilityElementNode? = nil) -> SafetyVerdict {
    SafetyGate.evaluateAction(action, targetNode: targetNode, riskCategoryConfirmedForThisItem: nil)
}
