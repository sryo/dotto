import Foundation

/// The confirmations a direct route asks before it runs. They go through SafetyConfirmationFlow like every other
/// confirmation, so a grant stays scoped to one category: `.runningScript` never covers `.deleting`, and
/// `.runningShortcut` is asked on every run.
extension SafetyGate {
    /// deny from ScriptTargetPolicy first; then a risky verb → its category; then a Finder script that names places
    /// outside the scope folders, or uses file verbs without naming a place inside them → `.runningScript`, naming
    /// those places; else modifiesData → `.runningScript`; else allow (the user already read the script before choosing
    /// Run). A risky verb's question also names the Finder places. The result then goes through `applyingAskPolicy`,
    /// so only a verb whose category asks (sending, deleting, paying) reaches the user.
    static func evaluateScriptPlan(_ scriptPlan: ScriptPlan, homeDirectoryPath: String = NSHomeDirectory()) -> SafetyVerdict {
        applyingAskPolicy(unfilteredScriptPlanVerdict(scriptPlan, homeDirectoryPath: homeDirectoryPath))
    }

    private static func unfilteredScriptPlanVerdict(_ scriptPlan: ScriptPlan, homeDirectoryPath: String) -> SafetyVerdict {
        let targetVerdict = ScriptTargetPolicy.evaluate(scriptPlan)
        if case .deny = targetVerdict { return targetVerdict }
        let applicationName = scriptPlan.targetApplicationName
        let fileReferenceReason = ScriptFileReferenceInspector.confirmationReason(for: scriptPlan, homeDirectoryPath: homeDirectoryPath)
        if let riskMatch = ScriptSourceInspector.riskMatch(inSource: scriptPlan.source) {
            return .requireUserConfirmation(
                reason: "This script for \(applicationName) mentions “\(riskMatch.matchedText)” "
                    + "(\(riskMatch.riskCategory.userFacingScopeDescription)). Dotto can't undo what it changes."
                    + (fileReferenceReason.map { " " + $0 } ?? ""),
                riskCategory: riskMatch.riskCategory)
        }
        if let fileReferenceReason {
            return .requireUserConfirmation(reason: fileReferenceReason + " Dotto can't undo what it changes.",
                                            riskCategory: .runningScript)
        }
        if scriptPlan.modifiesData {
            return .requireUserConfirmation(
                reason: "This script changes data in \(applicationName). Dotto can't undo what it changes.",
                riskCategory: .runningScript)
        }
        return .allow
    }

    /// Always `.runningShortcut`: a shortcut is opaque and may contain any action.
    static func evaluateShortcutPlan(_ shortcutPlan: ShortcutPlan) -> SafetyVerdict {
        .requireUserConfirmation(
            reason: "Run your shortcut “\(shortcutPlan.shortcutName)”? Shortcuts can do anything their actions allow, "
                + "and Dotto can't see inside them or undo them.",
            riskCategory: .runningShortcut)
    }

    /// `.deleting`, naming up to 5 items and the count, when the plan moves anything to the Trash.
    static func evaluateFileOperationsPlan(_ fileOperationsPlan: FileOperationsPlan) -> SafetyVerdict {
        let trashedItemNames = fileOperationsPlan.operations
            .filter { $0.kind == .moveToTrash }
            .compactMap(\.sourcePath)
            .map { "“\(FileOperationPathRules.name(of: $0))”" }
        guard !trashedItemNames.isEmpty else { return .allow }
        let itemCountText = trashedItemNames.count == 1 ? "1 item" : "\(trashedItemNames.count) items"
        return .requireUserConfirmation(
            reason: "This moves \(itemCountText) to the Trash: \(namedListDescription(trashedItemNames, maximumNamedCount: 5)). "
                + "You can put them back with Undo or from the Trash.",
            riskCategory: .deleting)
    }
}
