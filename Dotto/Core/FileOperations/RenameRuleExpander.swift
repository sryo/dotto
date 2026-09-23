import Foundation

extension SubmittedRenameRule {
    var fileFilter: FileRuleFileFilter {
        FileRuleFileFilter(sourceFolderPath: sourceFolderPath, nameContains: nameContains,
                           lowercasedExtensions: lowercasedExtensions, typeIdentifiers: typeIdentifiers)
    }
}

struct RenameRuleExpansion: Equatable, Sendable {
    /// One rename per file whose name changes, in the rule's order. Identifiers are placeholders; the validator
    /// assigns the real ones.
    var operations: [PlannedFileOperation]
    /// Matching files without a value the rule needs (a date, a pixel size, a file size); they keep their names.
    var skippedFileCount: Int
    /// What the skipped files lacked, e.g. "a pixel size", for the note to the model; nil when none were skipped.
    var skippedFilesLackedDescription: String?
}

/// The vetted built-in "rename by a pattern": Dotto, not the model, reads every file's real metadata and writes the
/// renames, so numbering 2,000 photos costs one small rule instead of 2,000 hand-written operations.
///
/// Template tokens (anything else in braces is an error, and so is an unmatched brace):
/// - `{name}`: the original name without its extension; `{ext}`: the original extension without the dot
/// - `{n}`, `{n:3}`: the file's 1-based position in the rule's order, zero-padded to the width (1-6)
/// - `{width}`, `{height}`: pixel size; `{size_kb}`: file size in whole kB; `{size_mb}`: in MB with one decimal
///   (1 kB = 1,000 bytes, like Finder)
/// - `{date:yyyy-MM-dd}`: the `date_source` date, with only the tokens yyyy, MM and dd and non-letter text
/// The original extension is appended automatically unless the template contains `{ext}`, which places it instead.
enum RenameRuleExpander {
    static let placeholderOperationIdentifier = "rule-operation"
    static let maximumSequenceNumberWidth = 6

    enum DateFormatPart: Equatable, Sendable {
        case literal(String)
        case year, monthNumber, dayNumber
    }

    enum NameTemplatePart: Equatable, Sendable {
        case literal(String)
        case originalName, originalExtension
        case sequenceNumber(width: Int)
        case pixelWidth, pixelHeight
        case sizeInKilobytes, sizeInMegabytes
        case date([DateFormatPart])
    }

