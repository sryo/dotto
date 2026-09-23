import Foundation

struct FileOperationProgress: Equatable, Sendable {
    /// Operations finished (completed, failed or skipped) before the one being described.
    var completedCount: Int
    var totalCount: Int
    /// "Moving IMG_2041", "Creating “2026-09 Septiembre”", "Renaming …", "Copying …", "Tagging …", "Moving … to the Trash"
    var currentOperationDescription: String
    var groupIdentifier: String
}

enum FileOperationGroupEvent: Equatable, Sendable {
    case started(groupIdentifier: String)
    case finished(groupIdentifier: String, completed: Int, failed: Int, skipped: Int, summary: String)
}

/// Runs a validated file-operations plan, one operation at a time: checkpoint, dependency check, pre-check against
/// the live file system (including `FileOperationContainmentCheck` on every operand's real folder), the change itself
/// (never replacing anything), a journal line flushed to disk, verification by re-reading, and an audit entry with
/// paths only.
final class FileOperationRunner {
    static let maximumReportedFailureCount = 50
    static let minimumSecondsBetweenProgressEvents: TimeInterval = 0.05

    private let fileSystem: FileSystemMutating
    private let journalStore: FileOperationJournalStore
    private let auditLogWriter: AuditLogWriter
    private let maximumConsecutiveFailures: Int
    private let homeDirectoryPath: String
    private let currentDate: () -> Date

    init(fileSystem: FileSystemMutating, journalStore: FileOperationJournalStore, auditLogWriter: AuditLogWriter,
         maximumConsecutiveFailures: Int = 5, homeDirectoryPath: String = NSHomeDirectory(),
         currentDate: @escaping () -> Date = Date.init) {
        self.fileSystem = fileSystem
        self.journalStore = journalStore
        self.auditLogWriter = auditLogWriter
        self.maximumConsecutiveFailures = maximumConsecutiveFailures
        self.homeDirectoryPath = homeDirectoryPath
        self.currentDate = currentDate
    }

    private enum OperationOutcome: Equatable {
        case completed
        /// Nothing needed changing (the folder to create already exists); counts as completed, with no journal line.
        case alreadyDone
        case failed(String)
        case skipped
    }

    private struct GroupTally {
        var completed = 0
        var failed = 0
        var skipped = 0
        var firstFailureReason: String?
        var operationKinds: Set<FileOperationKind> = []
    }

