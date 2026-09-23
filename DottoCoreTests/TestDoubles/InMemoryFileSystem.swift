import Foundation

/// A file system in memory for direct-route tests: case- and normalization-insensitive names (like APFS), volumes,
/// packages, symbolic links, per-path injected failures and a Trash. Paths are absolute; "/" always exists.
final class InMemoryFileSystem: FileSystemMutating, DirectRouteFileSystemReading, @unchecked Sendable {
    struct Node: Equatable {
        var path: String
        var kind: ExistingFileSystemItemKind
        /// Set on volume roots (and wherever a test wants); other nodes inherit it from their nearest ancestor.
        var volumeIdentifier: String?
        var tags: [String] = []
        var contents: String = ""
        var createdAt: Date?
        var modifiedAt: Date?
        var addedToFolderAt: Date?
        var imageCaptureDate: Date?
        var contentTypeIdentifier: String?
        var conformingTypeIdentifiers: [String] = []
        var isHidden = false
        /// For a symbolic link: the absolute path it points to (used only by `fullyResolvedPath`).
        var symbolicLinkTargetPath: String?
    }

    static let defaultVolumeIdentifier = "volume-main"
    let trashFolderPath: String
    private let stateLock = NSLock()
    private var nodesByKey: [String: Node] = [:]
    /// Keyed by the collision key of the source (or the created path): the next mutation touching it throws this.
    var injectedFailuresByPathKey: [String: FileSystemMutationError] = [:]
    /// Mutations that went through, in order ("move /a → /b"), for assertions.
    private(set) var performedMutations: [String] = []
    /// When set, `finderTags` returns this instead of the stored tags (to make verification fail).
    var tagsReportedAfterSetting: [String]?
    /// Called before each mutation; a test sets the abort signal from here to stop mid-run.
    var beforeEachMutation: (() -> Void)?

    init(homeDirectoryPath: String = "/Users/me") {
        trashFolderPath = homeDirectoryPath + "/.Trash"
        for folderPath in ["/Users", homeDirectoryPath, trashFolderPath, "/Volumes"] {
            nodesByKey[Self.key(folderPath)] = Node(path: folderPath, kind: .folder)
        }
    }

    // MARK: - Building the fixture

    @discardableResult
    func addFolder(_ path: String, volumeIdentifier: String? = nil) -> InMemoryFileSystem {
        addNode(Node(path: path, kind: .folder, volumeIdentifier: volumeIdentifier))
    }

    @discardableResult
    func addFile(_ path: String, contents: String = "", tags: [String] = [], createdAt: Date? = nil, modifiedAt: Date? = nil,
                 imageCaptureDate: Date? = nil, contentTypeIdentifier: String? = nil,
                 conformingTypeIdentifiers: [String] = []) -> InMemoryFileSystem {
        addNode(Node(path: path, kind: .regularFile, tags: tags, contents: contents, createdAt: createdAt, modifiedAt: modifiedAt,
                     imageCaptureDate: imageCaptureDate, contentTypeIdentifier: contentTypeIdentifier,
                     conformingTypeIdentifiers: conformingTypeIdentifiers))
    }

    @discardableResult
    func addItem(_ path: String, kind: ExistingFileSystemItemKind) -> InMemoryFileSystem {
        addNode(Node(path: path, kind: kind))
    }

    @discardableResult
    func addSymbolicLink(_ path: String, pointingTo targetPath: String) -> InMemoryFileSystem {
        addNode(Node(path: path, kind: .symbolicLink, symbolicLinkTargetPath: targetPath))
    }

    /// Makes the next `fullyResolvedPath` of this folder report another real path, as if a folder on it had been
    /// swapped for a link between the dry run and the change.
    var resolvedPathOverridesByPathKey: [String: String] = [:]