    /// For each matching file (see `FileRuleFileFilter`), orders by `order` (dates oldest first, ties by name; names in
    /// Finder's order), reversed when descending; skips and counts files missing the order's date or any value the
    /// template uses; numbers the rest from 1; expands the template; validates each new name; and drops files whose
    /// name wouldn't change.
    static func expand(_ rule: SubmittedRenameRule, entries: [FileMetadataRecord],
                       environment: DateFolderNamingEnvironment) -> Result<RenameRuleExpansion, FileOperationPlanProblem> {
        let templateParts: [NameTemplatePart]
        switch parseNameTemplate(rule.nameTemplate) {
        case .success(let parsedParts): templateParts = parsedParts
        case .failure(let templateProblem): return .failure(templateProblem)
        }
        let templateUsesDate = templateParts.contains { part in
            if case .date = part { return true }
            return false
        }
        let templateUsesPixelSize = templateParts.contains { $0 == .pixelWidth || $0 == .pixelHeight }
        let templateUsesFileSize = templateParts.contains { $0 == .sizeInKilobytes || $0 == .sizeInMegabytes }
        let templatePlacesExtension = templateParts.contains(.originalExtension)
        if templateUsesDate && rule.dateSource == nil {
            return .failure(templateProblem(rule.nameTemplate, "uses {date:…}, so set date_source."))
        }

        let fileFilter = rule.fileFilter
        var skippedFileCount = 0
        var lackedValueDescriptions: [String] = []
        func noteSkipped(lacking lackedValueDescription: String) {
            skippedFileCount += 1
            if !lackedValueDescriptions.contains(lackedValueDescription) { lackedValueDescriptions.append(lackedValueDescription) }
        }

        var orderedFiles: [(entry: FileMetadataRecord, orderDate: Date?, orderDateWasCaptureDate: Bool)] = []
        for entry in entries where fileFilter.matches(entry) {
            var orderDate: Date?
            var orderDateWasCaptureDate = false
            if rule.order != .name {
                (orderDate, orderDateWasCaptureDate) = chosenDate(of: entry, order: rule.order)
                if orderDate == nil {
                    noteSkipped(lacking: "a date")
                    continue
                }
            }
            if templateUsesDate, let dateSource = rule.dateSource, chosenDate(of: entry, dateSource: dateSource) == nil {
                noteSkipped(lacking: "a date")
                continue
            }
            if templateUsesPixelSize && (entry.imagePixelWidth == nil || entry.imagePixelHeight == nil) {
                noteSkipped(lacking: "a pixel size")
                continue
            }
            if templateUsesFileSize && entry.sizeInBytes == nil {
                noteSkipped(lacking: "a file size")
                continue
            }
            orderedFiles.append((entry, orderDate, orderDateWasCaptureDate))
        }
        orderedFiles.sort { firstFile, secondFile in
            if let firstDate = firstFile.orderDate, let secondDate = secondFile.orderDate, firstDate != secondDate {
                return firstDate < secondDate
            }
            return fileNameIsOrderedBefore(FileOperationPathRules.name(of: firstFile.entry.path),
                                           FileOperationPathRules.name(of: secondFile.entry.path))
        }
        if rule.isDescending { orderedFiles.reverse() }

        let dayFormatter = DateFolderRuleExpander.makeFormatter(pattern: "yyyy-MM-dd", environment: environment,
                                                                locale: environment.digitsLocale)
        let dateTokenFormatters = DateTokenFormatters(environment: environment)
        var renameOperations: [PlannedFileOperation] = []
        for (fileOffset, orderedFile) in orderedFiles.enumerated() {
            let entry = orderedFile.entry
            let sequenceNumber = fileOffset + 1
            let fileName = FileOperationPathRules.name(of: entry.path)
            let originalExtension = (fileName as NSString).pathExtension
            let originalNameWithoutExtension = originalExtension.isEmpty ? fileName : (fileName as NSString).deletingPathExtension
            let templateDate = rule.dateSource.flatMap { chosenDate(of: entry, dateSource: $0) }

            var expandedName = templateParts.map { part -> String in
                switch part {
                case .literal(let literalText): return literalText
                case .originalName: return originalNameWithoutExtension
                case .originalExtension: return originalExtension
                case .sequenceNumber(let width): return zeroPadded(sequenceNumber, toWidth: width)
                case .pixelWidth: return entry.imagePixelWidth.map(String.init) ?? ""
                case .pixelHeight: return entry.imagePixelHeight.map(String.init) ?? ""
                case .sizeInKilobytes: return entry.sizeInBytes.map(formattedKilobytes) ?? ""
                case .sizeInMegabytes: return entry.sizeInBytes.map(formattedMegabytes) ?? ""
                case .date(let dateFormatParts):
                    guard let templateDate else { return "" }
                    return formattedDate(dateFormatParts, date: templateDate, formatters: dateTokenFormatters)
                }
            }.joined()
            if !templatePlacesExtension && !originalExtension.isEmpty {
                if expandedName.lowercased().hasSuffix("." + originalExtension.lowercased()) {
                    return .failure(templateProblem(rule.nameTemplate,
                        "already ends with “.\(originalExtension)”. The original extension is kept automatically: remove it from the template, or place it with {ext}."))
                }
                expandedName += "." + originalExtension
            }
            if let nameProblem = FileOperationPathRules.validateNewName(expandedName, sourceName: fileName) {
                return .failure(templateProblem(rule.nameTemplate, nameProblem))
            }
            if expandedName == fileName { continue }

            var reasonParts: [String]
            switch rule.order {
            case .name:
                reasonParts = ["#\(sequenceNumber) by name"]
            case .created, .modified, .added, .captureDateOrCreated:
                let dateWord: String
                switch rule.order {
                case .captureDateOrCreated: dateWord = orderedFile.orderDateWasCaptureDate ? "taken" : "created"
                case .modified: dateWord = "modified"
                case .added: dateWord = "added"
                case .created, .name: dateWord = "created"
                }
                reasonParts = ["#\(sequenceNumber)", "\(dateWord) \(orderedFile.orderDate.map(dayFormatter.string(from:)) ?? "-")"]
            }
            if templateUsesPixelSize, let imagePixelWidth = entry.imagePixelWidth, let imagePixelHeight = entry.imagePixelHeight {
                reasonParts.append("\(imagePixelWidth)×\(imagePixelHeight) px")
            }
            if templateUsesFileSize, let sizeInBytes = entry.sizeInBytes {
                reasonParts.append(sizeInBytes >= 1_000_000 ? "\(formattedMegabytes(sizeInBytes)) MB" : "\(formattedKilobytes(sizeInBytes)) kB")
            }
            renameOperations.append(PlannedFileOperation(
                operationIdentifier: placeholderOperationIdentifier, kind: .rename, sourcePath: entry.path,
                destinationPath: (FileOperationPathRules.parentPath(of: entry.path) as NSString).appendingPathComponent(expandedName),
                tags: nil, reason: reasonParts.joined(separator: " · "), groupIdentifier: rule.groupIdentifier))
        }
        return .success(RenameRuleExpansion(
            operations: renameOperations, skippedFileCount: skippedFileCount,
            skippedFilesLackedDescription: lackedValueDescriptions.isEmpty ? nil : lackedValueDescriptions.joined(separator: " or ")))
    }