    func run(_ plan: FileOperationsPlan, taskIdentifier: String, taskTitle: String = "", runControl: TaskRunControl?,
             abortSignal: TaskAbortSignal,
             onGroupBoundary: @escaping (FileOperationGroupEvent) async -> Void,
             onProgress: @escaping (FileOperationProgress) async -> Void) async -> DirectRouteRunReport {
        let runStartDate = currentDate()
        let operations = plan.operations
        let lastOperationIndexByGroupIdentifier = Dictionary(
            operations.enumerated().map { ($0.element.groupIdentifier, $0.offset) }, uniquingKeysWith: { _, laterIndex in laterIndex })
        var groupTallies: [String: GroupTally] = [:]
        var startedGroupIdentifiers: Set<String> = []
        var failures: [FileOperationFailure] = []
        var journaledEntryCount = 0
        var consecutiveFailureCount = 0
        /// Collision keys of paths that a failed or skipped operation should have produced: anything under them is skipped.
        var unavailablePathKeys: Set<String> = []
        /// A destination suffixed at run time, keyed by the planned path's collision key, so later operations follow it.
        var actualPathByPlannedPathKey: [String: String] = [:]
        var lastProgressEventDate: Date?
        /// Groups the user skipped from the pill or the panel: their remaining operations, and anything that needed them, are skipped.
        var groupsSkippedByUser: Set<String> = []
        /// Set once the run must not change anything more; every remaining operation is skipped with this reason.
        var remainingOperationsSkipReason: String?

        do {
            try journalStore.beginJournal(FileOperationJournalHeader(journalIdentifier: taskIdentifier, taskTitle: taskTitle,
                                                                     scope: plan.scope, startedAt: runStartDate))
        } catch {
            auditLogWriter.append(eventKind: .error, itemIdentifier: nil, message: "Undo journal could not be created",
                                  details: ["error": String(describing: error)])
            remainingOperationsSkipReason = "Dotto couldn't create its undo record, so it changed nothing."
        }

        for (operationIndex, plannedOperation) in operations.enumerated() {
            let groupIdentifier = plannedOperation.groupIdentifier
            let isFirstOperationOfGroup = !startedGroupIdentifiers.contains(groupIdentifier)
                && groupTallies[groupIdentifier] == nil
            var outcome: OperationOutcome = .skipped
            var performedOperation = plannedOperation

            if remainingOperationsSkipReason == nil, let runControl {
                do {
                    let checkpointOutcome = isFirstOperationOfGroup
                        ? try await runControl.checkpointBetweenItems(abortSignal: abortSignal)
                        : try await runControl.checkpoint(abortSignal: abortSignal)
                    if checkpointOutcome == .skipCurrentItem { groupsSkippedByUser.insert(groupIdentifier) }
                } catch {
                    remainingOperationsSkipReason = TaskUserFacingMessages.itemStoppedByUserSummary
                }
            }
            if remainingOperationsSkipReason == nil && abortSignal.isAborted {
                remainingOperationsSkipReason = TaskUserFacingMessages.itemStoppedByUserSummary
            }

            let sourcePath = plannedOperation.sourcePath.map { remappedPath($0, actualPathByPlannedPathKey: actualPathByPlannedPathKey) }
            let destinationPath = plannedOperation.destinationPath.map { remappedPath($0, actualPathByPlannedPathKey: actualPathByPlannedPathKey) }
            performedOperation.sourcePath = sourcePath
            performedOperation.destinationPath = destinationPath

            let isSkippedByUser = groupsSkippedByUser.contains(groupIdentifier)
            let dependsOnUnavailablePath = [sourcePath, destinationPath.map(FileOperationPathRules.parentPath(of:))]
                .compactMap { $0 }
                .contains { isPath($0, equalToOrInsideAnyOf: unavailablePathKeys) }

            if remainingOperationsSkipReason == nil && !isSkippedByUser && !dependsOnUnavailablePath {
                if !startedGroupIdentifiers.contains(groupIdentifier) {
                    startedGroupIdentifiers.insert(groupIdentifier)
                    await onGroupBoundary(.started(groupIdentifier: groupIdentifier))
                }
                let progressEventDate = currentDate()
                if lastProgressEventDate.map({ progressEventDate.timeIntervalSince($0) >= Self.minimumSecondsBetweenProgressEvents }) ?? true {
                    lastProgressEventDate = progressEventDate
                    await onProgress(FileOperationProgress(completedCount: operationIndex, totalCount: operations.count,
                                                           currentOperationDescription: Self.progressDescription(of: plannedOperation),
                                                           groupIdentifier: groupIdentifier))
                }
                let (operationOutcome, journalEntry) = perform(&performedOperation, scope: plan.scope, abortSignal: abortSignal)
                outcome = operationOutcome
                if let journalEntry {
                    do {
                        try journalStore.append(journalEntry, toJournal: taskIdentifier)
                        journaledEntryCount += 1
                    } catch {
                        auditLogWriter.append(eventKind: .error, itemIdentifier: nil, message: "Undo journal write failed",
                                              details: ["op_id": plannedOperation.operationIdentifier, "error": String(describing: error)])
                        remainingOperationsSkipReason = "Dotto couldn't write its undo record, so it stopped."
                    }
                }
                if case .completed = outcome, let journalEntry {
                    outcome = verify(journalEntry, requestedTags: plannedOperation.tags)
                }
                if let plannedDestinationPath = plannedOperation.destinationPath, let actualDestinationPath = performedOperation.destinationPath,
                   actualDestinationPath != plannedDestinationPath {
                    actualPathByPlannedPathKey[FileOperationPathRules.collisionKey(forPath: plannedDestinationPath)] = actualDestinationPath
                }
            }

            switch outcome {
            case .completed, .alreadyDone:
                consecutiveFailureCount = 0
                groupTallies[groupIdentifier, default: GroupTally()].completed += 1
            case .failed(let userFacingReason):
                consecutiveFailureCount += 1
                groupTallies[groupIdentifier, default: GroupTally()].failed += 1
                if groupTallies[groupIdentifier]?.firstFailureReason == nil {
                    groupTallies[groupIdentifier]?.firstFailureReason = userFacingReason
                }
                if failures.count < Self.maximumReportedFailureCount {
                    failures.append(FileOperationFailure(operationIdentifier: plannedOperation.operationIdentifier,
                                                         userFacingReason: userFacingReason))
                }
                markUnavailable(performedOperation, unavailablePathKeys: &unavailablePathKeys)
            case .skipped:
                groupTallies[groupIdentifier, default: GroupTally()].skipped += 1
                markUnavailable(performedOperation, unavailablePathKeys: &unavailablePathKeys)
            }
            groupTallies[groupIdentifier, default: GroupTally()].operationKinds.insert(plannedOperation.kind)
            auditOperation(performedOperation, outcome: outcome, remainingOperationsSkipReason: remainingOperationsSkipReason)

            if consecutiveFailureCount >= maximumConsecutiveFailures && remainingOperationsSkipReason == nil {
                remainingOperationsSkipReason = "Stopped after \(maximumConsecutiveFailures) failures in a row (Dotto may not have permission for this folder)."
                auditLogWriter.append(eventKind: .error, itemIdentifier: nil, message: remainingOperationsSkipReason ?? "", details: [:])
            }

            if lastOperationIndexByGroupIdentifier[groupIdentifier] == operationIndex {
                let groupTally = groupTallies[groupIdentifier] ?? GroupTally()
                await onGroupBoundary(.finished(groupIdentifier: groupIdentifier, completed: groupTally.completed,
                                                failed: groupTally.failed, skipped: groupTally.skipped,
                                                summary: Self.groupSummary(groupTally, skipReason: remainingOperationsSkipReason)))
            }
        }

        if let lastOperation = operations.last {
            await onProgress(FileOperationProgress(completedCount: operations.count, totalCount: operations.count,
                                                   currentOperationDescription: Self.progressDescription(of: lastOperation),
                                                   groupIdentifier: lastOperation.groupIdentifier))
        }
        try? journalStore.markStatus(.finished, ofJournal: taskIdentifier)

        let allTallies = groupTallies.values
        return DirectRouteRunReport(
            completedOperationCount: allTallies.reduce(0) { $0 + $1.completed },
            failedOperationCount: allTallies.reduce(0) { $0 + $1.failed },
            skippedOperationCount: allTallies.reduce(0) { $0 + $1.skipped },
            failures: failures,
            undoJournalIdentifier: journaledEntryCount > 0 ? taskIdentifier : nil,
            outputText: nil,
            durationSeconds: currentDate().timeIntervalSince(runStartDate))
    }

