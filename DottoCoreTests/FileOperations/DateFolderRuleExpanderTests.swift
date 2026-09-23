import Foundation

private func makeRule(format folderNameFormat: String = "yyyy-MM MMMM", dateSource: DateFolderRuleDateSource = .captureDateOrCreated,
                      extensions: [String] = [], typeIdentifiers: [String] = [], nameContains: String? = nil) -> SubmittedDateFolderRule {
    SubmittedDateFolderRule(sourceFolderPath: "/Users/me/Desktop/Shots", destinationParentFolderPath: "/Users/me/Desktop/Shots",
                            nameContains: nameContains, lowercasedExtensions: extensions, typeIdentifiers: typeIdentifiers,
                            dateSource: dateSource, folderNameFormat: folderNameFormat, groupIdentifier: "sort")
}

private func makeRecord(_ fileName: String, createdAt: Date? = nil, imageCaptureDate: Date? = nil, kind: ExistingFileSystemItemKind = .regularFile,
                        conformingTypeIdentifiers: [String] = ["public.png", "public.image"]) -> FileMetadataRecord {
    FileMetadataRecord(path: "/Users/me/Desktop/Shots/\(fileName)", kind: kind, isHidden: fileName.hasPrefix("."), sizeInBytes: 10,
                       createdAt: createdAt, modifiedAt: nil, addedToFolderAt: nil, contentTypeIdentifier: conformingTypeIdentifiers.first,
                       conformingTypeIdentifiers: conformingTypeIdentifiers, imageCaptureDate: imageCaptureDate,
                       imagePixelWidth: nil, imagePixelHeight: nil, finderTags: [], contentIsNotLocal: false, volumeIdentifier: nil)
}

private func date(_ isoText: String) -> Date {
    ISO8601DateFormatter().date(from: isoText) ?? Date(timeIntervalSince1970: 0)
}

private let spanishEnvironment = DateFolderNamingEnvironment(timeZoneIdentifier: "America/Argentina/Buenos_Aires", localeIdentifier: "es_ES",
                                                             calendarIdentifier: "gregorian")
private let englishEnvironment = DateFolderNamingEnvironment(timeZoneIdentifier: "UTC", localeIdentifier: "en_US", calendarIdentifier: "gregorian")

private func expansion(_ rule: SubmittedDateFolderRule, _ records: [FileMetadataRecord],
                       environment: DateFolderNamingEnvironment = spanishEnvironment) throws -> DateFolderRuleExpansion {
    switch DateFolderRuleExpander.expand(rule, entries: records, environment: environment) {
    case .success(let ruleExpansion): return ruleExpansion
    case .failure(let problem): throw CoreTestFailure(description: "unexpected problem: \(problem)")
    }
}

