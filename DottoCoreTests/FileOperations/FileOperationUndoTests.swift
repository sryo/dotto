import Foundation

private func runThenUndo(_ operations: [PlannedFileOperation], fileSystem: InMemoryFileSystem,
                         betweenRunAndUndo: () -> Void = {}) async throws -> (report: FileOperationUndoReport, journalStore: FileOperationJournalStore) {
    let journalStore = try makeJournalStore()
    let auditLogWriter = try ConversationFixtures.makeAuditLogWriter()
    _ = await FileOperationRunner(fileSystem: fileSystem, journalStore: journalStore, auditLogWriter: auditLogWriter)
        .run(makeFileOperationsPlan(operations), taskIdentifier: "task-1", runControl: nil, abortSignal: TaskAbortSignal(),
             onGroupBoundary: { _ in }, onProgress: { _ in })
    betweenRunAndUndo()
    let undoReport = try await FileOperationUndoRunner(fileSystem: fileSystem, journalStore: journalStore, auditLogWriter: auditLogWriter)
        .undo(journalIdentifier: "task-1", abortSignal: TaskAbortSignal(), onProgress: { _ in })
    return (undoReport, journalStore)
}

private func posixPermissions(ofPath path: String) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

let fileOperationUndoTestSuite = CoreTestSuite(name: "FileOperationUndo", testCases: [
    CoreTestCase(name: "undo steps run in reverse journal order, one kind of step per kind of change") {
        let performedAt = Date(timeIntervalSince1970: 0)
        let entries = [
            FileOperationJournalEntry(operationIdentifier: "op-1", kind: .createFolder, sourcePath: nil, destinationPath: "/s/F",
                                      previousTags: nil, trashedItemPath: nil, performedAt: performedAt),
            FileOperationJournalEntry(operationIdentifier: "op-2", kind: .move, sourcePath: "/s/a", destinationPath: "/s/F/a",
                                      previousTags: nil, trashedItemPath: nil, performedAt: performedAt),
            FileOperationJournalEntry(operationIdentifier: "op-3", kind: .copy, sourcePath: "/s/b", destinationPath: "/s/b 2",
                                      previousTags: nil, trashedItemPath: nil, performedAt: performedAt),
            FileOperationJournalEntry(operationIdentifier: "op-4", kind: .setTags, sourcePath: "/s/c", destinationPath: nil,
                                      previousTags: ["Old"], trashedItemPath: nil, performedAt: performedAt),
            FileOperationJournalEntry(operationIdentifier: "op-5", kind: .moveToTrash, sourcePath: "/s/d", destinationPath: nil,
                                      previousTags: nil, trashedItemPath: "/t/d", performedAt: performedAt),
        ]
        try expectEqual(FileOperationUndoPlanner.undoSteps(for: entries), [
            .restoreFromTrash(trashedItemPath: "/t/d", toOriginalPath: "/s/d"),
            .restoreTags(path: "/s/c", tags: ["Old"]),
            .trashCopy(copyPath: "/s/b 2"),
            .moveBack(fromPath: "/s/F/a", toOriginalPath: "/s/a"),
            .removeCreatedFolderIfEmpty(folderPath: "/s/F"),
        ])
    },
    CoreTestCase(name: "moves, renames, tags and trashing are reverted, the created folder removed and the copy trashed") {
        let fileSystem = makeShotsFileSystem().addFile("/Users/me/Desktop/Shots/tagged.png", tags: ["Blue"])
            .addFile("/Users/me/Desktop/Shots/old.png").addFile("/Users/me/Desktop/Shots/dup.png")
        let (undoReport, journalStore) = try await runThenUndo(sortShotsOperations + [
            makePlannedOperation(.rename, from: "/Users/me/Desktop/Shots/tagged.png", to: "/Users/me/Desktop/Shots/renamed.png"),
            makePlannedOperation(.setTags, from: "/Users/me/Desktop/Shots/renamed.png", tags: ["Red"]),
            makePlannedOperation(.moveToTrash, from: "/Users/me/Desktop/Shots/old.png"),
            makePlannedOperation(.copy, from: "/Users/me/Desktop/Shots/dup.png", to: "/Users/me/Desktop/Shots/dup copy.png"),
        ], fileSystem: fileSystem)
        try expectEqual(undoReport, FileOperationUndoReport(revertedCount: 7, skippedCount: 0, skippedReasons: []))
        try expectEqual(fileSystem.allPaths(under: directRouteTestScopeRootPath), [
            "/Users/me/Desktop/Shots", "/Users/me/Desktop/Shots/IMG_1.png", "/Users/me/Desktop/Shots/IMG_2.png",
            "/Users/me/Desktop/Shots/dup.png", "/Users/me/Desktop/Shots/old.png", "/Users/me/Desktop/Shots/tagged.png",
        ])
        try expectEqual(fileSystem.node(atPath: "/Users/me/Desktop/Shots/tagged.png")?.tags, ["Blue"])
        try expectEqual(fileSystem.allPaths(under: fileSystem.trashFolderPath), [fileSystem.trashFolderPath, fileSystem.trashFolderPath + "/dup copy.png"])
        try expectEqual(try journalStore.loadJournal("task-1").status, .undone)
        try expectTrue(!fileSystem.performedMutations.contains { $0.hasPrefix("delete") })
    },
    CoreTestCase(name: "a folder that isn't empty stays, and an occupied original name is never overwritten") {
        let fileSystem = makeShotsFileSystem()
        let (undoReport, journalStore) = try await runThenUndo(sortShotsOperations, fileSystem: fileSystem) {
            fileSystem.addFile("/Users/me/Desktop/Shots/2026-09/added later.png")
            fileSystem.addFile("/Users/me/Desktop/Shots/IMG_1.png", contents: "a new file with the old name")
        }
        try expectEqual(undoReport.revertedCount, 1)
        try expectEqual(undoReport.skippedCount, 2)
        try expectEqual(fileSystem.node(atPath: "/Users/me/Desktop/Shots/IMG_1.png")?.contents, "a new file with the old name")
        try expectEqual(fileSystem.node(atPath: "/Users/me/Desktop/Shots/2026-09/IMG_1.png")?.contents, "one")
        try expectEqual(fileSystem.node(atPath: "/Users/me/Desktop/Shots/IMG_2.png")?.contents, "two")
        try expectTrue(undoReport.skippedReasons.contains { $0.contains("original name") }, "\(undoReport.skippedReasons)")
        try expectTrue(undoReport.skippedReasons.contains { $0.contains("isn't empty") }, "\(undoReport.skippedReasons)")
        try expectEqual(try journalStore.loadJournal("task-1").status, .partiallyUndone)
    },
    CoreTestCase(name: "an undo stopped partway journals what it reverted and carries on later with only the rest") {
        let fileSystem = makeShotsFileSystem()
        let journalStore = try makeJournalStore()
        _ = await FileOperationRunner(fileSystem: fileSystem, journalStore: journalStore, auditLogWriter: try ConversationFixtures.makeAuditLogWriter())
            .run(makeFileOperationsPlan(sortShotsOperations), taskIdentifier: "task-1", runControl: nil, abortSignal: TaskAbortSignal(),
                 onGroupBoundary: { _ in }, onProgress: { _ in })
        let undoAbortSignal = TaskAbortSignal()
        fileSystem.beforeEachMutation = { undoAbortSignal.abort() }
        let stoppedReport = try await FileOperationUndoRunner(fileSystem: fileSystem, journalStore: journalStore, auditLogWriter: nil)
            .undo(journalIdentifier: "task-1", abortSignal: undoAbortSignal, onProgress: { _ in })
        fileSystem.beforeEachMutation = nil
        try expectEqual(stoppedReport.revertedCount, 1, "the step under way finishes; Stop is honored before the next one")
        let stoppedJournal = try journalStore.loadJournal("task-1")
        try expectEqual(stoppedJournal.status, .partiallyUndone)
        try expectEqual(stoppedJournal.revertedOperationIdentifiers, ["op-3"])
        try expectEqual(journalStore.mostRecentUndoableJournalIdentifier(), "task-1", "the menu bar keeps offering the rest")

        let resumedReport = try await FileOperationUndoRunner(fileSystem: fileSystem, journalStore: journalStore, auditLogWriter: nil)
            .undo(journalIdentifier: "task-1", abortSignal: TaskAbortSignal(), onProgress: { _ in })
        try expectEqual(resumedReport, FileOperationUndoReport(revertedCount: 2, skippedCount: 0, skippedReasons: []))
        try expectEqual(try journalStore.loadJournal("task-1").status, .undone)
        try expectEqual(journalStore.mostRecentUndoableJournalIdentifier(), nil)
        try expectEqual(fileSystem.allPaths(under: directRouteTestScopeRootPath), [
            "/Users/me/Desktop/Shots", "/Users/me/Desktop/Shots/IMG_1.png", "/Users/me/Desktop/Shots/IMG_2.png",
        ])
    },
    CoreTestCase(name: "a created folder holding only Finder's .DS_Store and Icon files is still removed; anything else keeps it") {
        let fileSystem = makeShotsFileSystem()
        let (undoReport, _) = try await runThenUndo(sortShotsOperations + [
            makePlannedOperation(.createFolder, to: "/Users/me/Desktop/Shots/Other"),
        ], fileSystem: fileSystem) {
            fileSystem.addFile("/Users/me/Desktop/Shots/2026-09/.DS_Store")
            fileSystem.addFile("/Users/me/Desktop/Shots/2026-09/Icon\r")
            fileSystem.addFile("/Users/me/Desktop/Shots/Other/.DS_Store")
            fileSystem.addFile("/Users/me/Desktop/Shots/Other/notes.txt")
        }
        try expectEqual(undoReport.revertedCount, 3)
        try expectEqual(undoReport.skippedCount, 1)
        try expectTrue(fileSystem.node(atPath: "/Users/me/Desktop/Shots/2026-09") == nil)
        try expectEqual(fileSystem.node(atPath: "/Users/me/Desktop/Shots/Other/notes.txt")?.kind, .regularFile)
    },
    CoreTestCase(name: "a journal can't be undone twice") {
        let fileSystem = makeShotsFileSystem()
        let (_, journalStore) = try await runThenUndo(sortShotsOperations, fileSystem: fileSystem)
        do {
            _ = try await FileOperationUndoRunner(fileSystem: fileSystem, journalStore: journalStore, auditLogWriter: nil)
                .undo(journalIdentifier: "task-1", abortSignal: TaskAbortSignal(), onProgress: { _ in })
            throw CoreTestFailure(description: "expected the second undo to be refused")
        } catch let undoError as FileOperationUndoError {
            try expectEqual(undoError, .journalNotUndoable(.undone))
        }
    },
    CoreTestCase(name: "a journal left running by another process reads as interrupted and can be undone") {
        let journalsDirectoryURL = makeScratchDirectoryURL(prefix: "journals")
        let crashedStore = try FileOperationJournalStore(journalsDirectoryURL: journalsDirectoryURL)
        try crashedStore.beginJournal(FileOperationJournalHeader(journalIdentifier: "task-crashed", taskTitle: "Sort",
                                                                 scope: directRouteTestScope, startedAt: Date()))
        try crashedStore.append(FileOperationJournalEntry(operationIdentifier: "op-1", kind: .createFolder, sourcePath: nil,
                                                          destinationPath: "/Users/me/Desktop/Shots/New", previousTags: nil,
                                                          trashedItemPath: nil, performedAt: Date()), toJournal: "task-crashed")
        try expectEqual(try crashedStore.loadJournal("task-crashed").status, .running)
        try expectEqual(crashedStore.mostRecentUndoableJournalIdentifier(), nil)

        let relaunchedStore = try FileOperationJournalStore(journalsDirectoryURL: journalsDirectoryURL)
        try expectEqual(try relaunchedStore.loadJournal("task-crashed").status, .interrupted)
        try expectEqual(relaunchedStore.mostRecentUndoableJournalIdentifier(), "task-crashed")
        let fileSystem = makeShotsFileSystem().addFolder("/Users/me/Desktop/Shots/New")
        let undoReport = try await FileOperationUndoRunner(fileSystem: fileSystem, journalStore: relaunchedStore, auditLogWriter: nil)
            .undo(journalIdentifier: "task-crashed", abortSignal: TaskAbortSignal(), onProgress: { _ in })
        try expectEqual(undoReport.revertedCount, 1)
        try expectTrue(fileSystem.node(atPath: "/Users/me/Desktop/Shots/New") == nil)
    },
    CoreTestCase(name: "pruning keeps the newest 20 journals and anything younger than 7 days") {
        let journalStore = try makeJournalStore()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        for journalNumber in 1...25 {
            // Journals 1…22 are 8+ days old (oldest first); 23…25 are from today.
            let startedAt = journalNumber <= 22 ? now.addingTimeInterval(-Double(30 - journalNumber) * 86_400) : now.addingTimeInterval(-60)
            let journalIdentifier = "task-\(journalNumber)"
            try journalStore.beginJournal(FileOperationJournalHeader(journalIdentifier: journalIdentifier, taskTitle: "t",
                                                                     scope: directRouteTestScope, startedAt: startedAt))
            try journalStore.markStatus(.finished, ofJournal: journalIdentifier)
        }
        try journalStore.pruneOldJournals(now: now)
        let remainingJournalFileNames = try FileManager.default.contentsOfDirectory(atPath: journalStore.journalsDirectoryURL.path)
        try expectEqual(remainingJournalFileNames.count, 20)
        try expectTrue(!remainingJournalFileNames.contains("task-1.jsonl") && remainingJournalFileNames.contains("task-25.jsonl"),
                       "\(remainingJournalFileNames.sorted())")
    },
    CoreTestCase(name: "journal files are 0600 in a 0700 folder, and identifiers can't leave the folder") {
        let journalStore = try makeJournalStore()
        try journalStore.beginJournal(FileOperationJournalHeader(journalIdentifier: "task-modes", taskTitle: "t",
                                                                 scope: directRouteTestScope, startedAt: Date()))
        try expectEqual(try posixPermissions(ofPath: journalStore.journalsDirectoryURL.path), 0o700)
        try expectEqual(try posixPermissions(ofPath: journalStore.journalsDirectoryURL.appendingPathComponent("task-modes.jsonl").path), 0o600)
        let escapingError = try expectThrowsError {
            try journalStore.beginJournal(FileOperationJournalHeader(journalIdentifier: "../escape", taskTitle: "t",
                                                                     scope: directRouteTestScope, startedAt: Date()))
        }
        try expectEqual(escapingError as? FileOperationJournalStoreError, .invalidJournalIdentifier)
    },
])
