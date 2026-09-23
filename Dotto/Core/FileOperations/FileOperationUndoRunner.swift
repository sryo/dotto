import Foundation

enum FileOperationUndoStep: Equatable, Sendable {
    /// Undoes a move or a rename.
    case moveBack(fromPath: String, toOriginalPath: String)
    case restoreFromTrash(trashedItemPath: String, toOriginalPath: String)
    /// Undoes a copy: the copy goes to the Trash, never deleted.
    case trashCopy(copyPath: String)
    case removeCreatedFolderIfEmpty(folderPath: String)
    case restoreTags(path: String, tags: [String])
}

enum FileOperationUndoPlanner {
    /// Reverse order of the journal, so a file goes back before the folder it was moved into is removed.
    static func undoSteps(for entries: [FileOperationJournalEntry]) -> [FileOperationUndoStep] {
        undoStepsWithOperationIdentifiers(for: entries).map(\.undoStep)
    }

    /// The same steps, each with the operation it reverses, so a reversed step can be journaled.
    static func undoStepsWithOperationIdentifiers(for entries: [FileOperationJournalEntry])
        -> [(operationIdentifier: String, undoStep: FileOperationUndoStep)] {
        entries.reversed().compactMap { entry in
            undoStep(for: entry).map { (entry.operationIdentifier, $0) }
        }
    }

    private static func undoStep(for entry: FileOperationJournalEntry) -> FileOperationUndoStep? {
        switch entry.kind {
        case .move, .rename:
            guard let sourcePath = entry.sourcePath, let destinationPath = entry.destinationPath else { return nil }
            return .moveBack(fromPath: destinationPath, toOriginalPath: sourcePath)
        case .copy:
            guard let destinationPath = entry.destinationPath else { return nil }
            return .trashCopy(copyPath: destinationPath)
        case .createFolder:
            guard let destinationPath = entry.destinationPath else { return nil }
            return .removeCreatedFolderIfEmpty(folderPath: destinationPath)
        case .setTags:
            guard let sourcePath = entry.sourcePath else { return nil }
            return .restoreTags(path: sourcePath, tags: entry.previousTags ?? [])
        case .moveToTrash:
            guard let sourcePath = entry.sourcePath, let trashedItemPath = entry.trashedItemPath else { return nil }
            return .restoreFromTrash(trashedItemPath: trashedItemPath, toOriginalPath: sourcePath)
        }
    }
}

struct FileOperationUndoReport: Equatable, Sendable {
    var revertedCount: Int
    var skippedCount: Int
    /// At most 20, in order.
    var skippedReasons: [String]
}

enum FileOperationUndoError: Error, Equatable {
    /// The journal was already undone, has nothing left to undo, or its task is still running.
    case journalNotUndoable(FileOperationJournalStatus)
}

/// Reverses a journaled task. It never overwrites (an occupied original path is left alone and reported, not
/// suffixed, which would scatter the user's files) and never deletes (a non-empty created folder stays, a copy goes
/// to the Trash). Every step is checked against the live file system first, including the real folder of each path
/// (`FileOperationContainmentCheck` against the task's scope), and each reversed step is journaled, so an undo that
/// stopped partway carries on with what is left.
final class FileOperationUndoRunner: Sendable {
    static let maximumReportedSkipReasonCount = 20

    private let fileSystem: FileSystemMutating
    private let journalStore: FileOperationJournalStore
    private let auditLogWriter: AuditLogWriter?
    private let homeDirectoryPath: String

    init(fileSystem: FileSystemMutating, journalStore: FileOperationJournalStore, auditLogWriter: AuditLogWriter?,
         homeDirectoryPath: String = NSHomeDirectory()) {
        self.fileSystem = fileSystem
        self.journalStore = journalStore
        self.auditLogWriter = auditLogWriter
        self.homeDirectoryPath = homeDirectoryPath
    }