let dateFolderRuleExpanderTestSuite = CoreTestSuite(name: "DateFolderRuleExpander", testCases: [
    CoreTestCase(name: "month names follow the locale and are capitalized") {
        let records = [makeRecord("a.png", createdAt: date("2026-09-10T15:00:00Z"))]
        try expectEqual(try expansion(makeRule(), records).operations.first?.destinationPath, "/Users/me/Desktop/Shots/2026-09 Septiembre")
        try expectEqual(try expansion(makeRule(), records, environment: englishEnvironment).operations.first?.destinationPath,
                        "/Users/me/Desktop/Shots/2026-09 September")
    },
    CoreTestCase(name: "the capture date wins over the creation date, and the reason says which") {
        let ruleExpansion = try expansion(makeRule(format: "yyyy-MM"), [
            makeRecord("taken.png", createdAt: date("2026-10-01T12:00:00Z"), imageCaptureDate: date("2026-08-15T12:00:00Z")),
            makeRecord("made.png", createdAt: date("2026-10-02T12:00:00Z")),
        ])
        let moveOperations = ruleExpansion.operations.filter { $0.kind == .move }
        try expectEqual(moveOperations.map(\.destinationPath), ["/Users/me/Desktop/Shots/2026-08/taken.png", "/Users/me/Desktop/Shots/2026-10/made.png"])
        try expectEqual(moveOperations.map(\.reason), ["Taken 2026-08-15", "Created 2026-10-02"])
    },
    CoreTestCase(name: "the folder follows the user's time zone at a month edge") {
        // 23:30 on Aug 31 in UTC-3 is already Sep 1 in UTC.
        let records = [makeRecord("late.png", createdAt: date("2026-09-01T02:30:00Z"))]
        try expectEqual(try expansion(makeRule(format: "yyyy-MM-dd"), records).operations.first?.destinationPath,
                        "/Users/me/Desktop/Shots/2026-08-31")
        try expectEqual(try expansion(makeRule(format: "yyyy-MM-dd"), records, environment: englishEnvironment).operations.first?.destinationPath,
                        "/Users/me/Desktop/Shots/2026-09-01")
    },
    CoreTestCase(name: "extension, type and name filters apply, and folders, hidden files and other folders' files are left out") {
        var otherFolderRecord = makeRecord("elsewhere.png", createdAt: date("2026-09-01T12:00:00Z"))
        otherFolderRecord.path = "/Users/me/Desktop/Other/elsewhere.png"
        let records = [
            makeRecord("Screenshot 1.png", createdAt: date("2026-09-01T12:00:00Z")),
            makeRecord("photo.jpg", createdAt: date("2026-09-01T12:00:00Z"), conformingTypeIdentifiers: ["public.jpeg", "public.image"]),
            makeRecord("notes.txt", createdAt: date("2026-09-01T12:00:00Z"), conformingTypeIdentifiers: ["public.plain-text"]),
            makeRecord(".hidden.png", createdAt: date("2026-09-01T12:00:00Z")),
            makeRecord("Folder", createdAt: date("2026-09-01T12:00:00Z"), kind: .folder),
            otherFolderRecord,
        ]
        func movedNames(_ rule: SubmittedDateFolderRule) throws -> [String] {
            try expansion(rule, records).operations.filter { $0.kind == .move }.compactMap(\.sourcePath).map(FileOperationPathRules.name(of:))
        }
        try expectEqual(try movedNames(makeRule(extensions: ["PNG"])), ["Screenshot 1.png"])
        try expectEqual(try movedNames(makeRule(typeIdentifiers: ["public.image"])), ["Screenshot 1.png", "photo.jpg"])
        try expectEqual(try movedNames(makeRule(nameContains: "screenshot")), ["Screenshot 1.png"])
        try expectEqual(try movedNames(makeRule()), ["Screenshot 1.png", "notes.txt", "photo.jpg"])
    },
    CoreTestCase(name: "files without the chosen date are skipped and counted") {
        let ruleExpansion = try expansion(makeRule(dateSource: .modified), [makeRecord("a.png", createdAt: date("2026-09-01T12:00:00Z"))])
        try expectEqual(ruleExpansion.operations, [])
        try expectEqual(ruleExpansion.skippedFileCount, 1)
    },
    CoreTestCase(name: "one create per distinct folder in date order, then moves by date and name") {
        let ruleExpansion = try expansion(makeRule(format: "yyyy-MM"), [
            makeRecord("c.png", createdAt: date("2026-10-05T12:00:00Z")),
            makeRecord("b.png", createdAt: date("2026-09-05T12:00:00Z")),
            makeRecord("a.png", createdAt: date("2026-09-05T12:00:00Z")),
        ])
        try expectEqual(ruleExpansion.operations.map(\.kind), [.createFolder, .createFolder, .move, .move, .move])
        try expectEqual(ruleExpansion.operations.prefix(2).map(\.destinationPath),
                        ["/Users/me/Desktop/Shots/2026-09", "/Users/me/Desktop/Shots/2026-10"])
        try expectEqual(ruleExpansion.operations.suffix(3).compactMap(\.sourcePath).map(FileOperationPathRules.name(of:)), ["a.png", "b.png", "c.png"])
        try expectTrue(ruleExpansion.operations.allSatisfy { $0.groupIdentifier == "sort" })
    },
    CoreTestCase(name: "unknown format letters, formats without a date token and names with a slash are problems") {
        let records = [makeRecord("a.png", createdAt: date("2026-09-01T12:00:00Z"))]
        for invalidFormat in ["yyyy-MM HH", "yy-MM", "Photos", "yyyy/MM"] {
            guard case .failure(let problem) = DateFolderRuleExpander.expand(makeRule(format: invalidFormat), entries: records,
                                                                            environment: spanishEnvironment) else {
                throw CoreTestFailure(description: "expected a problem for \(invalidFormat)")
            }
            try expectEqual(problem.kind, .invalidName, invalidFormat)
        }
    },
])