    @discardableResult
    private func addNode(_ node: Node) -> InMemoryFileSystem {
        stateLock.withLock {
            var ancestorPath = FileOperationPathRules.parentPath(of: node.path)
            var missingAncestorPaths: [String] = []
            while ancestorPath != "/" && nodesByKey[Self.key(ancestorPath)] == nil {
                missingAncestorPaths.insert(ancestorPath, at: 0)
                ancestorPath = FileOperationPathRules.parentPath(of: ancestorPath)
            }
            for missingAncestorPath in missingAncestorPaths {
                nodesByKey[Self.key(missingAncestorPath)] = Node(path: missingAncestorPath, kind: .folder)
            }
            nodesByKey[Self.key(node.path)] = node
        }
        return self
    }

    func node(atPath path: String) -> Node? {
        stateLock.withLock { nodesByKey[Self.key(path)] }
    }

    /// Every stored path at or below a folder, sorted.
    func allPaths(under folderPath: String) -> [String] {
        stateLock.withLock {
            let folderKey = Self.key(folderPath)
            return nodesByKey.filter { $0.key == folderKey || $0.key.hasPrefix(folderKey + "/") }.map(\.value.path).sorted()
        }
    }

    static func key(_ path: String) -> String {
        FileOperationPathRules.collisionKey(forPath: path)
    }

    // MARK: - DirectRouteFileSystemReading

    func canonicalPathKeepingLastComponent(_ path: String) -> String? {
        let normalizedPath = UploadFileAllowlist.normalizedPath(path)
        guard normalizedPath.hasPrefix("/") else { return nil }
        let parentPath = FileOperationPathRules.parentPath(of: normalizedPath)
        guard parentPath == "/" || existingItemKind(atCanonicalPath: parentPath) != nil else { return nil }
        return normalizedPath
    }

    func canonicalExistingFolderPath(_ path: String) -> String? {
        let normalizedPath = UploadFileAllowlist.normalizedPath(path)
        guard let existingNode = node(atPath: normalizedPath), existingNode.kind == .folder else { return nil }
        return existingNode.path
    }

    func existingItemKind(atCanonicalPath canonicalPath: String) -> ExistingFileSystemItemKind? {
        if canonicalPath == "/" { return .folder }
        return node(atPath: canonicalPath)?.kind
    }

    func volumeIdentifier(ofCanonicalPath canonicalPath: String) -> String? {
        stateLock.withLock {
            var candidatePath = canonicalPath
            while candidatePath != "/" && !candidatePath.isEmpty {
                if let volumeIdentifier = nodesByKey[Self.key(candidatePath)]?.volumeIdentifier { return volumeIdentifier }
                candidatePath = FileOperationPathRules.parentPath(of: candidatePath)
            }
            return Self.defaultVolumeIdentifier
        }
    }

    func listFolder(atCanonicalPath canonicalPath: String, depth: Int, includesHiddenItems: Bool,
                    maximumEntryCount: Int, abortSignal: TaskAbortSignal) async throws -> FolderListing {
        let folderKey = Self.key(canonicalPath)
        let folderDepth = folderKey.split(separator: "/").count
        let descendantNodes = stateLock.withLock {
            nodesByKey.filter { $0.key.hasPrefix(folderKey + "/") }.map(\.value)
        }
        let listedNodes = descendantNodes
            .map { (node: $0, depth: Self.key($0.path).split(separator: "/").count - folderDepth) }
            .filter { $0.depth <= depth && (includesHiddenItems || !(FileOperationPathRules.name(of: $0.node.path).hasPrefix(".") || $0.node.isHidden)) }
            .sorted { $0.node.path < $1.node.path }
        let entries = listedNodes.prefix(maximumEntryCount).map { listedNode in
            FolderListingEntry(path: listedNode.node.path, kind: listedNode.node.kind,
                               isHidden: listedNode.node.isHidden || FileOperationPathRules.name(of: listedNode.node.path).hasPrefix("."),
                               depth: listedNode.depth)
        }
        return FolderListing(folderPath: canonicalPath, entries: Array(entries), omittedEntryCount: max(0, listedNodes.count - maximumEntryCount))
    }