    // MARK: - Template

    static func parseNameTemplate(_ nameTemplate: String) -> Result<[NameTemplatePart], FileOperationPlanProblem> {
        var parts: [NameTemplatePart] = []
        var pendingLiteralText = ""
        var remainingTemplate = Substring(nameTemplate)
        while let nextCharacter = remainingTemplate.first {
            if nextCharacter == "}" {
                return .failure(templateProblem(nameTemplate, "has a “}” without its “{”."))
            }
            guard nextCharacter == "{" else {
                pendingLiteralText.append(nextCharacter)
                remainingTemplate = remainingTemplate.dropFirst()
                continue
            }
            guard let closingBraceIndex = remainingTemplate.firstIndex(of: "}") else {
                return .failure(templateProblem(nameTemplate, "has a “{” without its “}”."))
            }
            let tokenText = String(remainingTemplate[remainingTemplate.index(after: remainingTemplate.startIndex)..<closingBraceIndex])
            if tokenText.contains("{") {
                return .failure(templateProblem(nameTemplate, "has a “{” inside a token."))
            }
            switch parseToken(tokenText, nameTemplate: nameTemplate) {
            case .success(let tokenPart):
                if !pendingLiteralText.isEmpty {
                    parts.append(.literal(pendingLiteralText))
                    pendingLiteralText = ""
                }
                parts.append(tokenPart)
            case .failure(let tokenProblem):
                return .failure(tokenProblem)
            }
            remainingTemplate = remainingTemplate[remainingTemplate.index(after: closingBraceIndex)...]
        }
        if !pendingLiteralText.isEmpty { parts.append(.literal(pendingLiteralText)) }
        let hasVaryingToken = parts.contains { part in
            switch part {
            case .literal, .originalExtension: return false
            default: return true
            }
        }
        guard hasVaryingToken else {
            return .failure(templateProblem(nameTemplate,
                "needs a token that differs per file: {n}, {name}, {date:…}, {width}, {height}, {size_kb} or {size_mb}."))
        }
        return .success(parts)
    }

    private static func parseToken(_ tokenText: String, nameTemplate: String) -> Result<NameTemplatePart, FileOperationPlanProblem> {
        switch tokenText {
        case "name": return .success(.originalName)
        case "ext": return .success(.originalExtension)
        case "n": return .success(.sequenceNumber(width: 1))
        case "width": return .success(.pixelWidth)
        case "height": return .success(.pixelHeight)
        case "size_kb": return .success(.sizeInKilobytes)
        case "size_mb": return .success(.sizeInMegabytes)
        default: break
        }
        if tokenText.hasPrefix("n:") {
            let widthText = tokenText.dropFirst(2)
            guard !widthText.isEmpty, widthText.allSatisfy({ $0.isASCII && $0.isNumber }), let width = Int(widthText),
                  (1...maximumSequenceNumberWidth).contains(width) else {
                return .failure(templateProblem(nameTemplate, "uses {\(tokenText)}; the width in {n:W} must be 1-\(maximumSequenceNumberWidth)."))
            }
            return .success(.sequenceNumber(width: width))
        }
        if tokenText.hasPrefix("date:") {
            return parseDateFormat(String(tokenText.dropFirst(5)), nameTemplate: nameTemplate).map { .date($0) }
        }
        return .failure(templateProblem(nameTemplate,
            "uses the unknown token {\(tokenText)}. Only {name}, {ext}, {n}, {n:3}, {width}, {height}, {size_kb}, {size_mb} and {date:yyyy-MM-dd} exist."))
    }

