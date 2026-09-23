import Foundation

/// What a Finder script says about files: the places it names (POSIX and HFS paths, `~`, Finder's special
/// locations) and the file verbs it uses. A Finder script can reach any file the user can, so one that names a place
/// outside the task's scope folders, or works on files without naming any place inside them (Finder's selection or
/// front window), asks first and shows those places.
struct ScriptFileReferenceFindings: Equatable, Sendable {
    /// As written in the script ("/Users/me/.ssh", "path to desktop"), in order, without repeats.
    var placesOutsideScope: [String]
    var placesInsideScope: [String]
    /// Lowercased, in order, without repeats ("move", "duplicate").
    var fileVerbs: [String]
}

enum ScriptFileReferenceInspector {
    static let finderBundleIdentifier = "com.apple.finder"
    static let maximumNamedPlaceCount = 5

    /// Finder verbs that open, read or change files.
    static let fileVerbs = ["duplicate", "move", "delete", "open", "read", "write", "make", "eject", "erase", "reveal"]

    /// Finder's special locations (AppleScript `path to …` and object words, JXA properties), with the path each means.
    /// A path starting with "~" is under the home folder.
    private static let specialLocationPatterns: [(pattern: String, path: String)] = [
        (#"\bpath\s+to\s+(?:the\s+)?desktop(?:\s+folder)?\b"#, "~/Desktop"),
        (#"\bpath\s+to\s+(?:the\s+)?documents\s+folder\b"#, "~/Documents"),
        (#"\bpath\s+to\s+(?:the\s+)?downloads\s+folder\b"#, "~/Downloads"),
        (#"\bpath\s+to\s+(?:the\s+)?pictures\s+folder\b"#, "~/Pictures"),
        (#"\bpath\s+to\s+(?:the\s+)?movies\s+folder\b"#, "~/Movies"),
        (#"\bpath\s+to\s+(?:the\s+)?music\s+folder\b"#, "~/Music"),
        (#"\bpath\s+to\s+(?:the\s+)?(?:home\s+folder|current\s+user\s+folder)\b"#, "~"),
        (#"\bpath\s+to\s+(?:the\s+)?(?:library|preferences|application\s+support|startup\s+disk|system|applications|temporary\s+items|trash)(?:\s+folder)?\b"#, "/"),
        (#"\bpath\s+to\b"#, "/"),
        (#"\bof\s+(?:the\s+)?desktop\b"#, "~/Desktop"),
        (#"\bof\s+(?:the\s+)?home\b"#, "~"),
        (#"\bof\s+(?:the\s+)?startup\s+disk\b"#, "/"),
        (#"\bof\s+(?:the\s+)?computer\s+container\b"#, "/"),
        (#"\.desktop\b"#, "~/Desktop"),
        (#"\.home\b"#, "~"),
        (#"\.startupdisk\b"#, "/"),
    ]

    static func findings(source: String, scope: DirectRouteScope, homeDirectoryPath: String) -> ScriptFileReferenceFindings {
        var placesOutsideScope: [String] = []
        var placesInsideScope: [String] = []
        func classify(writtenPlace: String, absolutePath: String) {
            if isInsideScope(absolutePath, scope: scope, homeDirectoryPath: homeDirectoryPath) {
                if !placesInsideScope.contains(writtenPlace) { placesInsideScope.append(writtenPlace) }
            } else if !placesOutsideScope.contains(writtenPlace) {
                placesOutsideScope.append(writtenPlace)
            }
        }

        for literalText in stringLiterals(in: source) {
            if let absolutePath = absolutePath(ofWrittenPath: literalText, homeDirectoryPath: homeDirectoryPath) {
                classify(writtenPlace: literalText, absolutePath: absolutePath)
            }
        }
        let lowercasedCollapsedSource = source.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
        var matchedSpecialRanges: [Range<String.Index>] = []
        for specialLocationPattern in specialLocationPatterns {
            for matchedRange in matchRanges(of: specialLocationPattern.pattern, in: lowercasedCollapsedSource)
            where !matchedSpecialRanges.contains(where: { $0.overlaps(matchedRange) }) {
                matchedSpecialRanges.append(matchedRange)
                let absolutePath = expandingHome(in: specialLocationPattern.path, homeDirectoryPath: homeDirectoryPath)
                classify(writtenPlace: String(lowercasedCollapsedSource[matchedRange]), absolutePath: absolutePath)
            }
        }

        var foundFileVerbs: [String] = []
        for fileVerb in fileVerbs where !matchRanges(of: #"\b"# + fileVerb + #"\b"#, in: lowercasedCollapsedSource).isEmpty {
            foundFileVerbs.append(fileVerb)
        }
        return ScriptFileReferenceFindings(placesOutsideScope: placesOutsideScope, placesInsideScope: placesInsideScope,
                                           fileVerbs: foundFileVerbs)
    }

    /// For a Finder script only: why it needs the user's go-ahead, naming the places, or nil when it stays in scope.
    static func confirmationReason(for scriptPlan: ScriptPlan, homeDirectoryPath: String) -> String? {
        guard scriptPlan.targetBundleIdentifier.lowercased() == finderBundleIdentifier else { return nil }
        let scope = scriptPlan.fileScope ?? .empty
        let scriptFindings = findings(source: scriptPlan.source, scope: scope, homeDirectoryPath: homeDirectoryPath)
        if !scriptFindings.placesOutsideScope.isEmpty {
            let namedPlaces = scriptFindings.placesOutsideScope.prefix(maximumNamedPlaceCount).map { "“\($0)”" }
            let moreCount = scriptFindings.placesOutsideScope.count - namedPlaces.count
            let placesText = namedPlaces.joined(separator: ", ") + (moreCount > 0 ? " and \(moreCount) more" : "")
            let scopeText = scope.roots.isEmpty ? "you didn't give Dotto a folder for this task"
                : "outside the folders you gave Dotto"
            return "This Finder script names places \(scopeText): \(placesText). It can reach any file there."
        }
        if !scriptFindings.fileVerbs.isEmpty && scriptFindings.placesInsideScope.isEmpty {
            let verbsText = scriptFindings.fileVerbs.prefix(maximumNamedPlaceCount).map { "“\($0)”" }.joined(separator: ", ")
            return "This Finder script uses \(verbsText) without naming a folder you gave Dotto, so it works on whatever "
                + "Finder shows or has selected when it runs."
        }
        return nil
    }

    // MARK: - Reading the source

    /// Double-quoted literals (both languages, with backslash escapes), plus single-quoted and backtick literals, which
    /// only JXA has; an AppleScript apostrophe in a comment may pair up oddly, which only adds places (fails closed).
    static func stringLiterals(in source: String) -> [String] {
        var literals: [String] = []
        var characterIndex = source.startIndex
        while characterIndex < source.endIndex {
            let openingCharacter = source[characterIndex]
            guard openingCharacter == "\"" || openingCharacter == "'" || openingCharacter == "`" else {
                characterIndex = source.index(after: characterIndex)
                continue
            }
            var literalText = ""
            var scanIndex = source.index(after: characterIndex)
            var foundClosingQuote = false
            while scanIndex < source.endIndex {
                let scannedCharacter = source[scanIndex]
                if scannedCharacter == "\\", source.index(after: scanIndex) < source.endIndex {
                    literalText.append(source[source.index(after: scanIndex)])
                    scanIndex = source.index(scanIndex, offsetBy: 2)
                    continue
                }
                if scannedCharacter == openingCharacter { foundClosingQuote = true; break }
                if scannedCharacter.isNewline && openingCharacter != "`" { break }
                literalText.append(scannedCharacter)
                scanIndex = source.index(after: scanIndex)
            }
            if foundClosingQuote {
                literals.append(literalText)
                characterIndex = source.index(after: scanIndex)
            } else {
                characterIndex = source.index(after: characterIndex)
            }
        }
        return literals
    }

    /// "/…" and "~/…" as they are, and HFS paths ("Macintosh HD:Users:me:Desktop:") as POSIX: a first component
    /// followed by "Users", "Applications", "Library", "System" or "Volumes" is taken to be the startup disk, any other
    /// first component a volume under /Volumes. nil for text that isn't a path (URLs included).
    static func absolutePath(ofWrittenPath writtenPath: String, homeDirectoryPath: String) -> String? {
        let trimmedPath = writtenPath.trimmingCharacters(in: .whitespaces)
        if trimmedPath.hasPrefix("/") { return trimmedPath }
        if trimmedPath == "~" || trimmedPath.hasPrefix("~/") { return expandingHome(in: trimmedPath, homeDirectoryPath: homeDirectoryPath) }
        guard !trimmedPath.contains("://"), trimmedPath.contains(":"), !trimmedPath.hasPrefix(":") else { return nil }
        let hfsComponents = trimmedPath.split(separator: ":", omittingEmptySubsequences: true).map(String.init)
        // A colon in prose ("Note: done") has a space after it, and a time ("10:30") is all digits; an HFS path is neither.
        guard let volumeName = hfsComponents.first, hfsComponents.count > 1 || trimmedPath.hasSuffix(":"),
              !trimmedPath.contains(": "),
              !hfsComponents.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }
        let startupDiskFolderNames: Set<String> = ["Users", "Applications", "Library", "System", "Volumes", "private"]
        let remainingComponents = Array(hfsComponents.dropFirst())
        if let firstRemainingComponent = remainingComponents.first, startupDiskFolderNames.contains(firstRemainingComponent) {
            return "/" + remainingComponents.joined(separator: "/")
        }
        return (["/Volumes", volumeName] + remainingComponents).joined(separator: "/")
    }

    private static func isInsideScope(_ absolutePath: String, scope: DirectRouteScope, homeDirectoryPath: String) -> Bool {
        let normalizedPath = UploadFileAllowlist.normalizedPath(absolutePath)
        let trimmedPath = normalizedPath.count > 1 && normalizedPath.hasSuffix("/") ? String(normalizedPath.dropLast()) : normalizedPath
        guard let pathComponents = FileOperationScopePolicy.normalizedComponents(ofCanonicalPath: trimmedPath) else { return false }
        if ProtectedPathPolicy.isProtected(normalizedPathComponents: pathComponents, homeDirectoryPath: homeDirectoryPath)
            || ProtectedPathPolicy.isHomeLibraryFolder(normalizedPathComponents: pathComponents, homeDirectoryPath: homeDirectoryPath) {
            return false
        }
        return scope.roots.contains { root in
            guard let rootComponents = FileOperationScopePolicy.normalizedComponents(
                ofCanonicalPath: UploadFileAllowlist.normalizedPath(root.canonicalPath)) else { return false }
            return FileOperationScopePolicy.isComponentList(pathComponents, equalToOrInside: rootComponents)
        }
    }

    private static func expandingHome(in path: String, homeDirectoryPath: String) -> String {
        if path == "~" { return homeDirectoryPath }
        guard path.hasPrefix("~/") else { return path }
        return (homeDirectoryPath as NSString).appendingPathComponent(String(path.dropFirst(2)))
    }

    private static func matchRanges(of pattern: String, in text: String) -> [Range<String.Index>] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text) }
    }
}