    func readMetadata(ofCanonicalPaths canonicalPaths: [String], abortSignal: TaskAbortSignal) async throws -> [FileMetadataRecord] {
        canonicalPaths.compactMap { canonicalPath in
            guard let existingNode = node(atPath: canonicalPath) else { return nil }
            return FileMetadataRecord(path: existingNode.path, kind: existingNode.kind,
                                      isHidden: existingNode.isHidden || FileOperationPathRules.name(of: existingNode.path).hasPrefix("."),
                                      sizeInBytes: Int64(existingNode.contents.utf8.count), createdAt: existingNode.createdAt,
                                      modifiedAt: existingNode.modifiedAt, addedToFolderAt: existingNode.addedToFolderAt,
                                      contentTypeIdentifier: existingNode.contentTypeIdentifier,
                                      conformingTypeIdentifiers: existingNode.conformingTypeIdentifiers,
                                      imageCaptureDate: existingNode.imageCaptureDate, imagePixelWidth: nil, imagePixelHeight: nil,
                                      finderTags: existingNode.tags, contentIsNotLocal: false,
                                      volumeIdentifier: volumeIdentifier(ofCanonicalPath: existingNode.path))
        }
    }

    // MARK: - FileSystemMutating

    func fullyResolvedPath(ofExistingPath path: String) -> String? {
        if let overriddenPath = stateLock.withLock({ resolvedPathOverridesByPathKey[Self.key(path)] }) { return overriddenPath }
        guard path.hasPrefix("/") else { return nil }
        var resolvedPath = ""
        var remainingComponents = path.split(separator: "/").map(String.init)
        var followedLinkCount = 0
        while !remainingComponents.isEmpty {
            let candidatePath = resolvedPath + "/" + remainingComponents.removeFirst()
            guard let candidateNode = node(atPath: candidatePath) else { return nil }
            if candidateNode.kind == .symbolicLink, let symbolicLinkTargetPath = candidateNode.symbolicLinkTargetPath {
                followedLinkCount += 1
                if followedLinkCount > 32 { return nil }
                remainingComponents = symbolicLinkTargetPath.split(separator: "/").map(String.init) + remainingComponents
                resolvedPath = ""
                continue
            }
            resolvedPath = candidateNode.path
        }
        return resolvedPath.isEmpty ? "/" : resolvedPath
    }

    func createFolder(atCanonicalPath canonicalPath: String) throws {
        try beginMutation(touching: canonicalPath)
        try stateLock.withLock {
            guard nodesByKey[Self.key(canonicalPath)] == nil else { throw FileSystemMutationError.destinationExists }
            let parentPath = FileOperationPathRules.parentPath(of: canonicalPath)
            guard parentPath == "/" || nodesByKey[Self.key(parentPath)]?.kind == .folder else { throw FileSystemMutationError.sourceMissing }
            nodesByKey[Self.key(canonicalPath)] = Node(path: canonicalPath, kind: .folder)
            performedMutations.append("create \(canonicalPath)")
        }
    }

    func moveItemWithoutReplacing(fromCanonicalPath sourcePath: String, toCanonicalPath destinationPath: String) throws {
        try beginMutation(touching: sourcePath)
        let isCaseOnlyRename = Self.key(sourcePath) == Self.key(destinationPath)
        if !isCaseOnlyRename && existingItemKind(atCanonicalPath: destinationPath) != nil { throw FileSystemMutationError.destinationExists }
        guard existingItemKind(atCanonicalPath: sourcePath) != nil else { throw FileSystemMutationError.sourceMissing }
        guard existingItemKind(atCanonicalPath: FileOperationPathRules.parentPath(of: destinationPath)) == .folder else {
            throw FileSystemMutationError.sourceMissing
        }
        if volumeIdentifier(ofCanonicalPath: sourcePath) != volumeIdentifier(ofCanonicalPath: FileOperationPathRules.parentPath(of: destinationPath)) {
            throw FileSystemMutationError.crossVolume
        }
        relocateSubtree(from: sourcePath, to: destinationPath, keepsSource: false)
        stateLock.withLock { performedMutations.append("move \(sourcePath) → \(destinationPath)") }
    }

