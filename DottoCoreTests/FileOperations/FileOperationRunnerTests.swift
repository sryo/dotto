import Foundation

/// Collects what the runner reports through its callbacks.
final class FileOperationRunRecorder: @unchecked Sendable {
    private let recorderLock = NSLock()
    private var recordedGroupEvents: [FileOperationGroupEvent] = []
    private var recordedProgressEvents: [FileOperationProgress] = []

    var groupEvents: [FileOperationGroupEvent] { recorderLock.withLock { recordedGroupEvents } }
    var progressEvents: [FileOperationProgress] { recorderLock.withLock { recordedProgressEvents } }

    func record(_ groupEvent: FileOperationGroupEvent) { recorderLock.withLock { recordedGroupEvents.append(groupEvent) } }
    func record(_ progress: FileOperationProgress) { recorderLock.withLock { recordedProgressEvents.append(progress) } }
}

func makeJournalStore() throws -> FileOperationJournalStore {
    try FileOperationJournalStore(journalsDirectoryURL: makeScratchDirectoryURL(prefix: "journals"))
}

/// Numbers the operations the way the validator does, without validating them.
func makeFileOperationsPlan(_ operations: [PlannedFileOperation], groups: [FileOperationGroup]? = nil) -> FileOperationsPlan {
    let numberedOperations = operations.enumerated().map { operationOffset, operation in
        var numberedOperation = operation
        numberedOperation.operationIdentifier = "op-\(operationOffset + 1)"
        return numberedOperation
    }
    let groupIdentifiers = numberedOperations.map(\.groupIdentifier).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    return FileOperationsPlan(scope: directRouteTestScope,
                              groups: groups ?? groupIdentifiers.map { FileOperationGroup(groupIdentifier: $0, title: "Group \($0)") },
                              operations: numberedOperations, collisionAdjustments: [])
}

private func runPlan(_ plan: FileOperationsPlan, fileSystem: InMemoryFileSystem, journalStore: FileOperationJournalStore,
                     auditLogWriter: AuditLogWriter, runControl: TaskRunControl? = nil, abortSignal: TaskAbortSignal = TaskAbortSignal(),
                     recorder: FileOperationRunRecorder = FileOperationRunRecorder(), taskIdentifier: String = "task-1") async -> DirectRouteRunReport {
    let fileOperationRunner = FileOperationRunner(fileSystem: fileSystem, journalStore: journalStore, auditLogWriter: auditLogWriter)
    return await fileOperationRunner.run(plan, taskIdentifier: taskIdentifier, taskTitle: "Sort shots", runControl: runControl,
                                         abortSignal: abortSignal,
                                         onGroupBoundary: { recorder.record($0) }, onProgress: { recorder.record($0) })
}

let sortShotsOperations = [
    makePlannedOperation(.createFolder, to: "/Users/me/Desktop/Shots/2026-09", group: "folders"),
    makePlannedOperation(.move, from: "/Users/me/Desktop/Shots/IMG_1.png", to: "/Users/me/Desktop/Shots/2026-09/IMG_1.png", group: "moves"),
    makePlannedOperation(.move, from: "/Users/me/Desktop/Shots/IMG_2.png", to: "/Users/me/Desktop/Shots/2026-09/IMG_2.png", group: "moves"),
]

