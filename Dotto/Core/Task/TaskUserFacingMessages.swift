import Foundation

/// The user-facing text that more than one place shows: item result summaries, status lines, and the descriptions
/// of planning failures, stop reasons and failed teaching.
enum TaskUserFacingMessages {
    static let itemSkippedByUserSummary = "Skipped by the user."
    static let itemStoppedByUserSummary = "Stopped by the user."
    static let itemActionDeclinedByUserSummary = "Skipped: the user declined an action in this item."
    static let itemNeedsForegroundSummary = "Needs the target app in front. Dotto kept it in the background and did not run this step."
    static let itemActionLimitReachedSummary = "Stopped after reaching the action limit for this item."

    static let readyStatusLine = "Ready"
    static let reviewChecklistStatusLine = "Review the checklist"
    static let continuingStatusLine = "Continuing…"
    static let skippingThisItemStatusLine = "Skipping this item…"
    static let missingAnthropicAPIKeyMessage = "Add your Anthropic API key in the menu bar panel to start."
    static let routineNoLongerExistsMessage = "That routine no longer exists."

    static func targetApplicationQuitMessage(applicationName: String) -> String {
        "\(applicationName) quit before Dotto could start"
    }

    static func taskLogCreationFailedMessage(describing error: Error) -> String {
        "Could not create the task log: \(error.localizedDescription)"
    }

    static func userFacingDescription(ofPlanningError planningError: Error) -> String {
        if let checklistPlanningError = planningError as? ChecklistPlanningError {
            switch checklistPlanningError {
            case .refused(let explanation):
                return "Claude declined to plan this task" + (explanation.map { ": \($0)" } ?? ".")
            case .noPlanSubmitted:
                return "Claude didn't produce a checklist. Try rephrasing the command."
            case .aborted:
                return "Planning was stopped."
            case .transportFailed(let transportFailureDescription):
                return "Couldn't reach Claude: \(transportFailureDescription)"
            case .taskCeilingReached(let ceilingDescription):
                return "Stopped: \(ceilingDescription)"
            }
        }
        if let actionBackendError = planningError as? ActionBackendError {
            return actionBackendError.messageForModel
        }
        return planningError.localizedDescription
    }

    static func userFacingDescription(ofStopReason stopReason: TaskStopReason) -> String {
        switch stopReason {
        case .allItemsProcessed:
            return "All items processed"
        case .userAborted:
            return "Stopped by you"
        case .tooManyConsecutiveFailures:
            return "Stopped after several failed items in a row"
        case .taskActionLimitReached:
            return "Stopped: action limit reached"
        case .taskCeilingReached(let ceilingDescription):
            return "Stopped: \(ceilingDescription)"
        case .unrecoverableError(let errorDescription):
            return "Stopped: \(errorDescription)"
        }
    }

    static func userFacingDescription(ofDemonstrationCompileError compileError: Error) -> String {
        guard let demonstrationCompileError = compileError as? DemonstrationCompileError else {
            return compileError.localizedDescription
        }
        switch demonstrationCompileError {
        case .noUsableEvents: return "nothing was recorded"
        case .refused(let explanation): return "Claude declined" + (explanation.map { ": \($0)" } ?? "")
        case .noRoutineSubmitted: return "Claude didn't return a routine"
        case .aborted: return "stopped"
        case .transportFailed(let transportFailureDescription): return "couldn't reach Claude: \(transportFailureDescription)"
        case .taskCeilingReached(let ceilingDescription): return ceilingDescription
        }
    }
}
