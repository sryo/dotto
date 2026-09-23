import Foundation

/// Also an Error, so it can be the failure of a Result.
struct FileOperationPlanProblem: Error, Equatable, Sendable {
    enum Kind: String, Sendable {
        case outsideScope, protectedPath, sourceMissing, sourceKindMismatch, destinationParentMissing,
             invalidName, cycle, crossVolume, tooManyOperations, emptyPlan, scopeRootOperand,
             duplicateSource, hiddenItem, unsupportedOperand, renameChangesFolder
    }
    var kind: Kind
    var operationIndex: Int?
    /// Dotto's wording, basenames only, fed back to the model and shown in the failure card.
    var descriptionForModel: String
}

/// What the validator may ask the real file system. Every closure takes a canonical path and never follows the last
/// component.
struct FileSystemProbe {
    var existingItemKind: (String) -> ExistingFileSystemItemKind?
    var volumeIdentifier: (String) -> String?
    var isInsidePackage: (String) -> Bool
}

enum FileOperationPlanValidationResult: Equatable, Sendable {
    case valid(operations: [PlannedFileOperation], collisionAdjustments: [FileOperationCollisionAdjustment])
    case invalid([FileOperationPlanProblem])
}

/// The dry run: applies the operations in order to a simulated copy of the file system (an overlay over the probe),
/// so every later operation is checked against what the earlier ones will have done. Run at plan time and again
/// right before the run, against the live file system.
enum FileOperationPlanValidator {
    static let maximumTagCount = 20
    static let maximumTagLength = 255

    /// `operationLabels` name each operation in the problems the model reads ("Operation 3", "Date folder rule 1"),
    /// so feedback matches what it wrote; by default "Operation N" in plan order. With
    /// `keepsOperationIdentifiers` (the run-time re-check of an approved plan) kept operations keep their "op-N"
    /// identifiers, so the preview's collision adjustments and the journal still name the same operations.
    static func validate(operations: [PlannedFileOperation], scope: DirectRouteScope, probe: FileSystemProbe,
                         homeDirectoryPath: String, maximumOperationCount: Int, operationLabels: [String]? = nil,
                         keepsOperationIdentifiers: Bool = false) -> FileOperationPlanValidationResult {
        if operations.isEmpty {
            return .invalid([FileOperationPlanProblem(kind: .emptyPlan, operationIndex: nil,
                                                      descriptionForModel: "The plan has no operations.")])
        }
        // Folders the plan creates don't count against the cap on changes (a date rule creates one per month on top
        // of its moves), but they have a cap of their own.
        let createFolderOperationCount = operations.filter { $0.kind == .createFolder }.count
        let changeOperationCount = operations.count - createFolderOperationCount
        if changeOperationCount > maximumOperationCount || createFolderOperationCount > maximumOperationCount {
            return .invalid([FileOperationPlanProblem(
                kind: .tooManyOperations, operationIndex: nil,
                descriptionForModel: "The plan changes \(changeOperationCount) items and creates \(createFolderOperationCount) folders; at most \(maximumOperationCount) of each are allowed.")])
        }
        var planSimulation = FileOperationPlanSimulation(operations: operations, scope: scope, probe: probe,
                                                         homeDirectoryPath: homeDirectoryPath, operationLabels: operationLabels,
                                                         keepsOperationIdentifiers: keepsOperationIdentifiers)
        planSimulation.run()
        if !planSimulation.problems.isEmpty { return .invalid(planSimulation.problems) }
        if planSimulation.keptOperations.isEmpty {
            return .invalid([FileOperationPlanProblem(kind: .emptyPlan, operationIndex: nil,
                                                      descriptionForModel: "Nothing to do: every folder in the plan already exists.")])
        }
        return .valid(operations: planSimulation.keptOperations, collisionAdjustments: planSimulation.collisionAdjustments)
    }

    /// "Operation N" for each operation, in plan order.
    static func defaultOperationLabel(operationIndex: Int) -> String {
        "Operation \(operationIndex + 1)"
    }
}

private struct SimulatedFileSystemItem {
    var kind: ExistingFileSystemItemKind
    var volumeIdentifier: String?
    /// The real path whose descendants are this item's contents; nil for a folder the plan creates (empty).
    var contentsOriginPath: String?
}

private enum SimulatedFileSystemEntry {
    case present(SimulatedFileSystemItem)
    case removed(byOperationIndex: Int)
}

