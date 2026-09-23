import Foundation

let directRouteTestHomeDirectoryPath = "/Users/me"
let directRouteTestScopeRootPath = "/Users/me/Desktop/Shots"
let directRouteTestScope = DirectRouteScope(roots: [
    DirectRouteScopeRoot(canonicalPath: directRouteTestScopeRootPath, source: .finderWindowUnderSummonPoint),
])

func makePlannedOperation(_ kind: FileOperationKind, from sourcePath: String? = nil, to destinationPath: String? = nil,
                          tags: [String]? = nil, group groupIdentifier: String = "g1") -> PlannedFileOperation {
    PlannedFileOperation(operationIdentifier: "draft", kind: kind, sourcePath: sourcePath, destinationPath: destinationPath,
                         tags: tags, reason: "test", groupIdentifier: groupIdentifier)
}

func makeFileSystemProbe(_ inMemoryFileSystem: InMemoryFileSystem) -> FileSystemProbe {
    FileSystemProbe(existingItemKind: { inMemoryFileSystem.existingItemKind(atCanonicalPath: $0) },
                    volumeIdentifier: { inMemoryFileSystem.volumeIdentifier(ofCanonicalPath: $0) },
                    isInsidePackage: { path in
                        var ancestorPath = FileOperationPathRules.parentPath(of: path)
                        while ancestorPath != "/" {
                            if inMemoryFileSystem.existingItemKind(atCanonicalPath: ancestorPath) == .package { return true }
                            ancestorPath = FileOperationPathRules.parentPath(of: ancestorPath)
                        }
                        return false
                    })
}

func makeShotsFileSystem() -> InMemoryFileSystem {
    InMemoryFileSystem()
        .addFolder(directRouteTestScopeRootPath)
        .addFile("/Users/me/Desktop/Shots/IMG_1.png", contents: "one")
        .addFile("/Users/me/Desktop/Shots/IMG_2.png", contents: "two")
}

private func validate(_ operations: [PlannedFileOperation], fileSystem: InMemoryFileSystem = makeShotsFileSystem(),
                      scope: DirectRouteScope = directRouteTestScope, maximumOperationCount: Int = 2_000) -> FileOperationPlanValidationResult {
    FileOperationPlanValidator.validate(operations: operations, scope: scope, probe: makeFileSystemProbe(fileSystem),
                                        homeDirectoryPath: directRouteTestHomeDirectoryPath, maximumOperationCount: maximumOperationCount)
}

private func problemKinds(_ validationResult: FileOperationPlanValidationResult) throws -> [FileOperationPlanProblem.Kind] {
    guard case .invalid(let problems) = validationResult else {
        throw CoreTestFailure(description: "expected problems, got \(validationResult)")
    }
    return problems.map(\.kind)
}

private func validOperations(_ validationResult: FileOperationPlanValidationResult) throws
    -> (operations: [PlannedFileOperation], adjustments: [FileOperationCollisionAdjustment]) {
    guard case .valid(let operations, let collisionAdjustments) = validationResult else {
        throw CoreTestFailure(description: "expected a valid plan, got \(validationResult)")
    }
    return (operations, collisionAdjustments)
}

