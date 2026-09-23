import Foundation

private let renameTestFolderPath = "/Users/me/Pictures/Trip"

private func makeRenameRule(template nameTemplate: String, order: RenameRuleOrder = .name, isDescending: Bool = false,
                            dateSource: DateFolderRuleDateSource? = nil, extensions: [String] = [],
                            nameContains: String? = nil) -> SubmittedRenameRule {
    SubmittedRenameRule(sourceFolderPath: renameTestFolderPath, nameContains: nameContains, lowercasedExtensions: extensions,
                        typeIdentifiers: [], order: order, isDescending: isDescending, dateSource: dateSource,
                        nameTemplate: nameTemplate, groupIdentifier: "rename")
}

private func makeRenameRecord(_ fileName: String, createdAt: Date? = nil, imageCaptureDate: Date? = nil,
                              pixelWidth: Int? = nil, pixelHeight: Int? = nil, sizeInBytes: Int64? = 10,
                              kind: ExistingFileSystemItemKind = .regularFile) -> FileMetadataRecord {
    FileMetadataRecord(path: renameTestFolderPath + "/" + fileName, kind: kind, isHidden: fileName.hasPrefix("."), sizeInBytes: sizeInBytes,
                       createdAt: createdAt, modifiedAt: nil, addedToFolderAt: nil, contentTypeIdentifier: "public.jpeg",
                       conformingTypeIdentifiers: ["public.jpeg", "public.image"], imageCaptureDate: imageCaptureDate,
                       imagePixelWidth: pixelWidth, imagePixelHeight: pixelHeight, finderTags: [], contentIsNotLocal: false,
                       volumeIdentifier: nil)
}

private func renameTestDate(_ isoText: String) -> Date {
    ISO8601DateFormatter().date(from: isoText) ?? Date(timeIntervalSince1970: 0)
}

private let renameTestEnvironment = DateFolderNamingEnvironment(timeZoneIdentifier: "UTC", localeIdentifier: "es_AR",
                                                                calendarIdentifier: "gregorian")

private func renameExpansion(_ rule: SubmittedRenameRule, _ records: [FileMetadataRecord]) throws -> RenameRuleExpansion {
    switch RenameRuleExpander.expand(rule, entries: records, environment: renameTestEnvironment) {
    case .success(let ruleExpansion): return ruleExpansion
    case .failure(let problem): throw CoreTestFailure(description: "unexpected problem: \(problem.descriptionForModel)")
    }
}

private func renameProblem(_ rule: SubmittedRenameRule, _ records: [FileMetadataRecord]) throws -> FileOperationPlanProblem {
    switch RenameRuleExpander.expand(rule, entries: records, environment: renameTestEnvironment) {
    case .success(let ruleExpansion): throw CoreTestFailure(description: "expected a problem, got \(ruleExpansion.operations)")
    case .failure(let problem): return problem
    }
}

/// "from-name → to-name" for each operation, for compact assertions.
private func renamePairs(_ ruleExpansion: RenameRuleExpansion) -> [String] {
    ruleExpansion.operations.map { operation in
        FileOperationPathRules.name(of: operation.sourcePath ?? "") + " → " + FileOperationPathRules.name(of: operation.destinationPath ?? "")
    }
}

