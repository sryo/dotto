import Foundation

enum SafetyConfirmationOutcome: Equatable, Sendable {
    /// "Allow once" or "Allow for the rest of this task". Either way the answered category covers the action or item
    /// that asked; only the latter also added it to the rest-of-task grants.
    case allowed(SafetyRiskCategory)
    case declined
    /// The task's abort signal is already set.
    case stopped
}

/// The one place a safety confirmation is asked and its answer applied, shared by the item-level gate, agent
/// actions, routine replay and the bring-forward assist. Callers ask right after SafetyGate required a confirmation
/// and check the abort signal right after this returns, before anything runs.
enum SafetyConfirmationFlow {
    static func askUser(_ request: SafetyConfirmationRequest, confirmationRequester: UserConfirmationRequesting,
                        auditLogWriter: AuditLogWriter, additionalAuditDetails: [String: String] = [:],
                        riskCategoriesAllowedForRestOfTask: inout Set<SafetyRiskCategory>,
                        abortSignal: TaskAbortSignal) async -> SafetyConfirmationOutcome {
        let confirmationAnswer = await confirmationRequester.requestSafetyConfirmation(request)
        let auditDetails = ["reason": request.reason, "risk_category": request.riskCategory.rawValue]
            .merging(additionalAuditDetails) { _, additionalDetail in additionalDetail }
        auditLogWriter.append(eventKind: .userConfirmation, itemIdentifier: request.itemIdentifier,
                              message: String(describing: confirmationAnswer), details: auditDetails)
        switch confirmationAnswer {
        case .allowOnce:
            return .allowed(request.riskCategory)
        case .allowForAllRemainingItems:
            // Grants exactly the category the user was shown; approving sends never approves deletes or payments.
            // A category that asks every time is allowed once, whatever surface sent the rest-of-task answer.
            if request.riskCategory.offersRestOfTaskGrant {
                riskCategoriesAllowedForRestOfTask.insert(request.riskCategory)
            }
            return .allowed(request.riskCategory)
        case .skipItem:
            return .declined
        case .stopTask:
            abortSignal.abort()
            return .stopped
        }
    }
}