    /// Runs off the main actor: every step is a blocking system call, and the pill must keep drawing and Stop must
    /// stay clickable. Progress goes to `onProgress`, which hops to wherever its caller needs it.
    @concurrent
    func undo(journalIdentifier: String, abortSignal: TaskAbortSignal,
              onProgress: @escaping (FileOperationProgress) async -> Void) async throws -> FileOperationUndoReport {
        let loadedJournal = try journalStore.loadJournal(journalIdentifier)
        guard loadedJournal.isUndoable else {
            throw FileOperationUndoError.journalNotUndoable(loadedJournal.status)
        }
        let scope = loadedJournal.header.scope
        let undoSteps = FileOperationUndoPlanner.undoStepsWithOperationIdentifiers(for: loadedJournal.entriesNotYetReverted)
        var revertedCount = 0
        var skippedReasons: [String] = []
        var lastProgressReportDate: Date?

        for (stepIndex, undoStepWithIdentifier) in undoSteps.enumerated() {
            let undoStep = undoStepWithIdentifier.undoStep
            if abortSignal.isAborted {
                let remainingStepCount = undoSteps.count - stepIndex
                skippedReasons.append("Stopped before undoing the last \(remainingStepCount) change\(remainingStepCount == 1 ? "" : "s").")
                break
            }
            let progressReportDate = Date()
            if lastProgressReportDate.map({ progressReportDate.timeIntervalSince($0) >= FileOperationRunner.minimumSecondsBetweenProgressEvents }) ?? true {
                lastProgressReportDate = progressReportDate
                await onProgress(FileOperationProgress(completedCount: stepIndex, totalCount: undoSteps.count,
                                                       currentOperationDescription: Self.progressDescription(of: undoStep),
                                                       groupIdentifier: "undo"))
            }
            if let skipReason = perform(undoStep, scope: scope) {
                skippedReasons.append(skipReason)
                audit(undoStep, result: "skipped: \(skipReason)", journalIdentifier: journalIdentifier)
            } else {
                revertedCount += 1
                try? journalStore.markReverted(operationIdentifier: undoStepWithIdentifier.operationIdentifier, inJournal: journalIdentifier)
                audit(undoStep, result: "reverted", journalIdentifier: journalIdentifier)
            }
        }
        await onProgress(FileOperationProgress(completedCount: undoSteps.count, totalCount: undoSteps.count,
                                               currentOperationDescription: "Undone", groupIdentifier: "undo"))
        let skippedCount = undoSteps.count - revertedCount
        try journalStore.markStatus(skippedCount == 0 ? .undone : .partiallyUndone, ofJournal: journalIdentifier)
        return FileOperationUndoReport(revertedCount: revertedCount, skippedCount: skippedCount,
                                       skippedReasons: Array(skippedReasons.prefix(Self.maximumReportedSkipReasonCount)))
    }