let fileOperationRunnerTestSuite = CoreTestSuite(name: "FileOperationRunner", testCases: [
    CoreTestCase(name: "the happy path journals every change in order and reports each group once") {
        let fileSystem = makeShotsFileSystem()
        let journalStore = try makeJournalStore()
        let recorder = FileOperationRunRecorder()
        let report = await runPlan(makeFileOperationsPlan(sortShotsOperations), fileSystem: fileSystem, journalStore: journalStore,
                                   auditLogWriter: try ConversationFixtures.makeAuditLogWriter(), recorder: recorder)
        try expectEqual(report.completedOperationCount, 3)
        try expectEqual(report.failedOperationCount, 0)
        try expectEqual(report.undoJournalIdentifier, "task-1")
        try expectEqual(fileSystem.node(atPath: "/Users/me/Desktop/Shots/2026-09/IMG_1.png")?.contents, "one")
        let loadedJournal = try journalStore.loadJournal("task-1")
        try expectEqual(loadedJournal.entries.map(\.operationIdentifier), ["op-1", "op-2", "op-3"])
        try expectEqual(loadedJournal.status, .finished)
        try expectEqual(loadedJournal.header.taskTitle, "Sort shots")
        try expectEqual(recorder.groupEvents, [
            .started(groupIdentifier: "folders"),
            .finished(groupIdentifier: "folders", completed: 1, failed: 0, skipped: 0, summary: "1 created"),
            .started(groupIdentifier: "moves"),
            .finished(groupIdentifier: "moves", completed: 2, failed: 0, skipped: 0, summary: "2 moved"),
        ])
        try expectEqual(recorder.progressEvents.last, FileOperationProgress(completedCount: 3, totalCount: 3,
                                                                            currentOperationDescription: "Moving IMG_2", groupIdentifier: "moves"))
        try expectEqual(recorder.progressEvents.first?.currentOperationDescription, "Creating “2026-09”")
    },
    CoreTestCase(name: "a destination taken since planning gets the next suffix, journaled as the actual path") {
        let fileSystem = makeShotsFileSystem().addFile("/Users/me/Desktop/Shots/2026-09/IMG_1.png", contents: "someone else's")
        let journalStore = try makeJournalStore()
        let report = await runPlan(makeFileOperationsPlan(Array(sortShotsOperations.dropFirst())), fileSystem: fileSystem,
                                   journalStore: journalStore, auditLogWriter: try ConversationFixtures.makeAuditLogWriter())
        try expectEqual(report.completedOperationCount, 2)
        try expectEqual(fileSystem.node(atPath: "/Users/me/Desktop/Shots/2026-09/IMG_1.png")?.contents, "someone else's")
        try expectEqual(fileSystem.node(atPath: "/Users/me/Desktop/Shots/2026-09/IMG_1 2.png")?.contents, "one")
        try expectEqual(try journalStore.loadJournal("task-1").entries.first?.destinationPath, "/Users/me/Desktop/Shots/2026-09/IMG_1 2.png")
    },
    CoreTestCase(name: "a failed folder skips the moves into it") {
        let fileSystem = makeShotsFileSystem()
        fileSystem.injectedFailuresByPathKey[InMemoryFileSystem.key("/Users/me/Desktop/Shots/2026-09")] = .permissionDenied
        let recorder = FileOperationRunRecorder()
        let report = await runPlan(makeFileOperationsPlan(sortShotsOperations), fileSystem: fileSystem, journalStore: try makeJournalStore(),
                                   auditLogWriter: try ConversationFixtures.makeAuditLogWriter(), recorder: recorder)
        try expectEqual(report.failedOperationCount, 1)
        try expectEqual(report.skippedOperationCount, 2)
        try expectEqual(report.undoJournalIdentifier, nil)
        try expectEqual(fileSystem.performedMutations, [])
        try expectTrue(report.failures.first?.userFacingReason.contains("permission") == true, "\(report.failures)")
        try expectTrue(!recorder.groupEvents.contains(.started(groupIdentifier: "moves")), "a group none of whose operations ran never starts")
    },
    CoreTestCase(name: "five failures in a row stop the run") {
        let fileSystem = InMemoryFileSystem().addFolder(directRouteTestScopeRootPath)
        var operations: [PlannedFileOperation] = []
        for fileNumber in 1...8 {
            let filePath = "/Users/me/Desktop/Shots/f\(fileNumber).txt"
            fileSystem.addFile(filePath)
            fileSystem.injectedFailuresByPathKey[InMemoryFileSystem.key(filePath)] = .permissionDenied
            operations.append(makePlannedOperation(.rename, from: filePath, to: "/Users/me/Desktop/Shots/g\(fileNumber).txt"))
        }
        let report = await runPlan(makeFileOperationsPlan(operations), fileSystem: fileSystem, journalStore: try makeJournalStore(),
                                   auditLogWriter: try ConversationFixtures.makeAuditLogWriter())
        try expectEqual(report.failedOperationCount, 5)
        try expectEqual(report.skippedOperationCount, 3)
    },
    CoreTestCase(name: "no operation runs after Stop") {
        let fileSystem = makeShotsFileSystem()
        let abortSignal = TaskAbortSignal()
        fileSystem.beforeEachMutation = { if fileSystem.performedMutations.count == 1 { abortSignal.abort() } }
        let report = await runPlan(makeFileOperationsPlan(sortShotsOperations), fileSystem: fileSystem, journalStore: try makeJournalStore(),
                                   auditLogWriter: try ConversationFixtures.makeAuditLogWriter(), runControl: TaskRunControl(pollIntervalNanoseconds: 1_000_000),
                                   abortSignal: abortSignal)
        // The move that was already under way when Stop landed completes; nothing after it starts.
        try expectEqual(fileSystem.performedMutations.count, 2)
        try expectEqual(report.completedOperationCount, 2)
        try expectEqual(report.skippedOperationCount, 1)
    },
    CoreTestCase(name: "skipping while paused skips the rest of the current group and whatever needed it") {
        let fileSystem = makeShotsFileSystem()
        let runControl = TaskRunControl(pollIntervalNanoseconds: 1_000_000)
        runControl.requestPause(reason: .requestedByUser)
        runControl.requestSkipCurrentItem()
        let report = await runPlan(makeFileOperationsPlan(sortShotsOperations), fileSystem: fileSystem, journalStore: try makeJournalStore(),
                                   auditLogWriter: try ConversationFixtures.makeAuditLogWriter(), runControl: runControl)
        try expectEqual(report.completedOperationCount, 0)
        try expectEqual(report.skippedOperationCount, 3)
        try expectEqual(fileSystem.performedMutations, [])
    },
    CoreTestCase(name: "a change that doesn't verify fails but stays journaled for undo") {
        let fileSystem = makeShotsFileSystem()
        fileSystem.tagsReportedAfterSetting = ["Something else"]
        let journalStore = try makeJournalStore()
        let report = await runPlan(makeFileOperationsPlan([makePlannedOperation(.setTags, from: "/Users/me/Desktop/Shots/IMG_1.png", tags: ["Red"])]),
                                   fileSystem: fileSystem, journalStore: journalStore, auditLogWriter: try ConversationFixtures.makeAuditLogWriter())
        try expectEqual(report.failedOperationCount, 1)
        try expectEqual(report.undoJournalIdentifier, "task-1")
        try expectEqual(try journalStore.loadJournal("task-1").entries.first?.previousTags, [])
    },
    CoreTestCase(name: "the audit log holds paths, never file contents") {
        let fileSystem = InMemoryFileSystem().addFolder(directRouteTestScopeRootPath)
            .addFile("/Users/me/Desktop/Shots/secret.txt", contents: "SECRET-CONTENTS")
        let auditLogWriter = try ConversationFixtures.makeAuditLogWriter()
        _ = await runPlan(makeFileOperationsPlan([makePlannedOperation(.copy, from: "/Users/me/Desktop/Shots/secret.txt",
                                                                        to: "/Users/me/Desktop/Shots/copy.txt")]),
                          fileSystem: fileSystem, journalStore: try makeJournalStore(), auditLogWriter: auditLogWriter)
        let logText = try String(contentsOf: auditLogWriter.logFileURL, encoding: .utf8)
        try expectTrue(logText.contains("fileOperation") && logText.contains("/Users/me/Desktop/Shots/copy.txt"), logText)
        try expectTrue(!logText.contains("SECRET-CONTENTS"), logText)
    },
])