private struct FileOperationPlanSimulation {
    let operations: [PlannedFileOperation]
    let scope: DirectRouteScope
    let probe: FileSystemProbe
    let homeDirectoryPath: String
    let operationLabels: [String]?
    let keepsOperationIdentifiers: Bool
    var entriesByCollisionKey: [String: SimulatedFileSystemEntry] = [:]
    var problems: [FileOperationPlanProblem] = []
    var keptOperations: [PlannedFileOperation] = []
    var collisionAdjustments: [FileOperationCollisionAdjustment] = []

    init(operations: [PlannedFileOperation], scope: DirectRouteScope, probe: FileSystemProbe, homeDirectoryPath: String,
         operationLabels: [String]?, keepsOperationIdentifiers: Bool) {
        self.operations = operations
        self.scope = scope
        self.probe = probe
        self.homeDirectoryPath = homeDirectoryPath
        self.operationLabels = operationLabels
        self.keepsOperationIdentifiers = keepsOperationIdentifiers
    }

    mutating func run() {
        for (operationIndex, operation) in operations.enumerated() {
            if let problem = simulate(operation, operationIndex: operationIndex) {
                problems.append(problem)
            }
        }
    }

    // MARK: - One operation

    /// Applies the operation to the simulation when it is valid (appending it, possibly adjusted, to `keptOperations`),
    /// or returns the problem and leaves the simulation unchanged.
    private mutating func simulate(_ operation: PlannedFileOperation, operationIndex: Int) -> FileOperationPlanProblem? {
        let operationLabel = operationLabels.flatMap { $0.indices.contains(operationIndex) ? $0[operationIndex] : nil }
            ?? FileOperationPlanValidator.defaultOperationLabel(operationIndex: operationIndex)
        func problem(_ kind: FileOperationPlanProblem.Kind, _ descriptionForModel: String) -> FileOperationPlanProblem {
            FileOperationPlanProblem(kind: kind, operationIndex: operationIndex,
                                     descriptionForModel: "\(operationLabel) (\(operation.kind.rawValue)): \(descriptionForModel)")
        }

        let sourcePath = operation.sourcePath.map(UploadFileAllowlist.normalizedPath)
        let destinationPath = operation.destinationPath.map(UploadFileAllowlist.normalizedPath)
        switch operation.kind {
        case .createFolder:
            guard sourcePath == nil, destinationPath != nil else { return problem(.unsupportedOperand, "needs a destination path and no source.") }
        case .move, .rename, .copy:
            guard sourcePath != nil, destinationPath != nil else { return problem(.unsupportedOperand, "needs both a source and a destination path.") }
        case .setTags:
            guard sourcePath != nil, operation.tags != nil else { return problem(.unsupportedOperand, "needs a source path and tags.") }
        case .moveToTrash:
            guard sourcePath != nil else { return problem(.unsupportedOperand, "needs a source path.") }
        }

        let operandPaths = [sourcePath.map { ($0, true) }, destinationPath.map { ($0, false) }].compactMap { $0 }
        for (operandPath, operandIsSource) in operandPaths {
            if let operandProblem = operandPathProblem(operandPath, isSource: operandIsSource) {
                return problem(operandProblem.kind, operandProblem.description)
            }
            if let linkProblem = symbolicLinkAncestorProblem(operandPath) {
                return problem(linkProblem.kind, linkProblem.description)
            }
        }

        var sourceItem: SimulatedFileSystemItem?
        if let sourcePath {
            let sourceName = displayedName(sourcePath)
            let sourceCollisionKey = FileOperationPathRules.collisionKey(forPath: sourcePath)
            if case .removed(let removingOperationIndex) = entriesByCollisionKey[sourceCollisionKey] {
                return problem(.duplicateSource, "\(sourceName) is already moved or trashed by operation \(removingOperationIndex + 1); each item can leave its place only once.")
            }
            guard let existingSourceItem = item(atPath: sourcePath) else {
                return problem(.sourceMissing, "\(sourceName) doesn't exist (or an earlier operation moved it away).")
            }
            switch existingSourceItem.kind {
            case .regularFile, .folder, .package:
                break
            case .symbolicLink:
                // A link moved or renamed into the path of a later operation would carry that operation outside the
                // scope, so links are left alone entirely, like the insides of packages.
                return problem(.sourceKindMismatch, "\(sourceName) is a symbolic link; Dotto leaves links alone.")
            case .other:
                return problem(.unsupportedOperand, "\(sourceName) isn't a file or folder.")
            }
            sourceItem = existingSourceItem
        }

        switch operation.kind {
        case .createFolder:
            guard let destinationPath else { return nil }
            return simulateCreateFolder(operation, destinationPath: destinationPath, problem: problem)
        case .move, .rename, .copy:
            guard let sourcePath, let destinationPath, let sourceItem else { return nil }
            return simulateRelocation(operation, operationIndex: operationIndex, sourcePath: sourcePath, sourceItem: sourceItem,
                                      requestedDestinationPath: destinationPath, problem: problem)
        case .setTags:
            let tags = operation.tags ?? []
            if tags.count > FileOperationPlanValidator.maximumTagCount {
                return problem(.invalidName, "at most \(FileOperationPlanValidator.maximumTagCount) tags are allowed.")
            }
            let hasInvalidTag = tags.contains { tag in
                tag.isEmpty || tag.count > FileOperationPlanValidator.maximumTagLength
                    || tag.unicodeScalars.contains(where: FileOperationPathRules.isControlScalar)
            }
            if hasInvalidTag { return problem(.invalidName, "each tag needs 1 to \(FileOperationPlanValidator.maximumTagLength) characters and no control characters.") }
            keep(operation, sourcePath: sourcePath, destinationPath: nil)
            return nil
        case .moveToTrash:
            guard let sourcePath else { return nil }
            entriesByCollisionKey[FileOperationPathRules.collisionKey(forPath: sourcePath)] = .removed(byOperationIndex: operationIndex)
            keep(operation, sourcePath: sourcePath, destinationPath: nil)
            return nil
        }
    }

