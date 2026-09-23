import Foundation

/// Where a scope root came from. Only the user's own command, reply, attachments or the Finder window they summoned
/// Dotto over can create one; nothing the model or a screen says ever does.
enum DirectRouteScopeRootSource: String, Codable, Sendable {
    case finderWindowUnderSummonPoint = "finder_window"
    case attachedByUser = "attached"
    case typedInCommand = "typed_in_command"
    case typedInUserReply = "typed_in_user_reply"
}

struct DirectRouteScopeRoot: Codable, Equatable, Sendable {
    /// Absolute, symlinks resolved, data-volume prefix stripped (`UploadFileAllowlist.normalizedPath`).
    var canonicalPath: String
    var source: DirectRouteScopeRootSource
}

struct DirectRouteScope: Codable, Equatable, Sendable {
    var roots: [DirectRouteScopeRoot]
    static let empty = DirectRouteScope(roots: [])
    static let maximumRootCount = 4
}

/// What the planner is told about direct routes for this task. Built by the App before planning.
struct PlannerDirectRouteContext: Equatable, Sendable {
    var scope: DirectRouteScope
    var targetApplicationIsScriptable: Bool
    var targetApplicationAutomationState: AutomationPermissionState
    /// False after the user chose "Use the cursor instead", or when direct routes are turned off.
    var directRoutesAreEnabled: Bool
    /// Scripts and Shortcuts may activate apps through effects the executor cannot inspect.
    var focusPolicy: TaskFocusPolicy = .allowApprovedAssist
    /// The task's target is Finder, so a request about files is a file operations task.
    var targetApplicationIsFinder: Bool = false
    /// Items the user had selected in the Finder window they summoned Dotto over (canonical paths inside a scope
    /// root), so "these" can mean them.
    var finderSelectionPaths: [String] = []
    static let disabled = PlannerDirectRouteContext(scope: .empty, targetApplicationIsScriptable: false,
                                                    targetApplicationAutomationState: .unknown,
                                                    directRoutesAreEnabled: false)
}

enum AutomationPermissionState: String, Codable, Equatable, Sendable {
    case granted, notYetAsked = "not_yet_asked", denied, targetNotRunning = "target_not_running", unknown
}

enum DirectRoutePlan: Codable, Equatable, Sendable {
    case fileOperations(FileOperationsPlan)
    case script(ScriptPlan)
    case shortcut(ShortcutPlan)
}

// MARK: - File operations

enum FileOperationKind: String, Codable, CaseIterable, Sendable {
    case createFolder = "create_folder", move, rename, copy, setTags = "set_tags", moveToTrash = "move_to_trash"
}

struct PlannedFileOperation: Codable, Equatable, Identifiable, Sendable {
    /// "op-1"…: assigned by Dotto in execution order, stable for the journal and the audit log.
    var operationIdentifier: String
    var kind: FileOperationKind
    /// Canonical absolute paths. `sourcePath` is nil only for createFolder; `destinationPath` is nil for setTags and
    /// moveToTrash. For move, rename and copy it is the full new path including the name.
    var sourcePath: String?
    var destinationPath: String?
    /// setTags only: the complete new tag set.
    var tags: [String]?
    /// Model-written, ≤ 120 characters, shown in the expanded preview row. Untrusted text; never parsed.
    var reason: String
    var groupIdentifier: String
    var id: String { operationIdentifier }
}

struct FileOperationGroup: Codable, Equatable, Identifiable, Sendable {
    var groupIdentifier: String
    /// ≤ 60 characters, e.g. "Move 23 screenshots into month folders".
    var title: String
    var id: String { groupIdentifier }
}

/// A name Dotto changed so nothing is overwritten ("IMG_1.png" → "IMG_1 2.png"). Shown in the preview.
struct FileOperationCollisionAdjustment: Codable, Equatable, Sendable {
    var operationIdentifier: String
    var requestedDestinationPath: String
    var adjustedDestinationPath: String
}

struct FileOperationsPlan: Codable, Equatable, Sendable {
    var scope: DirectRouteScope
    var groups: [FileOperationGroup]
    /// Expanded (rules included), canonicalized, dry-run validated, in execution order.
    var operations: [PlannedFileOperation]
    var collisionAdjustments: [FileOperationCollisionAdjustment]
    static let maximumOperationCount = 2_000
}

