import Foundation

/// The user's time zone, calendar and locale, so date folder names read the way they expect ("2026-09 Septiembre").
struct DateFolderNamingEnvironment: Equatable, Sendable {
    var timeZoneIdentifier: String
    var localeIdentifier: String
    var calendarIdentifier: String

    /// Dotto's bundle is English only, so `Locale.current` speaks English even when the user's Mac is in Spanish; the
    /// user's first preferred language (with their region) is what they read their month names in.
    static var current: DateFolderNamingEnvironment {
        DateFolderNamingEnvironment(
            timeZoneIdentifier: TimeZone.current.identifier,
            localeIdentifier: namingLocaleIdentifier(preferredLanguageIdentifiers: Locale.preferredLanguages,
                                                     currentRegionIdentifier: Locale.current.region?.identifier,
                                                     currentLocaleIdentifier: Locale.current.identifier),
            calendarIdentifier: (Calendar.current as NSCalendar).calendarIdentifier.rawValue)
    }

    /// The first preferred language tag ("es-AR", "es", "zh-Hans-CN") as a locale identifier: its language, its script
    /// when it names one, and its own region, else the current region ("es" + AR → "es_AR"). Falls back to the current
    /// locale when there is no preferred language or its tag doesn't start with a 2-3 letter language code.
    static func namingLocaleIdentifier(preferredLanguageIdentifiers: [String], currentRegionIdentifier: String?,
                                       currentLocaleIdentifier: String) -> String {
        guard let preferredLanguageIdentifier = preferredLanguageIdentifiers.first else { return currentLocaleIdentifier }
        let tagComponents = preferredLanguageIdentifier.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
        guard let languageCode = tagComponents.first, (2...3).contains(languageCode.count),
              languageCode.allSatisfy({ $0.isASCII && $0.isLetter }) else { return currentLocaleIdentifier }
        var scriptCode: String?
        var tagRegionCode: String?
        // Subtags after the language: an optional 4-letter script, then an optional 2-letter or 3-digit region.
        // Anything later (variants, "-u-" extensions) doesn't change month names and is dropped.
        for subtag in tagComponents.dropFirst() {
            if scriptCode == nil, tagRegionCode == nil, subtag.count == 4, subtag.allSatisfy({ $0.isASCII && $0.isLetter }) {
                scriptCode = subtag.prefix(1).uppercased() + subtag.dropFirst().lowercased()
            } else if tagRegionCode == nil,
                      (subtag.count == 2 && subtag.allSatisfy({ $0.isASCII && $0.isLetter }))
                        || (subtag.count == 3 && subtag.allSatisfy({ $0.isASCII && $0.isNumber })) {
                tagRegionCode = subtag.uppercased()
            } else {
                break
            }
        }
        let regionCode = tagRegionCode ?? currentRegionIdentifier.flatMap { $0.isEmpty ? nil : $0.uppercased() }
        return ([languageCode.lowercased(), scriptCode, regionCode].compactMap { $0 }).joined(separator: "_")
    }

    var timeZone: TimeZone { TimeZone(identifier: timeZoneIdentifier) ?? TimeZone.current }
    var locale: Locale { Locale(identifier: localeIdentifier) }
    /// Numbers in names (years, months, days, counters) always use ASCII digits, whatever the user's language, so
    /// names sort and read the same everywhere; only month names follow `locale`.
    var digitsLocale: Locale { Locale(identifier: "en_US_POSIX") }
    var calendar: Calendar {
        var calendar = (NSCalendar(identifier: NSCalendar.Identifier(rawValue: calendarIdentifier)) as Calendar?)
            ?? Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = locale
        return calendar
    }
}

extension SubmittedDateFolderRule {
    var fileFilter: FileRuleFileFilter {
        FileRuleFileFilter(sourceFolderPath: sourceFolderPath, nameContains: nameContains,
                           lowercasedExtensions: lowercasedExtensions, typeIdentifiers: typeIdentifiers)
    }
}

struct DateFolderRuleExpansion: Equatable, Sendable {
    /// create_folder operations first (one per distinct folder, in date order), then one move per file (by date, then
    /// name). Identifiers are placeholders; the validator assigns the real ones.
    var operations: [PlannedFileOperation]
    /// Matching files without the chosen date, left where they are.
    var skippedFileCount: Int
}

