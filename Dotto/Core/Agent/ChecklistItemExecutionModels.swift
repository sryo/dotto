import Foundation

struct ChecklistItemExecutionContext {
    var checklist: Checklist
    var item: ChecklistItem
    var itemPositionAmongIncludedItems: Int
    var includedItemCount: Int
    var previousItemResultSummary: String?
    /// The risk category the user confirmed this whole item under before it started (directly, or through an
    /// "allow for all" grant). It covers actions of that category only; every other risky action still asks.
    var riskCategoryConfirmedForThisItem: SafetyRiskCategory?
    var remainingTaskActionBudget: Int
    var riskCategoriesAllowedForRestOfTask: Set<SafetyRiskCategory> = []
    var taskResourceBudget: TaskResourceBudget
    var runControl: TaskRunControl? = nil
    /// A retry reason or routine-fallback note, shown to the model as untrusted text.
    var additionalContextForModel: String? = nil
    var uploadFileAllowlist: UploadFileAllowlist = .empty
    /// Holds every bring-forward until the user has paused; nil only in tests.
    var foregroundAssistReadinessGate: ForegroundAssistReadinessGating? = nil
    var focusPolicy: TaskFocusPolicy = .allowApprovedAssist

    var itemWasConfirmedByUser: Bool { riskCategoryConfirmedForThisItem != nil }

    var foregroundAssistContext: ForegroundAssistContext {
        ForegroundAssistContext(itemIdentifier: item.itemIdentifier, itemLabel: item.label, itemParameters: item.parameters,
                                targetApplicationName: checklist.targetApplication.applicationName,
                                riskCategoryConfirmedForThisItem: riskCategoryConfirmedForThisItem,
                                targetProcessIdentifier: checklist.targetApplication.processIdentifier,
                                focusPolicy: focusPolicy)
    }

    func actionConfirmationRequest(reason: String, riskCategory: SafetyRiskCategory) -> SafetyConfirmationRequest {
        SafetyConfirmationRequest(itemIdentifier: item.itemIdentifier, itemLabel: item.label, reason: reason, isActionLevel: true,
                                  riskCategory: riskCategory, itemParameters: item.parameters)
    }
}

struct ChecklistItemExecutionResult: Equatable {
    var runStatus: ChecklistItemRunStatus
    var resultSummary: String
    var actionsPerformed: Int
    var userChoseToStopTask: Bool
    /// The grants in effect after this item, including any the user added during it.
    var riskCategoriesAllowedForRestOfTask: Set<SafetyRiskCategory>
    var recordedSteps: [RecordedAgentStep] = []
    var verifiedCompletionEvidence: StepExpectation? = nil
    /// ADR-13: set once a risky, user-confirmed or confirmed-item action ran, so the item is never retried automatically.
    var performedUserConfirmedAction: Bool = false
    /// Set once an action ran that may have changed data (typing, pressing a control), so at most one retry follows,
    /// and it goes through the agent from a fresh read rather than replaying the routine from its first step.
    var performedSideEffectingAction: Bool = false
    /// The failure would only repeat on a retry (a denied step, an exhausted action budget, a password field).
    var failedDeterministically: Bool = false
}