    private mutating func simulateCreateFolder(_ operation: PlannedFileOperation, destinationPath: String,
                                               problem: (FileOperationPlanProblem.Kind, String) -> FileOperationPlanProblem)
        -> FileOperationPlanProblem? {
        let folderName = FileOperationPathRules.name(of: destinationPath)
        if let existingItem = item(atPath: destinationPath) {
            // A rule and an explicit operation may both create the same folder; the second one has nothing to do.
            if existingItem.kind == .folder { return nil }
            return problem(.unsupportedOperand, "“\(folderName)” already exists and isn't a folder.")
        }
        if let nameProblem = FileOperationPathRules.validateNewName(folderName, sourceName: nil) {
            return problem(.invalidName, nameProblem)
        }
        let parentPath = FileOperationPathRules.parentPath(of: destinationPath)
        guard let parentItem = item(atPath: parentPath), parentItem.kind == .folder else {
            return problem(.destinationParentMissing, "the folder “\(FileOperationPathRules.name(of: parentPath))” for “\(folderName)” doesn't exist; create it first.")
        }
        place(SimulatedFileSystemItem(kind: .folder, volumeIdentifier: parentItem.volumeIdentifier, contentsOriginPath: nil),
              atPath: destinationPath)
        keep(operation, sourcePath: nil, destinationPath: destinationPath)
        return nil
    }