    // MARK: - Dependencies

    private func markUnavailable(_ operation: PlannedFileOperation, unavailablePathKeys: inout Set<String>) {
        switch operation.kind {
        case .createFolder, .move, .rename, .copy:
            if let destinationPath = operation.destinationPath {
                unavailablePathKeys.insert(FileOperationPathRules.collisionKey(forPath: destinationPath))
            }
        case .setTags, .moveToTrash:
            break
        }
    }

    private func isPath(_ path: String, equalToOrInsideAnyOf pathKeys: Set<String>) -> Bool {
        guard !pathKeys.isEmpty else { return false }
        var candidatePath = path
        while !candidatePath.isEmpty && candidatePath != "/" {
            if pathKeys.contains(FileOperationPathRules.collisionKey(forPath: candidatePath)) { return true }
            candidatePath = FileOperationPathRules.parentPath(of: candidatePath)
        }
        return false
    }

    /// Follows run-time suffixing: "/a/Shots/x.png" becomes "/a/Shots 2/x.png" when "Shots" was created as "Shots 2".
    private func remappedPath(_ plannedPath: String, actualPathByPlannedPathKey: [String: String]) -> String {
        guard !actualPathByPlannedPathKey.isEmpty else { return plannedPath }
        var ancestorPath = plannedPath
        var componentsBelowAncestor: [String] = []
        while !ancestorPath.isEmpty && ancestorPath != "/" {
            if let actualAncestorPath = actualPathByPlannedPathKey[FileOperationPathRules.collisionKey(forPath: ancestorPath)] {
                return ([actualAncestorPath] + componentsBelowAncestor).joined(separator: "/")
            }
            componentsBelowAncestor.insert(FileOperationPathRules.name(of: ancestorPath), at: 0)
            ancestorPath = FileOperationPathRules.parentPath(of: ancestorPath)
        }
        return plannedPath
    }

