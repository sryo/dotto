import Foundation

struct TargetApplicationReference: Codable, Equatable, Sendable {
    var processIdentifier: Int32
    var applicationName: String
    var bundleIdentifier: String?
}

struct ChecklistItemParameter: Codable, Equatable, Sendable { var name: String; var value: String }

enum ChecklistItemRunStatus: String, Codable, Sendable { case pending, running, completed, failed, needsUser, skipped }

struct ChecklistItem: Codable, Equatable, Identifiable, Sendable {
    var itemIdentifier: String
    var label: String
    var actionSummary: String
    var parameters: [ChecklistItemParameter]
    var isIrreversible: Bool
    var isIncludedByUser: Bool = true
    var wasLabelEditedByUser: Bool = false
    var runStatus: ChecklistItemRunStatus = .pending
    var resultSummary: String?
    /// The categories of a saved routine's confirm-each-item steps, so the up-front item confirmation names the
    /// real risk instead of a generic "irreversible" (which covers no risky action).
    var confirmationRiskCategoriesFromRoutine: [SafetyRiskCategory] = []
    var id: String { itemIdentifier }
}

struct Checklist: Codable, Equatable, Sendable {
    var taskIdentifier: String
    var originalCommand: String
    var title: String
    var targetApplication: TargetApplicationReference
    var items: [ChecklistItem]
    var createdAt: Date
    /// Set when the checklist was built from a saved routine file. `originalCommand` and `title` then come from
    /// that file rather than from the user, so prompts show them as untrusted routine metadata.
    var sourceRoutineIdentifier: String? = nil
    /// Set when the planner chose a direct route (file operations, a script or a shortcut). The items are then
    /// display groups of that one plan, which runs as a whole outside `TaskExecutor`.
    var directRoutePlan: DirectRoutePlan? = nil

    static let maximumItemCount = 200

    static func fromPlannerSubmission(_ submittedChecklist: SubmittedChecklistDraft, originalCommand: String,
                                      targetApplication: TargetApplicationReference, taskIdentifier: String,
                                      createdAt: Date) -> Checklist {
        // Item ids are assigned here rather than by the model so they are unique and stable for the audit log.
        let checklistItems = submittedChecklist.items.prefix(maximumItemCount).enumerated().map { itemOffset, submittedItem in
            // The planner's own is_irreversible flag is advisory; any risky wording in what it wrote marks the item too.
            let plannerTextMentionsRiskyVerb = SafetyRiskVocabulary.firstRiskMatch(
                inChecklistItemLabel: submittedItem.label, actionSummary: submittedItem.actionSummary,
                parameters: submittedItem.parameters) != nil
            return ChecklistItem(itemIdentifier: "item-\(itemOffset + 1)",
                                label: ChecklistItemTextRules.normalizedLabel(submittedItem.label),
                                actionSummary: ChecklistItemTextRules.normalizedActionSummary(submittedItem.actionSummary),
                                parameters: submittedItem.parameters,
                                isIrreversible: submittedItem.isIrreversible || plannerTextMentionsRiskyVerb)
        }
        return Checklist(taskIdentifier: taskIdentifier, originalCommand: originalCommand, title: submittedChecklist.taskTitle,
                        targetApplication: targetApplication, items: checklistItems, createdAt: createdAt)
    }

    /// One item per file-operation group (in the plan's group order, so item N is group N), or one item for a script
    /// or a shortcut. Direct-route items are always included and never marked irreversible here: the direct-route
    /// executor asks its own confirmations (moving to the Trash, risky scripts, every shortcut).
    static func fromDirectRoutePlan(_ directRoutePlan: DirectRoutePlan, title: String, originalCommand: String,
                                    targetApplication: TargetApplicationReference, taskIdentifier: String,
                                    createdAt: Date) -> Checklist {
        let checklistItems: [ChecklistItem]
        switch directRoutePlan {
        case .fileOperations(let fileOperationsPlan):
            checklistItems = fileOperationsPlan.groups.prefix(maximumItemCount).enumerated().map { groupOffset, operationGroup in
                let groupOperations = fileOperationsPlan.operations.filter { $0.groupIdentifier == operationGroup.groupIdentifier }
                return ChecklistItem(
                    itemIdentifier: "item-\(groupOffset + 1)", label: operationGroup.title,
                    actionSummary: groupOperations.first.map(exampleSummary(of:)) ?? "",
                    parameters: [ChecklistItemParameter(name: "operation_count", value: String(groupOperations.count))],
                    isIrreversible: false)
            }
        case .script(let scriptPlan):
            checklistItems = [ChecklistItem(itemIdentifier: "item-1", label: "Run script in \(scriptPlan.targetApplicationName)",
                                            actionSummary: scriptPlan.oneSentenceSummary, parameters: [], isIrreversible: false)]
        case .shortcut(let shortcutPlan):
            checklistItems = [ChecklistItem(itemIdentifier: "item-1", label: "Run shortcut “\(shortcutPlan.shortcutName)”",
                                            actionSummary: shortcutPlan.oneSentenceSummary, parameters: [], isIrreversible: false)]
        }
        return Checklist(taskIdentifier: taskIdentifier, originalCommand: originalCommand, title: title,
                         targetApplication: targetApplication, items: checklistItems, createdAt: createdAt,
                         directRoutePlan: directRoutePlan)
    }

    /// "e.g. IMG_2041.png → 2026-09 Septiembre/": the first operation of a group, by basenames only.
    private static func exampleSummary(of plannedFileOperation: PlannedFileOperation) -> String {
        func basename(_ path: String?) -> String { path.map { ($0 as NSString).lastPathComponent } ?? "" }
        func parentFolderName(_ path: String?) -> String {
            path.map { (($0 as NSString).deletingLastPathComponent as NSString).lastPathComponent } ?? ""
        }
        let sourceName = basename(plannedFileOperation.sourcePath)
        switch plannedFileOperation.kind {
        case .createFolder:
            return "e.g. “\(basename(plannedFileOperation.destinationPath))”"
        case .move, .copy:
            return "e.g. \(sourceName) → \(parentFolderName(plannedFileOperation.destinationPath))/"
        case .rename:
            return "e.g. \(sourceName) → \(basename(plannedFileOperation.destinationPath))"
        case .setTags:
            let tagList = (plannedFileOperation.tags ?? []).joined(separator: ", ")
            return tagList.isEmpty ? "e.g. \(sourceName): no tags" : "e.g. \(sourceName): \(tagList)"
        case .moveToTrash:
            return "e.g. \(sourceName) → Trash"
        }
    }

    var includedItems: [ChecklistItem] { items.filter(\.isIncludedByUser) }

    func updatingItem(withIdentifier itemIdentifier: String, _ mutateItem: (inout ChecklistItem) -> Void) -> Checklist {
        var updatedChecklist = self
        if let itemIndex = updatedChecklist.items.firstIndex(where: { $0.itemIdentifier == itemIdentifier }) {
            mutateItem(&updatedChecklist.items[itemIndex])
        }
        return updatedChecklist
    }
}