/// The vetted built-in "sort by date into folders": Dotto, not the model, reads every file's real date and writes
/// the moves, so sorting 2,000 files costs one small rule and can't mistype a name.
enum DateFolderRuleExpander {
    static let placeholderOperationIdentifier = "rule-operation"

    private enum FolderNameFormatPart: Equatable {
        case literal(String)
        case year, monthNumber, monthName, dayNumber
    }

    /// For each matching regular file (not hidden, not a folder, extension and type filters, name_contains), picks the
    /// date by `dateSource` (captureDateOrCreated: imageCaptureDate ?? createdAt), formats the folder name in the
    /// environment (only the tokens yyyy MM MMMM dd and literal text; any other letter is an error), capitalizes the
    /// first letter of month names, emits create_folder for each distinct folder (in date order) and one move per file
    /// (sorted by date, then name). Files without the chosen date are left alone and counted.
    static func expand(_ rule: SubmittedDateFolderRule, entries: [FileMetadataRecord],
                       environment: DateFolderNamingEnvironment) -> Result<DateFolderRuleExpansion, FileOperationPlanProblem> {
        let folderNameFormatParts: [FolderNameFormatPart]
        switch parseFolderNameFormat(rule.folderNameFormat) {
        case .success(let parsedParts): folderNameFormatParts = parsedParts
        case .failure(let formatProblem): return .failure(formatProblem)
        }

        let fileFilter = rule.fileFilter
        let matchingEntries = entries.filter { fileFilter.matches($0) }

        var skippedFileCount = 0
        var datedFiles: [(entry: FileMetadataRecord, date: Date, dateWasCaptureDate: Bool)] = []
        for entry in matchingEntries {
            let chosenDate: Date?
            var dateWasCaptureDate = false
            switch rule.dateSource {
            case .captureDateOrCreated:
                dateWasCaptureDate = entry.imageCaptureDate != nil
                chosenDate = entry.imageCaptureDate ?? entry.createdAt
            case .created: chosenDate = entry.createdAt
            case .modified: chosenDate = entry.modifiedAt
            case .added: chosenDate = entry.addedToFolderAt
            }
            guard let chosenDate else {
                skippedFileCount += 1
                continue
            }
            datedFiles.append((entry, chosenDate, dateWasCaptureDate))
        }
        datedFiles.sort { firstFile, secondFile in
            if firstFile.date != secondFile.date { return firstFile.date < secondFile.date }
            return FileOperationPathRules.name(of: firstFile.entry.path) < FileOperationPathRules.name(of: secondFile.entry.path)
        }

        let dayFormatter = makeFormatter(pattern: "yyyy-MM-dd", environment: environment, locale: environment.digitsLocale)
        let folderNameFormatters = FolderNameFormatters(environment: environment)
        var folderPathsInDateOrder: [String] = []
        var seenFolderCollisionKeys: Set<String> = []
        var moveOperations: [PlannedFileOperation] = []
        for datedFile in datedFiles {
            let folderName = formattedFolderName(folderNameFormatParts, date: datedFile.date, formatters: folderNameFormatters)
            if let nameProblem = FileOperationPathRules.validateNewName(folderName, sourceName: nil) {
                return .failure(FileOperationPlanProblem(kind: .invalidName, operationIndex: nil,
                                                         descriptionForModel: "date_folder_rules folder_name_format: \(nameProblem)"))
            }
            let folderPath = (rule.destinationParentFolderPath as NSString).appendingPathComponent(folderName)
            if seenFolderCollisionKeys.insert(FileOperationPathRules.collisionKey(forPath: folderPath)).inserted {
                folderPathsInDateOrder.append(folderPath)
            }
            let fileName = FileOperationPathRules.name(of: datedFile.entry.path)
            let reasonPrefix: String
            switch rule.dateSource {
            case .captureDateOrCreated: reasonPrefix = datedFile.dateWasCaptureDate ? "Taken" : "Created"
            case .created: reasonPrefix = "Created"
            case .modified: reasonPrefix = "Modified"
            case .added: reasonPrefix = "Added"
            }
            moveOperations.append(PlannedFileOperation(
                operationIdentifier: placeholderOperationIdentifier, kind: .move, sourcePath: datedFile.entry.path,
                destinationPath: (folderPath as NSString).appendingPathComponent(fileName), tags: nil,
                reason: "\(reasonPrefix) \(dayFormatter.string(from: datedFile.date))", groupIdentifier: rule.groupIdentifier))
        }
        let createFolderOperations = folderPathsInDateOrder.map { folderPath in
            PlannedFileOperation(operationIdentifier: placeholderOperationIdentifier, kind: .createFolder, sourcePath: nil,
                                 destinationPath: folderPath, tags: nil, reason: "Folder for these dates",
                                 groupIdentifier: rule.groupIdentifier)
        }
        return .success(DateFolderRuleExpansion(operations: createFolderOperations + moveOperations, skippedFileCount: skippedFileCount))
    }

