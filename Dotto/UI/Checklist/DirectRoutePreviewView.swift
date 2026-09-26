import SwiftUI

/// The approval preview of a direct route, shown in the checklist popover in place of the item list: the grouped
/// file changes, the script verbatim, or the shortcut and its input. Direct-route items can't be unchecked or edited
/// (the plan is approved and run as a whole) and can't be taught.
struct DirectRoutePreviewView: View {
    let directRoutePlan: DirectRoutePlan
    @ObservedObject var directRouteSessionState: DirectRouteSessionState

    var body: some View {
        switch directRoutePlan {
        case .fileOperations(let fileOperationsPlan):
            FileOperationsPreviewTable(fileOperationsPlan: fileOperationsPlan)
        case .script(let scriptPlan):
            ScriptPreviewView(scriptPlan: scriptPlan,
                              automationPermissionState: directRouteSessionState.currentPlannerContext.targetApplicationAutomationState)
        case .shortcut(let shortcutPlan):
            ShortcutPreviewView(shortcutPlan: shortcutPlan)
        }
    }

    /// "Runs directly in “Screenshots” · no cursor needed"
    static func subtitle(for directRoutePlan: DirectRoutePlan) -> String {
        switch directRoutePlan {
        case .fileOperations(let fileOperationsPlan):
            return "Runs directly in \(FileOperationPreviewText.scopeDescription(fileOperationsPlan.scope)) · no cursor needed"
        case .script(let scriptPlan):
            return "Runs directly in \(scriptPlan.targetApplicationName) · no cursor needed"
        case .shortcut:
            return "Runs directly · no cursor needed"
        }
    }
}

/// Cancel and Run for a direct route, plus "Use the cursor instead" for a script, which plans the same command
/// again as an ordinary checklist.
struct DirectRouteApprovalFooter: View {
    @ObservedObject var sessionScope: TaskSessionScope
    let directRoutePlan: DirectRoutePlan

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if case .script = directRoutePlan {
                Button("Use the cursor instead") { sessionScope.replanUsingCursorInstead() }
                    .dsOutlinedButtonStyle()
                    .nativeTooltip("Plan this again as a checklist Dotto does with its cursor")
            }
            HStack(spacing: 8) {
                Button("Cancel") { sessionScope.cancelChecklist() }
                    .dsSecondaryButtonStyle()
                Button(runButtonTitle) { sessionScope.approveChecklistAndRun() }
                    .dsPrimaryButtonStyle()
            }
        }
    }

    private var runButtonTitle: String {
        switch directRoutePlan {
        case .fileOperations(let fileOperationsPlan):
            if fileOperationsPlan.operations.contains(where: { $0.kind == .moveToTrash }) {
                return "Run · asks before trashing"
            }
            let changeCount = fileOperationsPlan.operations.count
            return changeCount == 1 ? "Run 1 change" : "Run \(changeCount) changes"
        case .script:
            return "Run script"
        case .shortcut:
            return "Run shortcut"
        }
    }
}
