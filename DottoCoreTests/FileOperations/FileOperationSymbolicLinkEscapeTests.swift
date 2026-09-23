import Foundation

/// A scope folder holding a link "L" to a folder outside the scope, the layout of the reviewers' symlink probes.
private let escapeScopeRootPath = "/Users/me/Desktop/Shots"
private let outsideFolderPath = "/Users/me/Outside"

private func makeEscapeFileSystem() -> InMemoryFileSystem {
    InMemoryFileSystem()
        .addFolder(escapeScopeRootPath + "/A")
        .addFile(escapeScopeRootPath + "/payload.txt", contents: "INJ")
        .addFile(outsideFolderPath + "/victim.txt", contents: "SECRET")
        .addFolder(outsideFolderPath + "/sub")
        .addSymbolicLink(escapeScopeRootPath + "/L", pointingTo: outsideFolderPath)
}

private func validateEscapePlan(_ operations: [PlannedFileOperation], fileSystem: InMemoryFileSystem) -> FileOperationPlanValidationResult {
    FileOperationPlanValidator.validate(operations: operations, scope: directRouteTestScope, probe: makeFileSystemProbe(fileSystem),
                                        homeDirectoryPath: directRouteTestHomeDirectoryPath, maximumOperationCount: 2_000)
}

private func problems(_ validationResult: FileOperationPlanValidationResult) throws -> [FileOperationPlanProblem] {
    guard case .invalid(let problems) = validationResult else {
        throw CoreTestFailure(description: "expected the plan to be refused, got \(validationResult)")
    }
    return problems
}

private func runEscapePlan(_ operations: [PlannedFileOperation], fileSystem: InMemoryFileSystem) async throws -> DirectRouteRunReport {
    let fileOperationRunner = FileOperationRunner(fileSystem: fileSystem, journalStore: try makeJournalStore(),
                                                  auditLogWriter: try ConversationFixtures.makeAuditLogWriter(),
                                                  homeDirectoryPath: directRouteTestHomeDirectoryPath)
    return await fileOperationRunner.run(makeFileOperationsPlan(operations), taskIdentifier: "escape-task", runControl: nil,
                                         abortSignal: TaskAbortSignal(), onGroupBoundary: { _ in }, onProgress: { _ in })
}