    // MARK: - One operation

    /// Pre-checks, performs and returns the outcome plus the journal entry to record (only after a change happened).
    /// A destination taken since planning gets the next free suffix, written back into `operation`.
    private func perform(_ operation: inout PlannedFileOperation, scope: DirectRouteScope, abortSignal: TaskAbortSignal)
        -> (OperationOutcome, FileOperationJournalEntry?) {
        let sourceName = operation.sourcePath.map { "“\(FileOperationPathRules.name(of: $0))”" } ?? ""
        // Every operand's real folder is checked right before the change (the dry run only saw paths as text); every
        // suffixed destination shares the requested one's folder, so checking that one covers them all.
        for operandPath in [operation.sourcePath, operation.destinationPath].compactMap({ $0 }) {
            if let containmentProblem = FileOperationContainmentCheck.problem(operandPath: operandPath, fileSystem: fileSystem,
                                                                             scope: scope, homeDirectoryPath: homeDirectoryPath) {
                return (.failed(containmentProblem), nil)
            }
        }
        var sourceKind: ExistingFileSystemItemKind?
        if let sourcePath = operation.sourcePath {
            guard let existingSourceKind = fileSystem.existingItemKind(atCanonicalPath: sourcePath), existingSourceKind != .other else {
                return (.failed("\(sourceName) is no longer there."), nil)
            }
            if existingSourceKind == .symbolicLink {
                return (.failed("\(sourceName) is now a symbolic link; Dotto leaves links alone."), nil)
            }
            sourceKind = existingSourceKind
        }
        do {
            switch operation.kind {
            case .createFolder:
                guard let destinationPath = operation.destinationPath else { return (.failed("The plan is missing a folder path."), nil) }
                let folderName = "“\(FileOperationPathRules.name(of: destinationPath))”"
                if let existingKind = fileSystem.existingItemKind(atCanonicalPath: destinationPath) {
                    return existingKind == .folder ? (.alreadyDone, nil) : (.failed("\(folderName) already exists and isn't a folder."), nil)
                }
                try fileSystem.createFolder(atCanonicalPath: destinationPath)
                return (.completed, journalEntry(for: operation))

            case .move, .rename, .copy:
                guard let sourcePath = operation.sourcePath, let requestedDestinationPath = operation.destinationPath else {
                    return (.failed("The plan is missing a path."), nil)
                }
                let isCaseOnlyRename = operation.kind != .copy
                    && FileOperationPathRules.collisionKey(forPath: sourcePath) == FileOperationPathRules.collisionKey(forPath: requestedDestinationPath)
                for attempt in 1...FileOperationPathRules.maximumSuffixAttempt {
                    let candidateDestinationPath = attempt == 1 ? requestedDestinationPath
                        : FileOperationPathRules.suffixedPath(requestedDestinationPath, attempt: attempt, isPlainFolder: sourceKind == .folder)
                    if !isCaseOnlyRename && fileSystem.existingItemKind(atCanonicalPath: candidateDestinationPath) != nil { continue }
                    do {
                        if operation.kind == .copy {
                            try fileSystem.copyItemWithoutReplacing(fromCanonicalPath: sourcePath, toCanonicalPath: candidateDestinationPath,
                                                                    abortSignal: abortSignal)
                        } else {
                            try fileSystem.moveItemWithoutReplacing(fromCanonicalPath: sourcePath, toCanonicalPath: candidateDestinationPath)
                        }
                    } catch FileSystemMutationError.destinationExists where !isCaseOnlyRename {
                        // Taken between the check and the change: try the next name.
                        continue
                    }
                    operation.destinationPath = candidateDestinationPath
                    return (.completed, journalEntry(for: operation))
                }
                return (.failed("Every name for \(sourceName) up to “… \(FileOperationPathRules.maximumSuffixAttempt)” is taken."), nil)

            case .setTags:
                guard let sourcePath = operation.sourcePath else { return (.failed("The plan is missing a path."), nil) }
                let previousTags = try fileSystem.finderTags(atCanonicalPath: sourcePath)
                try fileSystem.setFinderTags(operation.tags ?? [], atCanonicalPath: sourcePath)
                var entry = journalEntry(for: operation)
                entry.previousTags = previousTags
                return (.completed, entry)

            case .moveToTrash:
                guard let sourcePath = operation.sourcePath else { return (.failed("The plan is missing a path."), nil) }
                let trashedItemPath = try fileSystem.moveItemToTrash(atCanonicalPath: sourcePath)
                var entry = journalEntry(for: operation)
                entry.trashedItemPath = trashedItemPath
                return (.completed, entry)
            }
        } catch let mutationError as FileSystemMutationError {
            if mutationError == .stopped { return (.skipped, nil) }
            return (.failed(Self.userFacingReason(for: mutationError, operation: operation)), nil)
        } catch {
            return (.failed("\(sourceName.isEmpty ? "The change" : sourceName) failed: \(error.localizedDescription)"), nil)
        }
    }