// MARK: - Scripts and shortcuts

enum ScriptLanguage: String, Codable, Sendable { case appleScript = "applescript", javaScript = "jxa" }

struct ScriptPlan: Codable, Equatable, Sendable {
    var targetBundleIdentifier: String
    var targetApplicationName: String
    var language: ScriptLanguage
    /// Shown verbatim and run verbatim; ≤ 20,000 characters.
    var source: String
    var oneSentenceSummary: String
    var expectedEffects: [String]
    var modifiesData: Bool
    /// Clamped to 5...300.
    var timeoutSeconds: Int
    /// Filled in by Dotto (ScriptSourceInspector), never by the model.
    var inspection: ScriptSourceInspection
    /// The task's scope folders when the plan was accepted, so a Finder script that names paths outside them (or
    /// works on files with no scope at all) asks first. Set by Dotto, never by the model.
    var fileScope: DirectRouteScope? = nil
    static let maximumSourceLength = 20_000
}

struct ScriptSourceInspection: Codable, Equatable, Sendable {
    /// Application names and bundle ids the source addresses, as written.
    var referencedApplicationSpecifiers: [String]
    /// Constructs that make the script unrunnable ("do shell script", "System Events", …). Non-empty = denied.
    var deniedConstructs: [String]
    /// The first risky verb found by SafetyRiskVocabulary plus the AppleScript verb table, if any.
    var riskMatch: SafetyRiskMatch?
}

enum ShortcutInput: Codable, Equatable, Sendable {
    case none
    /// Written to a 0600 temporary file and passed with --input-path.
    case text(String)
    /// Canonical paths inside the scope, 1...20.
    case files([String])
}

struct ShortcutPlan: Codable, Equatable, Sendable {
    /// Exactly as `shortcuts list` printed it.
    var shortcutName: String
    var input: ShortcutInput
    var oneSentenceSummary: String
    var timeoutSeconds: Int
}

// MARK: - Run results

struct FileOperationFailure: Codable, Equatable, Sendable {
    var operationIdentifier: String
    /// Dotto's own wording, naming files by basename.
    var userFacingReason: String
}

struct DirectRouteRunReport: Equatable, Sendable {
    var completedOperationCount: Int
    var failedOperationCount: Int
    var skippedOperationCount: Int
    /// At most 50, in order.
    var failures: [FileOperationFailure]
    /// Set when at least one undoable entry was journaled.
    var undoJournalIdentifier: String?
    /// Script or shortcut output, ≤ 2,000 characters; untrusted, shown as plain monospaced text only.
    var outputText: String?
    var durationSeconds: Double
}

// MARK: - Performer protocols (implemented in Platform, faked in tests)

enum ExistingFileSystemItemKind: String, Codable, Equatable, Sendable {
    case regularFile, folder, package, symbolicLink, other
}

struct FolderListingEntry: Codable, Equatable, Sendable {
    var path: String
    var kind: ExistingFileSystemItemKind
    var isHidden: Bool
    var depth: Int
}

struct FolderListing: Equatable, Sendable {
    var folderPath: String
    var entries: [FolderListingEntry]
    /// Entries beyond the cap, counted but not listed.
    var omittedEntryCount: Int
}

struct FileMetadataRecord: Codable, Equatable, Sendable {
    var path: String
    var kind: ExistingFileSystemItemKind
    var isHidden: Bool
    var sizeInBytes: Int64?
    var createdAt: Date?
    var modifiedAt: Date?
    var addedToFolderAt: Date?
    var contentTypeIdentifier: String?
    /// The content type and every type it conforms to, e.g. ["public.png", "public.image", "public.data", "public.item"].
    var conformingTypeIdentifiers: [String]
    /// EXIF DateTimeOriginal (with OffsetTimeOriginal when present, else the current time zone). Never read for
    /// files whose contents aren't local (iCloud dataless), so reading metadata never downloads anything.
    var imageCaptureDate: Date?
    var imagePixelWidth: Int?
    var imagePixelHeight: Int?
    var finderTags: [String]
    var contentIsNotLocal: Bool
    /// APFS volume identity, so cross-volume moves can be refused.
    var volumeIdentifier: String?
}