    /// Returns nil when the step was reverted, else why it was left as it is.
    private func perform(_ undoStep: FileOperationUndoStep, scope: DirectRouteScope) -> String? {
        // A path in the Trash is where macOS put the item, outside the scope by design; every other path is checked.
        for checkedPath in Self.pathsCheckedForContainment(of: undoStep) {
            if let containmentProblem = FileOperationContainmentCheck.problem(operandPath: checkedPath, fileSystem: fileSystem,
                                                                             scope: scope, homeDirectoryPath: homeDirectoryPath) {
                return containmentProblem
            }
        }
        do {
            switch undoStep {
            case .moveBack(let fromPath, let toOriginalPath):
                let displayedName = Self.displayedName(toOriginalPath)
                guard let movedItemKind = fileSystem.existingItemKind(atCanonicalPath: fromPath) else {
                    return "\(displayedName) is no longer where Dotto put it."
                }
                if movedItemKind == .symbolicLink {
                    return "\(displayedName) was replaced by a symbolic link; Dotto leaves links alone."
                }
                let isCaseOnlyRename = FileOperationPathRules.collisionKey(forPath: fromPath) == FileOperationPathRules.collisionKey(forPath: toOriginalPath)
                if !isCaseOnlyRename && fileSystem.existingItemKind(atCanonicalPath: toOriginalPath) != nil {
                    return "\(displayedName) wasn't moved back: something else now has its original name."
                }
                try fileSystem.moveItemWithoutReplacing(fromCanonicalPath: fromPath, toCanonicalPath: toOriginalPath)
            case .restoreFromTrash(let trashedItemPath, let toOriginalPath):
                let displayedName = Self.displayedName(toOriginalPath)
                guard fileSystem.existingItemKind(atCanonicalPath: trashedItemPath) != nil else {
                    return "\(displayedName) is no longer in the Trash."
                }
                if fileSystem.existingItemKind(atCanonicalPath: toOriginalPath) != nil {
                    return "\(displayedName) stays in the Trash: something else now has its original name."
                }
                try fileSystem.moveItemWithoutReplacing(fromCanonicalPath: trashedItemPath, toCanonicalPath: toOriginalPath)
            case .trashCopy(let copyPath):
                guard let copyKind = fileSystem.existingItemKind(atCanonicalPath: copyPath) else {
                    return "The copy \(Self.displayedName(copyPath)) is no longer there."
                }
                if copyKind == .symbolicLink {
                    return "The copy \(Self.displayedName(copyPath)) was replaced by a symbolic link; Dotto leaves links alone."
                }
                _ = try fileSystem.moveItemToTrash(atCanonicalPath: copyPath)
            case .removeCreatedFolderIfEmpty(let folderPath):
                let displayedName = Self.displayedName(folderPath)
                guard fileSystem.existingItemKind(atCanonicalPath: folderPath) == .folder else {
                    return "The folder \(displayedName) is no longer there."
                }
                do {
                    try fileSystem.removeEmptyFolder(atCanonicalPath: folderPath)
                } catch FileSystemMutationError.notEmpty {
                    return "The folder \(displayedName) stays: it isn't empty."
                }
            case .restoreTags(let path, let tags):
                guard let taggedItemKind = fileSystem.existingItemKind(atCanonicalPath: path) else {
                    return "\(Self.displayedName(path)) is no longer there, so its tags weren't restored."
                }
                if taggedItemKind == .symbolicLink {
                    return "\(Self.displayedName(path)) was replaced by a symbolic link, so its tags weren't restored."
                }
                try fileSystem.setFinderTags(tags, atCanonicalPath: path)
            }
            return nil
        } catch {
            return "\(Self.displayedName(Self.primaryPath(of: undoStep))) couldn't be put back: \(error)."
        }
    }

    private static func pathsCheckedForContainment(of undoStep: FileOperationUndoStep) -> [String] {
        switch undoStep {
        case .moveBack(let fromPath, let toOriginalPath): return [fromPath, toOriginalPath]
        case .restoreFromTrash(_, let toOriginalPath): return [toOriginalPath]
        case .trashCopy(let copyPath): return [copyPath]
        case .removeCreatedFolderIfEmpty(let folderPath): return [folderPath]
        case .restoreTags(let path, _): return [path]
        }
    }

    private func audit(_ undoStep: FileOperationUndoStep, result: String, journalIdentifier: String) {
        auditLogWriter?.append(eventKind: .undo, itemIdentifier: nil, message: result,
                               details: ["journal": journalIdentifier, "step": String(describing: undoStep)])
    }

    private static func primaryPath(of undoStep: FileOperationUndoStep) -> String {
        switch undoStep {
        case .moveBack(_, let toOriginalPath): return toOriginalPath
        case .restoreFromTrash(_, let toOriginalPath): return toOriginalPath
        case .trashCopy(let copyPath): return copyPath
        case .removeCreatedFolderIfEmpty(let folderPath): return folderPath
        case .restoreTags(let path, _): return path
        }
    }

    private static func progressDescription(of undoStep: FileOperationUndoStep) -> String {
        let nameWithoutExtension = (FileOperationPathRules.name(of: primaryPath(of: undoStep)) as NSString).deletingPathExtension
        switch undoStep {
        case .moveBack: return "Putting back \(nameWithoutExtension)"
        case .restoreFromTrash: return "Restoring \(nameWithoutExtension) from the Trash"
        case .trashCopy: return "Moving the copy of \(nameWithoutExtension) to the Trash"
        case .removeCreatedFolderIfEmpty: return "Removing the empty folder “\(FileOperationPathRules.name(of: primaryPath(of: undoStep)))”"
        case .restoreTags: return "Restoring the tags of \(nameWithoutExtension)"
        }
    }

    private static func displayedName(_ path: String) -> String {
        "“\(FileOperationPathRules.name(of: path))”"
    }
}