    private mutating func simulateRelocation(_ operation: PlannedFileOperation, operationIndex: Int, sourcePath: String,
                                             sourceItem: SimulatedFileSystemItem, requestedDestinationPath: String,
                                             problem: (FileOperationPlanProblem.Kind, String) -> FileOperationPlanProblem)
        -> FileOperationPlanProblem? {
        let sourceName = displayedName(sourcePath)
        let sourceParentPath = FileOperationPathRules.parentPath(of: sourcePath)
        let destinationParentPath = FileOperationPathRules.parentPath(of: requestedDestinationPath)
        let requestedName = FileOperationPathRules.name(of: requestedDestinationPath)
        let sourceCollisionKey = FileOperationPathRules.collisionKey(forPath: sourcePath)
        let requestedDestinationCollisionKey = FileOperationPathRules.collisionKey(forPath: requestedDestinationPath)

        if operation.kind == .rename,
           FileOperationPathRules.collisionKey(forPath: sourceParentPath) != FileOperationPathRules.collisionKey(forPath: destinationParentPath) {
            return problem(.renameChangesFolder, "renaming \(sourceName) can't change its folder; use move instead.")
        }
        if requestedDestinationPath == sourcePath {
            return problem(.invalidName, "\(sourceName) is already there with that name.")
        }
        if let nameProblem = FileOperationPathRules.validateNewName(requestedName, sourceName: FileOperationPathRules.name(of: sourcePath)) {
            return problem(.invalidName, nameProblem)
        }
        if requestedDestinationCollisionKey.hasPrefix(sourceCollisionKey + "/") {
            return problem(.cycle, "\(sourceName) can't go inside itself.")
        }
        guard let destinationParentItem = item(atPath: destinationParentPath), destinationParentItem.kind == .folder else {
            return problem(.destinationParentMissing, "the folder “\(FileOperationPathRules.name(of: destinationParentPath))” for \(sourceName) doesn't exist; create it first.")
        }
        if operation.kind != .copy, let sourceVolumeIdentifier = sourceItem.volumeIdentifier,
           let destinationVolumeIdentifier = destinationParentItem.volumeIdentifier, sourceVolumeIdentifier != destinationVolumeIdentifier {
            return problem(.crossVolume, "\(sourceName) would move to another disk; only copies can cross disks.")
        }

        // A case-only rename ("a.png" → "A.png") names the item itself, which is not a collision.
        var adjustedDestinationPath = requestedDestinationPath
        let isCaseOrNormalizationOnlyRename = requestedDestinationCollisionKey == sourceCollisionKey && operation.kind != .copy
        if !isCaseOrNormalizationOnlyRename, item(atPath: requestedDestinationPath) != nil {
            let suffixedDestinationPath = (2...FileOperationPathRules.maximumSuffixAttempt).lazy
                .map { attempt in
                    FileOperationPathRules.suffixedPath(requestedDestinationPath, attempt: attempt, isPlainFolder: sourceItem.kind == .folder)
                }
                .first { candidatePath in self.item(atPath: candidatePath) == nil }
            guard let suffixedDestinationPath else {
                return problem(.invalidName, "every name from “\(requestedName)” to “… \(FileOperationPathRules.maximumSuffixAttempt)” is taken.")
            }
            adjustedDestinationPath = suffixedDestinationPath
        }

        var relocatedItem = sourceItem
        relocatedItem.volumeIdentifier = operation.kind == .copy ? destinationParentItem.volumeIdentifier : sourceItem.volumeIdentifier
        if operation.kind != .copy {
            entriesByCollisionKey[sourceCollisionKey] = .removed(byOperationIndex: operationIndex)
        }
        place(relocatedItem, atPath: adjustedDestinationPath)
        let keptOperationIdentifier = keep(operation, sourcePath: sourcePath, destinationPath: adjustedDestinationPath)
        if adjustedDestinationPath != requestedDestinationPath {
            collisionAdjustments.append(FileOperationCollisionAdjustment(
                operationIdentifier: keptOperationIdentifier, requestedDestinationPath: requestedDestinationPath,
                adjustedDestinationPath: adjustedDestinationPath))
        }
        return nil
    }

    // MARK: - Operand paths

    private func operandPathProblem(_ operandPath: String, isSource: Bool)
        -> (kind: FileOperationPlanProblem.Kind, description: String)? {
        let operandName = displayedName(operandPath)
        guard let operandComponents = FileOperationScopePolicy.normalizedComponents(ofCanonicalPath: operandPath) else {
            return (.outsideScope, "\(operandName) isn't an absolute path.")
        }
        let isScopeRoot = scope.roots.contains { root in
            FileOperationScopePolicy.normalizedComponents(ofCanonicalPath: UploadFileAllowlist.normalizedPath(root.canonicalPath)) == operandComponents
        }
        if isScopeRoot {
            return (.scopeRootOperand, "\(operandName) is a scope folder itself; only what is inside it can change.")
        }
        let isProtected = ProtectedPathPolicy.isProtected(normalizedPathComponents: operandComponents, homeDirectoryPath: homeDirectoryPath)
            || ProtectedPathPolicy.isHomeLibraryFolder(normalizedPathComponents: operandComponents, homeDirectoryPath: homeDirectoryPath)
        if isProtected {
            return (.protectedPath, "\(operandName) is inside a protected folder.")
        }
        if case .denied(let reasonForModel) = FileOperationScopePolicy.evaluateChangeablePath(
            operandPath, scope: scope, homeDirectoryPath: homeDirectoryPath, isInsidePackage: probe.isInsidePackage(operandPath)) {
            return (.outsideScope, reasonForModel)
        }
        if let containingRoot = FileOperationScopePolicy.containingRoot(ofCanonicalPath: operandPath, scope: scope),
           let rootComponents = FileOperationScopePolicy.normalizedComponents(ofCanonicalPath: UploadFileAllowlist.normalizedPath(containingRoot.canonicalPath)) {
            let componentsBelowRoot = operandComponents.dropFirst(rootComponents.count)
            // A hidden new name (a destination's last component) is refused by the name rules with their own wording.
            let checkedComponents = isSource ? componentsBelowRoot : componentsBelowRoot.dropLast()
            if checkedComponents.contains(where: { $0.hasPrefix(".") }) {
                return (.hiddenItem, "\(operandName) is hidden or inside a hidden folder; Dotto leaves hidden items alone.")
            }
        }
        return nil
    }