    private func journalEntry(for operation: PlannedFileOperation) -> FileOperationJournalEntry {
        FileOperationJournalEntry(operationIdentifier: operation.operationIdentifier, kind: operation.kind,
                                  sourcePath: operation.sourcePath, destinationPath: operation.destinationPath,
                                  previousTags: nil, trashedItemPath: nil, performedAt: currentDate())
    }

    /// Re-reads what the change should have left. A failed check marks the operation failed but keeps its journal
    /// line, so undo still reverses whatever did happen.
    private func verify(_ entry: FileOperationJournalEntry, requestedTags: [String]?) -> OperationOutcome {
        let displayedName = "“\(FileOperationPathRules.name(of: entry.sourcePath ?? entry.destinationPath ?? ""))”"
        let verificationFailure = OperationOutcome.failed("\(displayedName) didn't end up where Dotto expected; check it in Finder.")
        switch entry.kind {
        case .createFolder:
            guard let destinationPath = entry.destinationPath,
                  fileSystem.existingItemKind(atCanonicalPath: destinationPath) == .folder else { return verificationFailure }
        case .move, .rename:
            guard let sourcePath = entry.sourcePath, let destinationPath = entry.destinationPath,
                  fileSystem.existingItemKind(atCanonicalPath: destinationPath) != nil else { return verificationFailure }
            let isCaseOnlyRename = FileOperationPathRules.collisionKey(forPath: sourcePath) == FileOperationPathRules.collisionKey(forPath: destinationPath)
            if !isCaseOnlyRename && fileSystem.existingItemKind(atCanonicalPath: sourcePath) != nil { return verificationFailure }
        case .copy:
            guard let destinationPath = entry.destinationPath,
                  fileSystem.existingItemKind(atCanonicalPath: destinationPath) != nil else { return verificationFailure }
        case .setTags:
            guard let sourcePath = entry.sourcePath,
                  let currentTags = try? fileSystem.finderTags(atCanonicalPath: sourcePath),
                  Set(currentTags) == Set(requestedTags ?? []) else { return verificationFailure }
        case .moveToTrash:
            guard let sourcePath = entry.sourcePath, let trashedItemPath = entry.trashedItemPath,
                  fileSystem.existingItemKind(atCanonicalPath: sourcePath) == nil,
                  fileSystem.existingItemKind(atCanonicalPath: trashedItemPath) != nil else { return verificationFailure }
        }
        return .completed
    }

