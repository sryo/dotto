import Foundation

/// The planner's read-only direct-route tools. Every path is scope-checked by the planner before anything is read.
enum DirectRouteReadRequest: Equatable, Sendable {
    /// depth is clamped to 1...2 by the decoder.
    case listFolder(path: String, depth: Int, includesHiddenItems: Bool)
    /// 1...200 paths, else an input error.
    case readFileMetadata(paths: [String])
    /// Every non-hidden item directly inside one folder, so the model never writes out a folder's paths to read them.
    case readFolderMetadata(folderPath: String)
    case listShortcuts(query: String?)
}

struct SubmittedFileOperationDraft: Equatable, Sendable {
    var kind: FileOperationKind
    var fromPath: String?
    var toPath: String?
    var tags: [String]?
    var reason: String
    var groupIdentifier: String
}

enum DateFolderRuleDateSource: String, Codable, Sendable {
    case captureDateOrCreated = "capture_date_or_created", created, modified, added
}

struct SubmittedDateFolderRule: Codable, Equatable, Sendable {
    var sourceFolderPath: String
    var destinationParentFolderPath: String
    var nameContains: String?
    var lowercasedExtensions: [String]
    var typeIdentifiers: [String]
    var dateSource: DateFolderRuleDateSource
    var folderNameFormat: String
    var groupIdentifier: String
}

/// The order a rename rule numbers files in. Date orders run oldest first unless the rule is descending.
enum RenameRuleOrder: String, Codable, Sendable {
    case name, created, modified, added
    case captureDateOrCreated = "capture_date_or_created"
}

struct SubmittedRenameRule: Codable, Equatable, Sendable {
    var sourceFolderPath: String
    var nameContains: String?
    var lowercasedExtensions: [String]
    var typeIdentifiers: [String]
    var order: RenameRuleOrder
    var isDescending: Bool
    /// The date `{date:…}` tokens use; nil when the template has none.
    var dateSource: DateFolderRuleDateSource?
    var nameTemplate: String
    var groupIdentifier: String
}

struct SubmittedFileOperationsDraft: Equatable, Sendable {
    var taskTitle: String
    var messageToUser: String?
    var groups: [FileOperationGroup]
    var operations: [SubmittedFileOperationDraft]
    var dateFolderRules: [SubmittedDateFolderRule]
    var renameRules: [SubmittedRenameRule]
    var continuesInNextCall: Bool
}

struct SubmittedScriptPlanDraft: Equatable, Sendable {
    var taskTitle: String
    var targetBundleIdentifier: String
    var language: ScriptLanguage
    var source: String
    var summary: String
    var expectedEffects: [String]
    var modifiesData: Bool
    var timeoutSeconds: Int
}

struct SubmittedShortcutPlanDraft: Equatable, Sendable {
    var taskTitle: String
    var shortcutName: String
    var input: ShortcutInput
    var summary: String
    var timeoutSeconds: Int
}

enum SubmittedDirectRoutePlanDraft: Equatable, Sendable {
    case fileOperations(SubmittedFileOperationsDraft)
    case script(SubmittedScriptPlanDraft)
    case shortcut(SubmittedShortcutPlanDraft)
}