    func copyItemWithoutReplacing(fromCanonicalPath sourcePath: String, toCanonicalPath destinationPath: String,
                                  abortSignal: TaskAbortSignal) throws {
        try beginMutation(touching: sourcePath)
        if abortSignal.isAborted { throw FileSystemMutationError.stopped }
        if existingItemKind(atCanonicalPath: destinationPath) != nil { throw FileSystemMutationError.destinationExists }
        guard existingItemKind(atCanonicalPath: sourcePath) != nil else { throw FileSystemMutationError.sourceMissing }
        relocateSubtree(from: sourcePath, to: destinationPath, keepsSource: true)
        stateLock.withLock { performedMutations.append("copy \(sourcePath) → \(destinationPath)") }
    }

    func finderTags(atCanonicalPath canonicalPath: String) throws -> [String] {
        guard let existingNode = node(atPath: canonicalPath) else { throw FileSystemMutationError.sourceMissing }
        if let tagsReportedAfterSetting, performedMutations.contains(where: { $0.hasPrefix("tag ") }) { return tagsReportedAfterSetting }
        return existingNode.tags
    }

    func setFinderTags(_ tags: [String], atCanonicalPath canonicalPath: String) throws {
        try beginMutation(touching: canonicalPath)
        try stateLock.withLock {
            guard nodesByKey[Self.key(canonicalPath)] != nil else { throw FileSystemMutationError.sourceMissing }
            nodesByKey[Self.key(canonicalPath)]?.tags = tags
            performedMutations.append("tag \(canonicalPath) \(tags)")
        }
    }

    func moveItemToTrash(atCanonicalPath canonicalPath: String) throws -> String {
        try beginMutation(touching: canonicalPath)
        guard existingItemKind(atCanonicalPath: canonicalPath) != nil else { throw FileSystemMutationError.sourceMissing }
        var trashedItemPath = trashFolderPath + "/" + FileOperationPathRules.name(of: canonicalPath)
        var attempt = 2
        while existingItemKind(atCanonicalPath: trashedItemPath) != nil {
            trashedItemPath = FileOperationPathRules.suffixedPath(trashFolderPath + "/" + FileOperationPathRules.name(of: canonicalPath), attempt: attempt)
            attempt += 1
        }
        relocateSubtree(from: canonicalPath, to: trashedItemPath, keepsSource: false)
        stateLock.withLock { performedMutations.append("trash \(canonicalPath)") }
        return trashedItemPath
    }

    func removeEmptyFolder(atCanonicalPath canonicalPath: String) throws {
        try beginMutation(touching: canonicalPath)
        try stateLock.withLock {
            let folderKey = Self.key(canonicalPath)
            guard nodesByKey[folderKey]?.kind == .folder else { throw FileSystemMutationError.sourceMissing }
            let contentNodes = nodesByKey.filter { $0.key.hasPrefix(folderKey + "/") }.map(\.value)
            let holdsOnlyFinderMetadata = contentNodes.allSatisfy { contentNode in
                contentNode.kind == .regularFile && FileOperationPathRules.parentPath(of: Self.key(contentNode.path)) == folderKey
                    && FileOperationPathRules.finderMetadataFileNames.contains(FileOperationPathRules.name(of: contentNode.path))
            }
            if !holdsOnlyFinderMetadata { throw FileSystemMutationError.notEmpty }
            for contentNode in contentNodes { nodesByKey[Self.key(contentNode.path)] = nil }
            nodesByKey[folderKey] = nil
            performedMutations.append("rmdir \(canonicalPath)")
        }
    }