let fileOperationSymbolicLinkEscapeTestSuite = CoreTestSuite(name: "File operations never escape the scope through a link", testCases: [
    CoreTestCase(name: "probe 1: renaming a link into a folder's place so later moves traverse it is refused at plan time") {
        let validationProblems = try problems(validateEscapePlan([
            makePlannedOperation(.rename, from: escapeScopeRootPath + "/A", to: escapeScopeRootPath + "/A-old"),
            makePlannedOperation(.rename, from: escapeScopeRootPath + "/L", to: escapeScopeRootPath + "/A"),
            makePlannedOperation(.move, from: escapeScopeRootPath + "/A/victim.txt", to: escapeScopeRootPath + "/stolen.txt"),
            makePlannedOperation(.setTags, from: escapeScopeRootPath + "/A-old", tags: ["x"]),
            makePlannedOperation(.move, from: escapeScopeRootPath + "/payload.txt", to: escapeScopeRootPath + "/A/sub/payload.txt"),
        ], fileSystem: makeEscapeFileSystem()))
        try expectEqual(validationProblems.first { $0.operationIndex == 1 }?.kind, .sourceKindMismatch, "a link is never moved or renamed")
        try expectTrue(validationProblems.contains { $0.operationIndex == 2 }, "the read through the link is refused")
        try expectTrue(validationProblems.contains { $0.operationIndex == 4 }, "the write through the link is refused")
    },
    CoreTestCase(name: "probe 2: trashing through a link renamed into place is refused, and so is trashing the link itself") {
        let validationProblems = try problems(validateEscapePlan([
            makePlannedOperation(.rename, from: escapeScopeRootPath + "/A", to: escapeScopeRootPath + "/A-old"),
            makePlannedOperation(.rename, from: escapeScopeRootPath + "/L", to: escapeScopeRootPath + "/A"),
            makePlannedOperation(.moveToTrash, from: escapeScopeRootPath + "/A/victim.txt"),
            makePlannedOperation(.moveToTrash, from: escapeScopeRootPath + "/L"),
        ], fileSystem: makeEscapeFileSystem()))
        try expectEqual(validationProblems.map(\.operationIndex), [1, 2, 3])
        try expectEqual(validationProblems.first { $0.operationIndex == 3 }?.kind, .sourceKindMismatch)
    },
    CoreTestCase(name: "probe 3: an operand below a link that already sits on its path is outside the scope") {
        let validationProblems = try problems(validateEscapePlan([
            makePlannedOperation(.move, from: escapeScopeRootPath + "/payload.txt", to: escapeScopeRootPath + "/L/sub/payload.txt"),
            makePlannedOperation(.move, from: escapeScopeRootPath + "/L/victim.txt", to: escapeScopeRootPath + "/stolen.txt"),
            makePlannedOperation(.createFolder, to: escapeScopeRootPath + "/L/new"),
        ], fileSystem: makeEscapeFileSystem()))
        try expectEqual(validationProblems.map(\.kind), [.outsideScope, .outsideScope, .outsideScope])
        try expectTrue(validationProblems[0].descriptionForModel.contains("through the link “L”"), validationProblems[0].descriptionForModel)
    },
    CoreTestCase(name: "a link carried inside a moved folder still can't be traversed afterwards") {
        let fileSystem = makeEscapeFileSystem()
            .addSymbolicLink(escapeScopeRootPath + "/A/inner-link", pointingTo: outsideFolderPath)
        let validationProblems = try problems(validateEscapePlan([
            makePlannedOperation(.move, from: escapeScopeRootPath + "/A", to: escapeScopeRootPath + "/B"),
            makePlannedOperation(.move, from: escapeScopeRootPath + "/payload.txt", to: escapeScopeRootPath + "/B/inner-link/payload.txt"),
        ], fileSystem: fileSystem))
        try expectEqual(validationProblems.map(\.kind), [.outsideScope])
        try expectEqual(validationProblems.map(\.operationIndex), [1])
    },
    CoreTestCase(name: "at run time a folder that became a link since the dry run stops the change before it happens") {
        // The plan was valid when checked; then "A" was swapped for a link to the outside folder.
        let fileSystem = InMemoryFileSystem()
            .addFile(escapeScopeRootPath + "/payload.txt", contents: "INJ")
            .addFolder(outsideFolderPath + "/sub")
            .addSymbolicLink(escapeScopeRootPath + "/A", pointingTo: outsideFolderPath)
        let report = try await runEscapePlan([
            makePlannedOperation(.move, from: escapeScopeRootPath + "/payload.txt", to: escapeScopeRootPath + "/A/sub/payload.txt"),
        ], fileSystem: fileSystem)
        try expectEqual(report.completedOperationCount, 0)
        try expectEqual(report.failedOperationCount, 1)
        try expectTrue(report.failures.first?.userFacingReason.contains("leads somewhere else") == true,
                       report.failures.first?.userFacingReason ?? "")
        try expectEqual(fileSystem.performedMutations, [])
        try expectEqual(fileSystem.node(atPath: escapeScopeRootPath + "/payload.txt")?.contents, "INJ")
    },
    CoreTestCase(name: "at run time a source, a trash and a copy destination whose real folder is outside the scope are refused") {
        let fileSystem = InMemoryFileSystem()
            .addFolder(escapeScopeRootPath + "/Kept")
            .addFile(escapeScopeRootPath + "/Kept/a.png", contents: "a")
            .addFile(outsideFolderPath + "/victim.txt", contents: "SECRET")
            .addSymbolicLink(escapeScopeRootPath + "/A", pointingTo: outsideFolderPath)
        fileSystem.resolvedPathOverridesByPathKey[InMemoryFileSystem.key(escapeScopeRootPath + "/Kept")] = "/Users/me/.ssh"
        let report = try await runEscapePlan([
            makePlannedOperation(.move, from: escapeScopeRootPath + "/A/victim.txt", to: escapeScopeRootPath + "/stolen.txt"),
            makePlannedOperation(.moveToTrash, from: escapeScopeRootPath + "/A/victim.txt"),
            makePlannedOperation(.copy, from: escapeScopeRootPath + "/payload.txt", to: escapeScopeRootPath + "/A/payload.txt"),
            makePlannedOperation(.setTags, from: escapeScopeRootPath + "/Kept/a.png", tags: ["Red"]),
        ], fileSystem: fileSystem)
        try expectEqual(report.completedOperationCount, 0)
        try expectEqual(report.failedOperationCount, 4)
        try expectEqual(fileSystem.performedMutations, [])
        try expectEqual(fileSystem.node(atPath: outsideFolderPath + "/victim.txt")?.contents, "SECRET")
    },
    CoreTestCase(name: "the containment check accepts a real folder inside the scope and refuses one outside or protected") {
        try expectEqual(FileOperationContainmentCheck.problem(
            operandPath: escapeScopeRootPath + "/2026-09/a.png", resolvedParentPath: escapeScopeRootPath + "/2026-09",
            scope: directRouteTestScope, homeDirectoryPath: directRouteTestHomeDirectoryPath), nil)
        try expectEqual(FileOperationContainmentCheck.problem(
            operandPath: escapeScopeRootPath + "/a.png", resolvedParentPath: escapeScopeRootPath,
            scope: directRouteTestScope, homeDirectoryPath: directRouteTestHomeDirectoryPath), nil, "the root's own children")
        try expectEqual(FileOperationContainmentCheck.problem(
            operandPath: escapeScopeRootPath + "/2026-09/a.png", resolvedParentPath: "/System/Volumes/Data" + escapeScopeRootPath + "/2026-09",
            scope: directRouteTestScope, homeDirectoryPath: directRouteTestHomeDirectoryPath), nil, "the data-volume spelling")
        try expectTrue(FileOperationContainmentCheck.problem(
            operandPath: escapeScopeRootPath + "/A/a.png", resolvedParentPath: "/Users/me/.ssh",
            scope: directRouteTestScope, homeDirectoryPath: directRouteTestHomeDirectoryPath) != nil)
        try expectTrue(FileOperationContainmentCheck.problem(
            operandPath: escapeScopeRootPath + "/A/a.png", resolvedParentPath: nil,
            scope: directRouteTestScope, homeDirectoryPath: directRouteTestHomeDirectoryPath) != nil)
        let scopeWithProtectedChild = DirectRouteScope(roots: [DirectRouteScopeRoot(canonicalPath: "/Users/me/Projects", source: .attachedByUser)])
        try expectTrue(FileOperationContainmentCheck.problem(
            operandPath: "/Users/me/Projects/.ssh/id_ed25519", resolvedParentPath: "/Users/me/Projects/.ssh",
            scope: scopeWithProtectedChild, homeDirectoryPath: directRouteTestHomeDirectoryPath) != nil)
    },
    CoreTestCase(name: "undo refuses to move a file back through a folder that became a link") {
        let fileSystem = InMemoryFileSystem()
            .addFolder(escapeScopeRootPath + "/2026-09")
            .addFile(escapeScopeRootPath + "/2026-09/a.png", contents: "a")
            .addFolder(outsideFolderPath)
        let journalStore = try makeJournalStore()
        try journalStore.beginJournal(FileOperationJournalHeader(journalIdentifier: "undo-escape", taskTitle: "t",
                                                                 scope: directRouteTestScope, startedAt: Date()))
        try journalStore.append(FileOperationJournalEntry(operationIdentifier: "op-1", kind: .move,
                                                          sourcePath: escapeScopeRootPath + "/Old/a.png",
                                                          destinationPath: escapeScopeRootPath + "/2026-09/a.png",
                                                          previousTags: nil, trashedItemPath: nil, performedAt: Date()),
                                toJournal: "undo-escape")
        try journalStore.markStatus(.finished, ofJournal: "undo-escape")
        fileSystem.addSymbolicLink(escapeScopeRootPath + "/Old", pointingTo: outsideFolderPath)
        let undoReport = try await FileOperationUndoRunner(fileSystem: fileSystem, journalStore: journalStore, auditLogWriter: nil,
                                                           homeDirectoryPath: directRouteTestHomeDirectoryPath)
            .undo(journalIdentifier: "undo-escape", abortSignal: TaskAbortSignal(), onProgress: { _ in })
        try expectEqual(undoReport.revertedCount, 0)
        try expectEqual(fileSystem.performedMutations, [])
    },
])