protocol DirectRouteFileSystemReading: AnyObject, Sendable {
    /// realpath of the parent plus the unresolved last component (a symlink is the link, not its target), with the
    /// data-volume prefix stripped. nil if the parent doesn't exist.
    func canonicalPathKeepingLastComponent(_ path: String) -> String?
    /// realpath of an existing folder; nil unless it exists and is a folder (not a package).
    func canonicalExistingFolderPath(_ path: String) -> String?
    /// lstat: never follows the last component.
    func existingItemKind(atCanonicalPath canonicalPath: String) -> ExistingFileSystemItemKind?
    func volumeIdentifier(ofCanonicalPath canonicalPath: String) -> String?
    func listFolder(atCanonicalPath canonicalPath: String, depth: Int, includesHiddenItems: Bool,
                    maximumEntryCount: Int, abortSignal: TaskAbortSignal) async throws -> FolderListing
    func readMetadata(ofCanonicalPaths canonicalPaths: [String], abortSignal: TaskAbortSignal) async throws -> [FileMetadataRecord]
}

enum FileSystemMutationError: Error, Equatable, Sendable {
    case destinationExists, sourceMissing, permissionDenied, notEmpty, crossVolume, stopped
    case other(String)
}

protocol FileSystemMutating: AnyObject, Sendable {
    /// mkdir without intermediates; fails with destinationExists if anything is there.
    func createFolder(atCanonicalPath canonicalPath: String) throws
    /// Atomic rename that never replaces: renamex_np(RENAME_EXCL). Same volume only.
    func moveItemWithoutReplacing(fromCanonicalPath sourcePath: String, toCanonicalPath destinationPath: String) throws
    /// copyfile(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_EXCL) with a callback that quits when the abort signal is set.
    func copyItemWithoutReplacing(fromCanonicalPath sourcePath: String, toCanonicalPath destinationPath: String,
                                  abortSignal: TaskAbortSignal) throws
    func finderTags(atCanonicalPath canonicalPath: String) throws -> [String]
    func setFinderTags(_ tags: [String], atCanonicalPath canonicalPath: String) throws
    /// FileManager.trashItem; returns the item's path inside the Trash.
    func moveItemToTrash(atCanonicalPath canonicalPath: String) throws -> String
    /// rmdir: only succeeds on a folder that is empty apart from Finder's own metadata
    /// (`FileOperationPathRules.finderMetadataFileNames`), which goes first. Used only to undo folders Dotto created.
    func removeEmptyFolder(atCanonicalPath canonicalPath: String) throws
    func existingItemKind(atCanonicalPath canonicalPath: String) -> ExistingFileSystemItemKind?
    /// realpath of an existing item: every symbolic link resolved, the data-volume prefix stripped; nil when missing.
    /// Asked right before each change, so a folder swapped for a link since the dry run is caught.
    func fullyResolvedPath(ofExistingPath path: String) -> String?
}

struct ScriptRunOutput: Equatable, Sendable {
    var exitStatus: Int32
    var standardOutputText: String
    var standardErrorText: String
    var timedOut: Bool
    var wasStopped: Bool
}

/// Runs an approved script out of process through /usr/bin/osascript (argument array, source on stdin, no shell), so
/// Stop and the timeout can kill it.
protocol ScriptRunning: AnyObject, Sendable {
    func automationPermission(forBundleIdentifier bundleIdentifier: String, mayPromptUser: Bool) async -> AutomationPermissionState
    func isApplicationRunning(bundleIdentifier: String) -> Bool
    func run(_ scriptPlan: ScriptPlan, abortSignal: TaskAbortSignal) async throws -> ScriptRunOutput
}

struct ShortcutRunOutput: Equatable, Sendable {
    var exitStatus: Int32
    var outputText: String
    var standardErrorText: String
    var timedOut: Bool
    var wasStopped: Bool
}

/// Lists and runs the user's shortcuts through /usr/bin/shortcuts with an argument array, by exact listed name.
protocol ShortcutRunning: AnyObject, Sendable {
    func listShortcutNames(abortSignal: TaskAbortSignal) async throws -> [String]
    func run(_ shortcutPlan: ShortcutPlan, abortSignal: TaskAbortSignal) async throws -> ShortcutRunOutput
}