let fileOperationPlanValidatorTestSuite = CoreTestSuite(name: "FileOperationPlanValidator", testCases: [
    CoreTestCase(name: "a folder then moves into it is valid, renumbered op-1…") {
        let validated = try validOperations(validate([
            makePlannedOperation(.createFolder, to: "/Users/me/Desktop/Shots/2026-09"),
            makePlannedOperation(.move, from: "/Users/me/Desktop/Shots/IMG_1.png", to: "/Users/me/Desktop/Shots/2026-09/IMG_1.png"),
            makePlannedOperation(.move, from: "/Users/me/Desktop/Shots/IMG_2.png", to: "/Users/me/Desktop/Shots/2026-09/IMG_2.png"),
        ]))
        try expectEqual(validated.operations.map(\.operationIdentifier), ["op-1", "op-2", "op-3"])
        try expectEqual(validated.adjustments, [])
    },
    CoreTestCase(name: "a destination folder that neither exists nor is created earlier is a problem") {
        try expectEqual(try problemKinds(validate([
            makePlannedOperation(.move, from: "/Users/me/Desktop/Shots/IMG_1.png", to: "/Users/me/Desktop/Shots/2026-09/IMG_1.png"),
        ])), [.destinationParentMissing])
    },
    CoreTestCase(name: "a missing source, and a source an earlier operation already moved, are problems") {
        try expectEqual(try problemKinds(validate([
            makePlannedOperation(.move, from: "/Users/me/Desktop/Shots/IMG_9.png", to: "/Users/me/Desktop/Shots/IMG_9b.png"),
        ])), [.sourceMissing])
        try expectEqual(try problemKinds(validate([
            makePlannedOperation(.rename, from: "/Users/me/Desktop/Shots/IMG_1.png", to: "/Users/me/Desktop/Shots/one.png"),
            makePlannedOperation(.rename, from: "/Users/me/Desktop/Shots/IMG_1.png", to: "/Users/me/Desktop/Shots/uno.png"),
        ])), [.duplicateSource])
        // The item's new path works for a later operation.
        _ = try validOperations(validate([
            makePlannedOperation(.rename, from: "/Users/me/Desktop/Shots/IMG_1.png", to: "/Users/me/Desktop/Shots/one.png"),
            makePlannedOperation(.rename, from: "/Users/me/Desktop/Shots/one.png", to: "/Users/me/Desktop/Shots/uno.png"),
        ]))
    },
    CoreTestCase(name: "an item inside a folder an earlier operation moved is missing at its old path and found at the new one") {
        let fileSystem = makeShotsFileSystem().addFile("/Users/me/Desktop/Shots/Old/a.png")
        try expectEqual(try problemKinds(validate([
            makePlannedOperation(.rename, from: "/Users/me/Desktop/Shots/Old", to: "/Users/me/Desktop/Shots/New"),
            makePlannedOperation(.rename, from: "/Users/me/Desktop/Shots/Old/a.png", to: "/Users/me/Desktop/Shots/Old/b.png"),
        ], fileSystem: fileSystem)), [.sourceMissing])
        _ = try validOperations(validate([
            makePlannedOperation(.rename, from: "/Users/me/Desktop/Shots/Old", to: "/Users/me/Desktop/Shots/New"),
            makePlannedOperation(.rename, from: "/Users/me/Desktop/Shots/New/a.png", to: "/Users/me/Desktop/Shots/New/b.png"),
        ], fileSystem: fileSystem))
    },
    CoreTestCase(name: "a taken destination gets \" 2\", and a destination an earlier operation took gets \" 3\"") {
        let fileSystem = makeShotsFileSystem().addFile("/Users/me/Desktop/Shots/Sorted/IMG.png")
            .addFile("/Users/me/Desktop/Shots/Other/IMG.png").addFile("/Users/me/Desktop/Shots/Third/IMG.png")
        let validated = try validOperations(validate([
            makePlannedOperation(.move, from: "/Users/me/Desktop/Shots/Other/IMG.png", to: "/Users/me/Desktop/Shots/Sorted/IMG.png"),
            makePlannedOperation(.move, from: "/Users/me/Desktop/Shots/Third/IMG.png", to: "/Users/me/Desktop/Shots/Sorted/img.PNG"),
        ], fileSystem: fileSystem))
        try expectEqual(validated.operations.map(\.destinationPath), ["/Users/me/Desktop/Shots/Sorted/IMG 2.png",
                                                                     "/Users/me/Desktop/Shots/Sorted/img 3.PNG"])
        try expectEqual(validated.adjustments, [
            FileOperationCollisionAdjustment(operationIdentifier: "op-1", requestedDestinationPath: "/Users/me/Desktop/Shots/Sorted/IMG.png",
                                             adjustedDestinationPath: "/Users/me/Desktop/Shots/Sorted/IMG 2.png"),
            FileOperationCollisionAdjustment(operationIdentifier: "op-2", requestedDestinationPath: "/Users/me/Desktop/Shots/Sorted/img.PNG",
                                             adjustedDestinationPath: "/Users/me/Desktop/Shots/Sorted/img 3.PNG"),
        ])
    },
    CoreTestCase(name: "creating an existing folder is dropped; creating over an existing file is a problem") {
        let fileSystem = makeShotsFileSystem().addFolder("/Users/me/Desktop/Shots/2026-09")
        let validated = try validOperations(validate([
            makePlannedOperation(.createFolder, to: "/Users/me/Desktop/Shots/2026-09"),
            makePlannedOperation(.createFolder, to: "/Users/me/Desktop/Shots/2026-10"),
            makePlannedOperation(.createFolder, to: "/Users/me/Desktop/Shots/2026-10"),
        ], fileSystem: fileSystem))
        try expectEqual(validated.operations.map(\.destinationPath), ["/Users/me/Desktop/Shots/2026-10"])
        try expectEqual(try problemKinds(validate([makePlannedOperation(.createFolder, to: "/Users/me/Desktop/Shots/IMG_1.png")])),
                        [.unsupportedOperand])
    },
    CoreTestCase(name: "a folder can't go into itself or its descendant") {
        let fileSystem = makeShotsFileSystem().addFolder("/Users/me/Desktop/Shots/A/Child")
        try expectEqual(try problemKinds(validate([
            makePlannedOperation(.move, from: "/Users/me/Desktop/Shots/A", to: "/Users/me/Desktop/Shots/A/Child/A"),
        ], fileSystem: fileSystem)), [.cycle])
        try expectEqual(try problemKinds(validate([
            makePlannedOperation(.copy, from: "/Users/me/Desktop/Shots/A", to: "/Users/me/Desktop/Shots/a/Copy"),
        ], fileSystem: fileSystem)), [.cycle])
    },
    CoreTestCase(name: "moves can't cross volumes, copies can") {
        let externalScope = DirectRouteScope(roots: directRouteTestScope.roots + [
            DirectRouteScopeRoot(canonicalPath: "/Volumes/Ext/Backup", source: .typedInCommand)])
        let fileSystem = makeShotsFileSystem().addFolder("/Volumes/Ext", volumeIdentifier: "volume-ext").addFolder("/Volumes/Ext/Backup/In")
        try expectEqual(try problemKinds(validate([
            makePlannedOperation(.move, from: "/Users/me/Desktop/Shots/IMG_1.png", to: "/Volumes/Ext/Backup/In/IMG_1.png"),
        ], fileSystem: fileSystem, scope: externalScope)), [.crossVolume])
        _ = try validOperations(validate([
            makePlannedOperation(.copy, from: "/Users/me/Desktop/Shots/IMG_1.png", to: "/Volumes/Ext/Backup/In/IMG_1.png"),
        ], fileSystem: fileSystem, scope: externalScope))
    },
    CoreTestCase(name: "a rename can't change folders; a case-only rename is not a collision") {
        let fileSystem = makeShotsFileSystem().addFolder("/Users/me/Desktop/Shots/Sub")
        try expectEqual(try problemKinds(validate([
            makePlannedOperation(.rename, from: "/Users/me/Desktop/Shots/IMG_1.png", to: "/Users/me/Desktop/Shots/Sub/IMG_1.png"),
        ], fileSystem: fileSystem)), [.renameChangesFolder])
        let validated = try validOperations(validate([
            makePlannedOperation(.rename, from: "/Users/me/Desktop/Shots/IMG_1.png", to: "/Users/me/Desktop/Shots/img_1.png"),
        ], fileSystem: fileSystem))
        try expectEqual(validated.operations.first?.destinationPath, "/Users/me/Desktop/Shots/img_1.png")
        try expectEqual(validated.adjustments, [])
    },
    CoreTestCase(name: "a symbolic link is left alone entirely; sockets and devices are refused") {
        let fileSystem = makeShotsFileSystem().addItem("/Users/me/Desktop/Shots/link", kind: .symbolicLink)
            .addItem("/Users/me/Desktop/Shots/socket", kind: .other)
        try expectEqual(try problemKinds(validate([
            makePlannedOperation(.rename, from: "/Users/me/Desktop/Shots/link", to: "/Users/me/Desktop/Shots/link2"),
            makePlannedOperation(.move, from: "/Users/me/Desktop/Shots/link", to: "/Users/me/Desktop/Shots/Sub/link"),
            makePlannedOperation(.copy, from: "/Users/me/Desktop/Shots/link", to: "/Users/me/Desktop/Shots/link2"),
            makePlannedOperation(.setTags, from: "/Users/me/Desktop/Shots/link", tags: ["Red"]),
            makePlannedOperation(.moveToTrash, from: "/Users/me/Desktop/Shots/link"),
            makePlannedOperation(.moveToTrash, from: "/Users/me/Desktop/Shots/socket"),
        ], fileSystem: fileSystem)), [.sourceKindMismatch, .sourceKindMismatch, .sourceKindMismatch, .sourceKindMismatch,
                                      .sourceKindMismatch, .unsupportedOperand])
    },
    CoreTestCase(name: "created folders don't count against the cap on changes, but have a cap of their own") {
        let twoFolders = (1...2).map { makePlannedOperation(.createFolder, to: "/Users/me/Desktop/Shots/F\($0)") }
        let threeFolders = (1...3).map { makePlannedOperation(.createFolder, to: "/Users/me/Desktop/Shots/F\($0)") }
        let validated = try validOperations(validate(twoFolders + [
            makePlannedOperation(.move, from: "/Users/me/Desktop/Shots/IMG_1.png", to: "/Users/me/Desktop/Shots/F1/IMG_1.png"),
            makePlannedOperation(.move, from: "/Users/me/Desktop/Shots/IMG_2.png", to: "/Users/me/Desktop/Shots/F2/IMG_2.png"),
        ], maximumOperationCount: 2))
        try expectEqual(validated.operations.count, 4)
        try expectEqual(try problemKinds(validate(threeFolders, maximumOperationCount: 2)), [.tooManyOperations])
    },
    CoreTestCase(name: "problems carry the caller's labels, and a re-check keeps the approved identifiers") {
        guard case .invalid(let labeledProblems) = FileOperationPlanValidator.validate(
            operations: [makePlannedOperation(.move, from: "/Users/me/Desktop/Shots/missing.png", to: "/Users/me/Desktop/Shots/x.png")],
            scope: directRouteTestScope, probe: makeFileSystemProbe(makeShotsFileSystem()),
            homeDirectoryPath: directRouteTestHomeDirectoryPath, maximumOperationCount: 2_000,
            operationLabels: ["Date folder rule 2"]) else { throw CoreTestFailure(description: "expected a problem") }
        try expectTrue(labeledProblems[0].descriptionForModel.hasPrefix("Date folder rule 2 (move):"), labeledProblems[0].descriptionForModel)

        let fileSystem = makeShotsFileSystem().addFolder("/Users/me/Desktop/Shots/2026-09")
        var approvedOperations = [
            makePlannedOperation(.createFolder, to: "/Users/me/Desktop/Shots/2026-09"),
            makePlannedOperation(.move, from: "/Users/me/Desktop/Shots/IMG_1.png", to: "/Users/me/Desktop/Shots/2026-09/IMG_1.png"),
        ]
        approvedOperations[0].operationIdentifier = "op-1"
        approvedOperations[1].operationIdentifier = "op-2"
        guard case .valid(let recheckedOperations, _) = FileOperationPlanValidator.validate(
            operations: approvedOperations, scope: directRouteTestScope, probe: makeFileSystemProbe(fileSystem),
            homeDirectoryPath: directRouteTestHomeDirectoryPath, maximumOperationCount: 2_000,
            keepsOperationIdentifiers: true) else { throw CoreTestFailure(description: "expected a valid re-check") }
        try expectEqual(recheckedOperations.map(\.operationIdentifier), ["op-2"], "the folder that now exists drops out; op-2 keeps its name")
    },
    CoreTestCase(name: "hidden items and items in hidden folders are refused, and new hidden names too") {
        let fileSystem = makeShotsFileSystem().addFile("/Users/me/Desktop/Shots/.DS_Store").addFile("/Users/me/Desktop/Shots/.git/config")
        try expectEqual(try problemKinds(validate([
            makePlannedOperation(.moveToTrash, from: "/Users/me/Desktop/Shots/.DS_Store"),
            makePlannedOperation(.rename, from: "/Users/me/Desktop/Shots/.git/config", to: "/Users/me/Desktop/Shots/.git/config2"),
            makePlannedOperation(.rename, from: "/Users/me/Desktop/Shots/IMG_1.png", to: "/Users/me/Desktop/Shots/.IMG_1.png"),
        ], fileSystem: fileSystem)), [.hiddenItem, .hiddenItem, .invalidName])
    },
    CoreTestCase(name: "the scope root can't be an operand, and paths outside the scope or protected are refused") {
        try expectEqual(try problemKinds(validate([
            makePlannedOperation(.moveToTrash, from: directRouteTestScopeRootPath),
            makePlannedOperation(.move, from: "/Users/me/Desktop/Shots/IMG_1.png", to: "/Users/me/Documents/IMG_1.png"),
            makePlannedOperation(.move, from: "/Users/me/Desktop/Shots/IMG_2.png", to: "/Users/me/Desktop/Shots/.ssh/IMG_2.png"),
        ])), [.scopeRootOperand, .outsideScope, .protectedPath])
    },
    CoreTestCase(name: "an empty plan and a plan over the ceiling are refused") {
        try expectEqual(try problemKinds(validate([])), [.emptyPlan])
        let tooManyOperations = (1...2_001).map { operationNumber in
            makePlannedOperation(.createFolder, to: "/Users/me/Desktop/Shots/f\(operationNumber)")
        }
        try expectEqual(try problemKinds(validate(tooManyOperations)), [.tooManyOperations])
        try expectEqual(try problemKinds(validate([makePlannedOperation(.createFolder, to: "/Users/me/Desktop/Shots/a")],
                                                  maximumOperationCount: 0)), [.tooManyOperations])
    },
    CoreTestCase(name: "tags are limited in count and content") {
        _ = try validOperations(validate([makePlannedOperation(.setTags, from: "/Users/me/Desktop/Shots/IMG_1.png", tags: ["Red", "Work"])]))
        try expectEqual(try problemKinds(validate([
            makePlannedOperation(.setTags, from: "/Users/me/Desktop/Shots/IMG_1.png", tags: (1...21).map { "t\($0)" }),
            makePlannedOperation(.setTags, from: "/Users/me/Desktop/Shots/IMG_2.png", tags: ["bad\ntag"]),
        ])), [.invalidName, .invalidName])
    },
    CoreTestCase(name: "problems name files by basename only") {
        guard case .invalid(let problems) = validate([
            makePlannedOperation(.move, from: "/Users/me/Desktop/Shots/IMG_1.png", to: "/Users/me/Desktop/Shots/Missing/IMG_1.png"),
        ]) else { throw CoreTestFailure(description: "expected problems") }
        try expectTrue(problems.allSatisfy { !$0.descriptionForModel.contains("/Users/me") }, "\(problems)")
        try expectEqual(problems.first?.operationIndex, 0)
    },
])