    private static func parseFolderNameFormat(_ folderNameFormat: String) -> Result<[FolderNameFormatPart], FileOperationPlanProblem> {
        var parts: [FolderNameFormatPart] = []
        var remainingFormat = Substring(folderNameFormat)
        func appendLiteral(_ literalText: String) {
            if case .literal(let previousText) = parts.last {
                parts[parts.count - 1] = .literal(previousText + literalText)
            } else {
                parts.append(.literal(literalText))
            }
        }
        while let nextCharacter = remainingFormat.first {
            if remainingFormat.hasPrefix("yyyy") {
                parts.append(.year)
                remainingFormat = remainingFormat.dropFirst(4)
            } else if remainingFormat.hasPrefix("MMMM") {
                parts.append(.monthName)
                remainingFormat = remainingFormat.dropFirst(4)
            } else if remainingFormat.hasPrefix("MM") {
                parts.append(.monthNumber)
                remainingFormat = remainingFormat.dropFirst(2)
            } else if remainingFormat.hasPrefix("dd") {
                parts.append(.dayNumber)
                remainingFormat = remainingFormat.dropFirst(2)
            } else if nextCharacter.isASCII && nextCharacter.isLetter {
                return .failure(FileOperationPlanProblem(
                    kind: .invalidName, operationIndex: nil,
                    descriptionForModel: "date_folder_rules folder_name_format “\(folderNameFormat)” uses “\(nextCharacter)”; only the tokens yyyy, MM, MMMM and dd and non-letter text are allowed."))
            } else {
                appendLiteral(String(nextCharacter))
                remainingFormat = remainingFormat.dropFirst()
            }
        }
        let hasDateToken = parts.contains { part in
            if case .literal = part { return false }
            return true
        }
        guard hasDateToken else {
            return .failure(FileOperationPlanProblem(kind: .invalidName, operationIndex: nil,
                                                     descriptionForModel: "date_folder_rules folder_name_format needs at least one date token (yyyy, MM, MMMM or dd)."))
        }
        return .success(parts)
    }

    /// Made once per expansion: creating a DateFormatter per file would dominate a 2,000-file rule.
    private struct FolderNameFormatters {
        let yearFormatter: DateFormatter
        let monthNumberFormatter: DateFormatter
        let dayNumberFormatter: DateFormatter
        let monthNameFormatter: DateFormatter
        let locale: Locale

        init(environment: DateFolderNamingEnvironment) {
            yearFormatter = DateFolderRuleExpander.makeFormatter(pattern: "yyyy", environment: environment, locale: environment.digitsLocale)
            monthNumberFormatter = DateFolderRuleExpander.makeFormatter(pattern: "MM", environment: environment, locale: environment.digitsLocale)
            dayNumberFormatter = DateFolderRuleExpander.makeFormatter(pattern: "dd", environment: environment, locale: environment.digitsLocale)
            monthNameFormatter = DateFolderRuleExpander.makeFormatter(pattern: "MMMM", environment: environment, locale: environment.locale)
            locale = environment.locale
        }
    }

    private static func formattedFolderName(_ parts: [FolderNameFormatPart], date: Date, formatters: FolderNameFormatters) -> String {
        parts.map { part in
            switch part {
            case .literal(let literalText): return literalText
            case .year: return formatters.yearFormatter.string(from: date)
            case .monthNumber: return formatters.monthNumberFormatter.string(from: date)
            case .dayNumber: return formatters.dayNumberFormatter.string(from: date)
            case .monthName:
                let monthName = formatters.monthNameFormatter.string(from: date)
                guard let firstCharacter = monthName.first else { return monthName }
                return String(firstCharacter).uppercased(with: formatters.locale) + monthName.dropFirst()
            }
        }.joined()
    }

    static func makeFormatter(pattern: String, environment: DateFolderNamingEnvironment, locale: Locale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = environment.calendar
        formatter.locale = locale
        formatter.timeZone = environment.timeZone
        formatter.dateFormat = pattern
        return formatter
    }
}