    // MARK: - Helpers

    private func beginMutation(touching path: String) throws {
        beforeEachMutation?()
        if let injectedFailure = stateLock.withLock({ injectedFailuresByPathKey[Self.key(path)] }) { throw injectedFailure }
    }

    private func relocateSubtree(from sourcePath: String, to destinationPath: String, keepsSource: Bool) {
        stateLock.withLock {
            let sourceKey = Self.key(sourcePath)
            let movedNodes = nodesByKey.filter { $0.key == sourceKey || $0.key.hasPrefix(sourceKey + "/") }
            if !keepsSource { for movedKey in movedNodes.keys { nodesByKey[movedKey] = nil } }
            for movedNode in movedNodes.values {
                var relocatedNode = movedNode
                relocatedNode.path = destinationPath + String(movedNode.path.dropFirst(sourcePath.count))
                if relocatedNode.path == destinationPath { relocatedNode.volumeIdentifier = keepsSource ? nil : movedNode.volumeIdentifier }
                nodesByKey[Self.key(relocatedNode.path)] = relocatedNode
            }
        }
    }
}

final class ScriptedScriptRunner: ScriptRunning, @unchecked Sendable {
    var runningBundleIdentifiers: Set<String>
    var automationPermissionState: AutomationPermissionState
    var scriptedOutput: ScriptRunOutput
    var scriptedError: Error?
    private(set) var ranScriptPlans: [ScriptPlan] = []
    private(set) var automationPermissionRequests: [(bundleIdentifier: String, mayPromptUser: Bool)] = []

    init(runningBundleIdentifiers: Set<String> = ["com.apple.mail"], automationPermissionState: AutomationPermissionState = .granted,
         scriptedOutput: ScriptRunOutput = ScriptRunOutput(exitStatus: 0, standardOutputText: "Created 4 mailboxes",
                                                           standardErrorText: "", timedOut: false, wasStopped: false),
         scriptedError: Error? = nil) {
        self.runningBundleIdentifiers = runningBundleIdentifiers
        self.automationPermissionState = automationPermissionState
        self.scriptedOutput = scriptedOutput
        self.scriptedError = scriptedError
    }

    func automationPermission(forBundleIdentifier bundleIdentifier: String, mayPromptUser: Bool) async -> AutomationPermissionState {
        automationPermissionRequests.append((bundleIdentifier, mayPromptUser))
        return automationPermissionState
    }

    func isApplicationRunning(bundleIdentifier: String) -> Bool {
        runningBundleIdentifiers.contains(bundleIdentifier)
    }

    func run(_ scriptPlan: ScriptPlan, abortSignal: TaskAbortSignal) async throws -> ScriptRunOutput {
        ranScriptPlans.append(scriptPlan)
        if let scriptedError { throw scriptedError }
        return scriptedOutput
    }
}

final class ScriptedShortcutRunner: ShortcutRunning, @unchecked Sendable {
    var listedShortcutNames: [String]
    var scriptedOutput: ShortcutRunOutput
    private(set) var ranShortcutPlans: [ShortcutPlan] = []

    init(listedShortcutNames: [String] = ["Resize for web"],
         scriptedOutput: ShortcutRunOutput = ShortcutRunOutput(exitStatus: 0, outputText: "3 images resized", standardErrorText: "",
                                                               timedOut: false, wasStopped: false)) {
        self.listedShortcutNames = listedShortcutNames
        self.scriptedOutput = scriptedOutput
    }

    func listShortcutNames(abortSignal: TaskAbortSignal) async throws -> [String] { listedShortcutNames }

    func run(_ shortcutPlan: ShortcutPlan, abortSignal: TaskAbortSignal) async throws -> ShortcutRunOutput {
        ranShortcutPlans.append(shortcutPlan)
        return scriptedOutput
    }
}