    // MARK: - Wording and audit

    private func auditOperation(_ operation: PlannedFileOperation, outcome: OperationOutcome, remainingOperationsSkipReason: String?) {
        let resultText: String
        switch outcome {
        case .completed: resultText = "completed"
        case .alreadyDone: resultText = "already_done"
        case .failed(let userFacingReason): resultText = "failed: \(userFacingReason)"
        case .skipped: resultText = "skipped" + (remainingOperationsSkipReason.map { ": \($0)" } ?? "")
        }
        var auditDetails = ["op_id": operation.operationIdentifier, "kind": operation.kind.rawValue, "result": resultText]
        if let sourcePath = operation.sourcePath { auditDetails["from"] = sourcePath }
        if let destinationPath = operation.destinationPath { auditDetails["to"] = destinationPath }
        auditLogWriter.append(eventKind: .fileOperation, itemIdentifier: nil, message: operation.kind.rawValue, details: auditDetails)
    }

    static func progressDescription(of operation: PlannedFileOperation) -> String {
        let operandPath = operation.sourcePath ?? operation.destinationPath ?? ""
        let nameWithoutExtension = (FileOperationPathRules.name(of: operandPath) as NSString).deletingPathExtension
        switch operation.kind {
        case .createFolder: return "Creating “\(FileOperationPathRules.name(of: operandPath))”"
        case .move: return "Moving \(nameWithoutExtension)"
        case .rename: return "Renaming \(nameWithoutExtension)"
        case .copy: return "Copying \(nameWithoutExtension)"
        case .setTags: return "Tagging \(nameWithoutExtension)"
        case .moveToTrash: return "Moving \(nameWithoutExtension) to the Trash"
        }
    }

    private static func userFacingReason(for mutationError: FileSystemMutationError, operation: PlannedFileOperation) -> String {
        let displayedName = "“\(FileOperationPathRules.name(of: operation.sourcePath ?? operation.destinationPath ?? ""))”"
        switch mutationError {
        case .destinationExists: return "\(displayedName): something with that name is already there."
        case .sourceMissing: return "\(displayedName) is no longer there."
        case .permissionDenied: return "\(displayedName): Dotto doesn't have permission to change it."
        case .notEmpty: return "\(displayedName) isn't empty."
        case .crossVolume: return "\(displayedName) is on another disk; Dotto only moves files within one disk."
        case .stopped: return TaskUserFacingMessages.itemStoppedByUserSummary
        case .other(let detail): return "\(displayedName) couldn't be changed: \(detail)"
        }
    }

    /// "23 moved", "21 of 23 moved; 2 failed: “IMG_2041.png” is locked…", "12 moved; 11 skipped".
    private static func groupSummary(_ groupTally: GroupTally, skipReason: String?) -> String {
        let totalCount = groupTally.completed + groupTally.failed + groupTally.skipped
        let verb = groupTally.operationKinds.count == 1 ? pastTenseVerb(for: groupTally.operationKinds.first ?? .move) : "done"
        if groupTally.failed == 0 && groupTally.skipped == 0 {
            return "\(groupTally.completed) \(verb)"
        }
        if groupTally.completed == 0 && groupTally.failed == 0 {
            return skipReason ?? "Skipped."
        }
        var summary = groupTally.failed > 0 ? "\(groupTally.completed) of \(totalCount) \(verb)" : "\(groupTally.completed) \(verb)"
        if groupTally.failed > 0 {
            summary += "; \(groupTally.failed) failed"
            if let firstFailureReason = groupTally.firstFailureReason { summary += ": \(firstFailureReason)" }
        }
        if groupTally.skipped > 0 { summary += "; \(groupTally.skipped) skipped" }
        return summary
    }

    private static func pastTenseVerb(for operationKind: FileOperationKind) -> String {
        switch operationKind {
        case .createFolder: return "created"
        case .move: return "moved"
        case .rename: return "renamed"
        case .copy: return "copied"
        case .setTags: return "tagged"
        case .moveToTrash: return "moved to the Trash"
        }
    }
}