    private static func parseDateFormat(_ dateFormat: String, nameTemplate: String) -> Result<[DateFormatPart], FileOperationPlanProblem> {
        var parts: [DateFormatPart] = []
        var remainingFormat = Substring(dateFormat)
        while let nextCharacter = remainingFormat.first {
            if remainingFormat.hasPrefix("yyyy") {
                parts.append(.year)
                remainingFormat = remainingFormat.dropFirst(4)
            } else if remainingFormat.hasPrefix("MM") {
                parts.append(.monthNumber)
                remainingFormat = remainingFormat.dropFirst(2)
            } else if remainingFormat.hasPrefix("dd") {
                parts.append(.dayNumber)
                remainingFormat = remainingFormat.dropFirst(2)
            } else if nextCharacter.isASCII && nextCharacter.isLetter {
                return .failure(templateProblem(nameTemplate,
                    "uses “\(nextCharacter)” in {date:\(dateFormat)}; only yyyy, MM and dd and non-letter text are allowed."))
            } else {
                if case .literal(let previousText) = parts.last {
                    parts[parts.count - 1] = .literal(previousText + String(nextCharacter))
                } else {
                    parts.append(.literal(String(nextCharacter)))
                }
                remainingFormat = remainingFormat.dropFirst()
            }
        }
        let hasDateToken = parts.contains { part in
            if case .literal = part { return false }
            return true
        }
        guard hasDateToken else {
            return .failure(templateProblem(nameTemplate, "has {date:\(dateFormat)} without yyyy, MM or dd."))
        }
        return .success(parts)
    }

    private static func templateProblem(_ nameTemplate: String, _ problemText: String) -> FileOperationPlanProblem {
        FileOperationPlanProblem(kind: .invalidName, operationIndex: nil,
                                 descriptionForModel: "rename_rules name_template “\(nameTemplate)” \(problemText)")
    }

    // MARK: - Values

    private static func chosenDate(of entry: FileMetadataRecord, order: RenameRuleOrder) -> (date: Date?, wasCaptureDate: Bool) {
        switch order {
        case .name: return (nil, false)
        case .created: return (entry.createdAt, false)
        case .modified: return (entry.modifiedAt, false)
        case .added: return (entry.addedToFolderAt, false)
        case .captureDateOrCreated: return (entry.imageCaptureDate ?? entry.createdAt, entry.imageCaptureDate != nil)
        }
    }

    private static func chosenDate(of entry: FileMetadataRecord, dateSource: DateFolderRuleDateSource) -> Date? {
        switch dateSource {
        case .captureDateOrCreated: return entry.imageCaptureDate ?? entry.createdAt
        case .created: return entry.createdAt
        case .modified: return entry.modifiedAt
        case .added: return entry.addedToFolderAt
        }
    }

    /// Finder's order ("IMG_2" before "IMG_10"), with a plain comparison to break ties so the order never depends on
    /// the input order.
    private static func fileNameIsOrderedBefore(_ firstFileName: String, _ secondFileName: String) -> Bool {
        switch firstFileName.localizedStandardCompare(secondFileName) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return firstFileName < secondFileName
        }
    }

    private static func zeroPadded(_ number: Int, toWidth width: Int) -> String {
        let digits = String(number)
        return digits.count >= width ? digits : String(repeating: "0", count: width - digits.count) + digits
    }

    private static func formattedKilobytes(_ sizeInBytes: Int64) -> String {
        String(Int64((Double(sizeInBytes) / 1_000).rounded()))
    }

    /// One decimal with a "." whatever the user's language (String(format:) doesn't localize).
    private static func formattedMegabytes(_ sizeInBytes: Int64) -> String {
        String(format: "%.1f", Double(sizeInBytes) / 1_000_000)
    }

    /// Made once per expansion: creating a DateFormatter per file would dominate a 2,000-file rule.
    private struct DateTokenFormatters {
        let yearFormatter: DateFormatter
        let monthNumberFormatter: DateFormatter
        let dayNumberFormatter: DateFormatter

        init(environment: DateFolderNamingEnvironment) {
            yearFormatter = DateFolderRuleExpander.makeFormatter(pattern: "yyyy", environment: environment, locale: environment.digitsLocale)
            monthNumberFormatter = DateFolderRuleExpander.makeFormatter(pattern: "MM", environment: environment, locale: environment.digitsLocale)
            dayNumberFormatter = DateFolderRuleExpander.makeFormatter(pattern: "dd", environment: environment, locale: environment.digitsLocale)
        }
    }

    private static func formattedDate(_ parts: [DateFormatPart], date: Date, formatters: DateTokenFormatters) -> String {
        parts.map { part in
            switch part {
            case .literal(let literalText): return literalText
            case .year: return formatters.yearFormatter.string(from: date)
            case .monthNumber: return formatters.monthNumberFormatter.string(from: date)
            case .dayNumber: return formatters.dayNumberFormatter.string(from: date)
            }
        }.joined()
    }
}