    /// An operand whose folder, or any folder above it inside its scope root, is a symbolic link in the simulated
    /// file system: the change would land wherever the link points, so it counts as outside the scope.
    private func symbolicLinkAncestorProblem(_ operandPath: String) -> (kind: FileOperationPlanProblem.Kind, description: String)? {
        guard let operandComponents = FileOperationScopePolicy.normalizedComponents(ofCanonicalPath: operandPath),
              let containingRoot = FileOperationScopePolicy.containingRoot(ofCanonicalPath: operandPath, scope: scope),
              let rootComponents = FileOperationScopePolicy.normalizedComponents(
                  ofCanonicalPath: UploadFileAllowlist.normalizedPath(containingRoot.canonicalPath)) else { return nil }
        var ancestorComponentCount = rootComponents.count + 1
        while ancestorComponentCount < operandComponents.count {
            let ancestorPath = "/" + operandComponents.prefix(ancestorComponentCount).joined(separator: "/")
            if item(atPath: ancestorPath)?.kind == .symbolicLink {
                return (.outsideScope, "\(displayedName(operandPath)) would be reached through the link “\(FileOperationPathRules.name(of: ancestorPath))”, which can lead outside the scope folders.")
            }
            ancestorComponentCount += 1
        }
        return nil
    }

    // MARK: - Simulated state

    /// The item at a path after the operations applied so far: an overlaid entry, the contents of a moved or copied
    /// folder (read at its original real path), or the real file system.
    private func item(atPath path: String) -> SimulatedFileSystemItem? {
        if let entry = entriesByCollisionKey[FileOperationPathRules.collisionKey(forPath: path)] {
            if case .present(let overlaidItem) = entry { return overlaidItem }
            return nil
        }
        var ancestorPath = FileOperationPathRules.parentPath(of: path)
        var componentsBelowAncestor = [FileOperationPathRules.name(of: path)]
        while ancestorPath != "/" && !ancestorPath.isEmpty {
            if let ancestorEntry = entriesByCollisionKey[FileOperationPathRules.collisionKey(forPath: ancestorPath)] {
                guard case .present(let ancestorItem) = ancestorEntry, let contentsOriginPath = ancestorItem.contentsOriginPath else {
                    return nil
                }
                return probedItem(atRealPath: contentsOriginPath + "/" + componentsBelowAncestor.joined(separator: "/"))
            }
            componentsBelowAncestor.insert(FileOperationPathRules.name(of: ancestorPath), at: 0)
            ancestorPath = FileOperationPathRules.parentPath(of: ancestorPath)
        }
        return probedItem(atRealPath: path)
    }

    private func probedItem(atRealPath realPath: String) -> SimulatedFileSystemItem? {
        guard let existingKind = probe.existingItemKind(realPath) else { return nil }
        return SimulatedFileSystemItem(kind: existingKind, volumeIdentifier: probe.volumeIdentifier(realPath), contentsOriginPath: realPath)
    }

    private mutating func place(_ simulatedItem: SimulatedFileSystemItem, atPath path: String) {
        entriesByCollisionKey[FileOperationPathRules.collisionKey(forPath: path)] = .present(simulatedItem)
    }

    /// Appends the operation under the next "op-N" identifier (or its own, when identifiers are kept) and returns it.
    @discardableResult
    private mutating func keep(_ operation: PlannedFileOperation, sourcePath: String?, destinationPath: String?) -> String {
        var keptOperation = operation
        if !keepsOperationIdentifiers {
            keptOperation.operationIdentifier = "op-\(keptOperations.count + 1)"
        }
        keptOperation.sourcePath = sourcePath
        keptOperation.destinationPath = destinationPath
        keptOperations.append(keptOperation)
        return keptOperation.operationIdentifier
    }

    private func displayedName(_ path: String) -> String {
        "“\(FileOperationPathRules.name(of: path))”"
    }
}