let renameRuleExpanderTestSuite = CoreTestSuite(name: "RenameRuleExpander", testCases: [
    CoreTestCase(name: "oldest first by capture date, zero-padded, keeping each file's extension, in its own folder") {
        let ruleExpansion = try renameExpansion(makeRenameRule(template: "photo-{n:3}", order: .captureDateOrCreated), [
            makeRenameRecord("IMG_2.JPG", createdAt: renameTestDate("2026-01-03T10:00:00Z")),
            makeRenameRecord("IMG_1.heic", createdAt: renameTestDate("2026-05-01T10:00:00Z"), imageCaptureDate: renameTestDate("2026-01-01T10:00:00Z")),
            makeRenameRecord("IMG_3.png", createdAt: renameTestDate("2026-01-02T10:00:00Z")),
        ])
        try expectEqual(renamePairs(ruleExpansion), ["IMG_1.heic → photo-001.heic", "IMG_3.png → photo-002.png", "IMG_2.JPG → photo-003.JPG"])
        try expectTrue(ruleExpansion.operations.allSatisfy { $0.kind == .rename && $0.groupIdentifier == "rename" })
        try expectEqual(ruleExpansion.operations.first?.destinationPath, renameTestFolderPath + "/photo-001.heic")
        try expectEqual(ruleExpansion.operations.map(\.reason), ["#1 · taken 2026-01-01", "#2 · created 2026-01-02", "#3 · created 2026-01-03"])
    },
    CoreTestCase(name: "name order is Finder's, descending reverses it, and {n} without a width isn't padded") {
        let records = ["IMG_10.jpg", "IMG_9.jpg", "IMG_100.jpg"].map { makeRenameRecord($0) }
        try expectEqual(renamePairs(try renameExpansion(makeRenameRule(template: "{n}"), records)),
                        ["IMG_9.jpg → 1.jpg", "IMG_10.jpg → 2.jpg", "IMG_100.jpg → 3.jpg"])
        try expectEqual(renamePairs(try renameExpansion(makeRenameRule(template: "{n}", isDescending: true), records)),
                        ["IMG_100.jpg → 1.jpg", "IMG_10.jpg → 2.jpg", "IMG_9.jpg → 3.jpg"])
    },
    CoreTestCase(name: "name, ext, pixel size, file size and date tokens") {
        let record = makeRenameRecord("Beach.jpeg", createdAt: renameTestDate("2026-09-03T23:30:00Z"), pixelWidth: 223, pixelHeight: 142,
                                      sizeInBytes: 1_260_000)
        func renamed(_ nameTemplate: String, dateSource: DateFolderRuleDateSource? = nil) throws -> String {
            let ruleExpansion = try renameExpansion(makeRenameRule(template: nameTemplate, dateSource: dateSource), [record])
            return FileOperationPathRules.name(of: try unwrapOrFail(ruleExpansion.operations.first?.destinationPath))
        }
        try expectEqual(try renamed("{name} {width}x{height}"), "Beach 223x142.jpeg")
        try expectEqual(try renamed("{name}-{size_kb}kB"), "Beach-1260kB.jpeg")
        try expectEqual(try renamed("{name}-{size_mb}MB"), "Beach-1.3MB.jpeg")
        try expectEqual(try renamed("{date:yyyy-MM-dd} {name}", dateSource: .created), "2026-09-03 Beach.jpeg")
        try expectEqual(try renamed("{name}.{ext}.bak"), "Beach.jpeg.bak", "{ext} places the extension instead")
        let reason = try renameExpansion(makeRenameRule(template: "{name} {width}x{height}"), [record]).operations.first?.reason
        try expectEqual(reason, "#1 by name · 223×142 px")
    },
    CoreTestCase(name: "files missing a value the template needs are skipped and counted, and the rest are numbered without gaps") {
        let ruleExpansion = try renameExpansion(makeRenameRule(template: "{n:2}-{width}x{height}"), [
            makeRenameRecord("a.jpg", pixelWidth: 10, pixelHeight: 20),
            makeRenameRecord("b.jpg"),
            makeRenameRecord("c.jpg", pixelWidth: 30, pixelHeight: 40),
        ])
        try expectEqual(renamePairs(ruleExpansion), ["a.jpg → 01-10x20.jpg", "c.jpg → 02-30x40.jpg"])
        try expectEqual(ruleExpansion.skippedFileCount, 1)
        try expectEqual(ruleExpansion.skippedFilesLackedDescription, "a pixel size")
        let undatedExpansion = try renameExpansion(makeRenameRule(template: "{n}", order: .created), [makeRenameRecord("x.jpg")])
        try expectEqual(undatedExpansion.operations, [])
        try expectEqual(undatedExpansion.skippedFileCount, 1)
        try expectEqual(undatedExpansion.skippedFilesLackedDescription, "a date")
    },
    CoreTestCase(name: "unchanged names are dropped but still take their number") {
        let ruleExpansion = try renameExpansion(makeRenameRule(template: "photo-{n:3}"), [
            makeRenameRecord("a.jpg"), makeRenameRecord("photo-002.jpg"), makeRenameRecord("z.jpg"),
        ])
        try expectEqual(renamePairs(ruleExpansion), ["a.jpg → photo-001.jpg", "z.jpg → photo-003.jpg"])
        try expectEqual(ruleExpansion.skippedFileCount, 0)
    },
    CoreTestCase(name: "hidden files, folders, other folders' files and filtered-out names are left alone") {
        var otherFolderRecord = makeRenameRecord("elsewhere.jpg")
        otherFolderRecord.path = "/Users/me/Pictures/Other/elsewhere.jpg"
        let records = [
            makeRenameRecord("keep.jpg"), makeRenameRecord(".hidden.jpg"), makeRenameRecord("Album", kind: .folder),
            makeRenameRecord("notes.txt"), otherFolderRecord,
        ]
        try expectEqual(renamePairs(try renameExpansion(makeRenameRule(template: "img-{n}", extensions: ["jpg"]), records)),
                        ["keep.jpg → img-1.jpg"])
        try expectEqual(renamePairs(try renameExpansion(makeRenameRule(template: "img-{n}", nameContains: "NOTES"), records)),
                        ["notes.txt → img-1.txt"])
    },
    CoreTestCase(name: "unknown tokens, unmatched braces, bad widths and date letters are problems returned to the model") {
        let records = [makeRenameRecord("a.jpg", createdAt: renameTestDate("2026-01-01T00:00:00Z"))]
        let invalidTemplates: [(String, String)] = [
            ("photo-{index}", "unknown token {index}"),
            ("photo-{n", "without its “}”"),
            ("photo-n}", "without its “{”"),
            ("photo-{n:0}", "must be 1-6"),
            ("photo-{n:7}", "must be 1-6"),
            ("{date:yyyy-MMM}", "uses “M”"),
            ("{date:HH}", "uses “H”"),
            ("photo", "needs a token that differs per file"),
            ("photo.{ext}", "needs a token that differs per file"),
        ]
        for (invalidTemplate, expectedText) in invalidTemplates {
            let problem = try renameProblem(makeRenameRule(template: invalidTemplate, dateSource: .created), records)
            try expectEqual(problem.kind, .invalidName, invalidTemplate)
            try expectTrue(problem.descriptionForModel.contains(expectedText), problem.descriptionForModel)
            try expectTrue(problem.descriptionForModel.hasPrefix("rename_rules name_template “\(invalidTemplate)”"), problem.descriptionForModel)
        }
        try expectTrue(try renameProblem(makeRenameRule(template: "{date:yyyy} {n}"), records).descriptionForModel.contains("set date_source"))
    },
    CoreTestCase(name: "a template that repeats the extension, or makes an invalid name, is a problem") {
        let records = [makeRenameRecord("a.jpg")]
        try expectTrue(try renameProblem(makeRenameRule(template: "photo-{n}.jpg"), records).descriptionForModel
            .contains("already ends with “.jpg”"))
        try expectTrue(try renameProblem(makeRenameRule(template: "{name}/{n}"), records).descriptionForModel.contains("“/” or “:”"))
        try expectTrue(try renameProblem(makeRenameRule(template: ".{name}"), records).descriptionForModel.contains("hide it"))
    },
    CoreTestCase(name: "names that collide with each other or with existing files get a number from the validator, never overwrite") {
        let records = [makeRenameRecord("a.jpg", pixelWidth: 10, pixelHeight: 10), makeRenameRecord("b.jpg", pixelWidth: 10, pixelHeight: 10)]
        let ruleExpansion = try renameExpansion(makeRenameRule(template: "{width}x{height}"), records)
        try expectEqual(renamePairs(ruleExpansion), ["a.jpg → 10x10.jpg", "b.jpg → 10x10.jpg"])
        var itemKindByPath: [String: ExistingFileSystemItemKind] = [
            "/Users": .folder, "/Users/me": .folder, "/Users/me/Pictures": .folder, renameTestFolderPath: .folder,
            renameTestFolderPath + "/a.jpg": .regularFile, renameTestFolderPath + "/b.jpg": .regularFile,
        ]
        itemKindByPath[renameTestFolderPath + "/10x10 2.jpg"] = .regularFile
        let existingItemKindByPath = itemKindByPath
        let fileSystemProbe = FileSystemProbe(existingItemKind: { existingItemKindByPath[$0] }, volumeIdentifier: { _ in "volume" },
                                              isInsidePackage: { _ in false })
        let validationResult = FileOperationPlanValidator.validate(
            operations: ruleExpansion.operations,
            scope: DirectRouteScope(roots: [DirectRouteScopeRoot(canonicalPath: renameTestFolderPath, source: .attachedByUser)]),
            probe: fileSystemProbe, homeDirectoryPath: "/Users/me", maximumOperationCount: 2_000)
        guard case .valid(let validatedOperations, let collisionAdjustments) = validationResult else {
            throw CoreTestFailure(description: "expected a valid plan, got \(validationResult)")
        }
        try expectEqual(validatedOperations.compactMap(\.destinationPath).map(FileOperationPathRules.name(of:)), ["10x10.jpg", "10x10 3.jpg"])
        try expectEqual(collisionAdjustments.count, 1)
    },
])
