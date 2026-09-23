import Foundation

/// Folder paths in text the user typed (the command, or a reply to the planner's question). The owner decided typed
/// paths grant file-operation scope, unlike uploads. Only the user's own text is ever passed here, never model or
/// screen text. Returns raw candidates: Platform canonicalizes them, keeps existing folders, and
/// FileOperationScopePolicy decides which become roots.
enum CommandPathExtractor {
    /// English and Spanish names of the standard home folders, mapped to their folder under the home folder.
    static let wellKnownFolderNameByLowercasedWord: [String: String] = [
        "desktop": "Desktop", "escritorio": "Desktop",
        "documents": "Documents", "documentos": "Documents",
        "downloads": "Downloads", "descargas": "Downloads",
        "pictures": "Pictures", "imágenes": "Pictures", "imagenes": "Pictures",
        "movies": "Movies", "películas": "Movies", "peliculas": "Movies",
        "music": "Music", "música": "Music", "musica": "Music",
    ]

    /// A well-known folder word counts only next to one of these ("my Downloads folder", "la carpeta Descargas"), so a
    /// bare noun ("move the documents", "fotos de descargas") never widens the scope.
    static let folderWords: Set<String> = ["folder", "directory", "carpeta", "directorio"]
    /// Words allowed between a folder word and the name ("the folder of Downloads", "la carpeta del Escritorio").
    private static let connectorWords: Set<String> = ["de", "del", "of", "the", "my", "mi", "la", "el", "called", "named", "llamada"]

    private static let quotePairs: [(opening: Character, closing: Character)] = [
        ("\"", "\""), ("'", "'"), ("“", "”"), ("‘", "’"), ("«", "»"),
    ]
    private static let trailingPunctuation = CharacterSet(charactersIn: ".,;:!?)]}\"'”’»")

    /// Absolute ("/…"), home-relative ("~/…") and quoted paths, plus well-known folders (Desktop/Escritorio,
    /// Documents/Documentos, Downloads/Descargas, Pictures/Imágenes, Movies/Películas, Music/Música) mapped under the
    /// home folder when the name is quoted or named as a folder ("Downloads folder", "carpeta de Descargas").
    static func candidateFolderPaths(inUserText userText: String, homeDirectoryPath: String) -> [String] {
        var candidatePaths: [String] = []
        func addCandidate(_ rawPath: String) {
            var expandedPath = expandingHome(in: rawPath, homeDirectoryPath: homeDirectoryPath)
            while expandedPath.count > 1 && expandedPath.hasSuffix("/") { expandedPath.removeLast() }
            guard expandedPath.hasPrefix("/"), expandedPath.count > 1, !candidatePaths.contains(expandedPath) else { return }
            candidatePaths.append(expandedPath)
        }

        let quotedRanges = quotedTextRanges(in: userText)
        for quotedRange in quotedRanges {
            let quotedText = String(userText[quotedRange]).trimmingCharacters(in: .whitespaces)
            if quotedText.hasPrefix("/") || quotedText.hasPrefix("~/") { addCandidate(quotedText) }
            if let wellKnownFolderName = wellKnownFolderNameByLowercasedWord[quotedText.lowercased()] {
                addCandidate((homeDirectoryPath as NSString).appendingPathComponent(wellKnownFolderName))
            }
        }

        var characterIndex = userText.startIndex
        while characterIndex < userText.endIndex {
            let isInsideQuotes = quotedRanges.contains { $0.contains(characterIndex) }
            let previousCharacter = characterIndex > userText.startIndex ? userText[userText.index(before: characterIndex)] : nil
            let startsAtWordBoundary = previousCharacter == nil || previousCharacter?.isWhitespace == true
                || previousCharacter.map { "(\"'“‘«".contains($0) } == true
            let remainingText = userText[characterIndex...]
            if !isInsideQuotes, startsAtWordBoundary, remainingText.hasPrefix("/") || remainingText.hasPrefix("~/") {
                let (unquotedPath, pathEndIndex) = unquotedPathToken(in: userText, from: characterIndex)
                addCandidate(unquotedPath)
                characterIndex = pathEndIndex
                continue
            }
            characterIndex = userText.index(after: characterIndex)
        }

        // Words outside paths only: "~/Desktop/x" names the folder x, not the Desktop.
        let lowercasedWords = textOutsidePathTokens(userText).lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
        for (wordIndex, lowercasedWord) in lowercasedWords.enumerated() {
            guard let wellKnownFolderName = wellKnownFolderNameByLowercasedWord[lowercasedWord],
                  isNamedAsFolder(wordIndex: wordIndex, lowercasedWords: lowercasedWords) else { continue }
            addCandidate((homeDirectoryPath as NSString).appendingPathComponent(wellKnownFolderName))
        }
        return candidatePaths
    }

    /// "Downloads folder", "folder Downloads", "carpeta de Descargas", "the folder called Downloads".
    private static func isNamedAsFolder(wordIndex: Int, lowercasedWords: [String]) -> Bool {
        if wordIndex + 1 < lowercasedWords.count, folderWords.contains(lowercasedWords[wordIndex + 1]) { return true }
        var previousIndex = wordIndex - 1
        var skippedConnectorCount = 0
        while previousIndex >= 0 {
            let previousWord = lowercasedWords[previousIndex]
            if folderWords.contains(previousWord) { return true }
            guard connectorWords.contains(previousWord), skippedConnectorCount < 2 else { return false }
            skippedConnectorCount += 1
            previousIndex -= 1
        }
        return false
    }

    /// The text with every "/…" and "~/…" token blanked out.
    private static func textOutsidePathTokens(_ userText: String) -> String {
        userText.split(separator: " ", omittingEmptySubsequences: false)
            .map { word in
                let trimmedWord = word.drop { "(\"'“‘«".contains($0) }
                return trimmedWord.hasPrefix("/") || trimmedWord.hasPrefix("~/") ? "" : String(word)
            }
            .joined(separator: " ")
    }

    /// The text between each pair of matching quotes, outermost first.
    private static func quotedTextRanges(in userText: String) -> [Range<String.Index>] {
        var quotedRanges: [Range<String.Index>] = []
        var searchIndex = userText.startIndex
        while searchIndex < userText.endIndex {
            let character = userText[searchIndex]
            let apostropheInsideWord = character == "'" || character == "’"
            let previousCharacter = searchIndex > userText.startIndex ? userText[userText.index(before: searchIndex)] : nil
            if let quotePair = quotePairs.first(where: { $0.opening == character }),
               !(apostropheInsideWord && previousCharacter?.isLetter == true),
               let closingIndex = userText[userText.index(after: searchIndex)...].firstIndex(of: quotePair.closing) {
                quotedRanges.append(userText.index(after: searchIndex)..<closingIndex)
                searchIndex = userText.index(after: closingIndex)
                continue
            }
            searchIndex = userText.index(after: searchIndex)
        }
        return quotedRanges
    }

    /// Up to the first unescaped whitespace; "My\ Folder" keeps its space. Trailing sentence punctuation is dropped.
    private static func unquotedPathToken(in userText: String, from startIndex: String.Index) -> (path: String, endIndex: String.Index) {
        var pathCharacters = ""
        var characterIndex = startIndex
        while characterIndex < userText.endIndex {
            let character = userText[characterIndex]
            if character == "\\", userText.index(after: characterIndex) < userText.endIndex,
               userText[userText.index(after: characterIndex)] == " " {
                pathCharacters.append(" ")
                characterIndex = userText.index(characterIndex, offsetBy: 2)
                continue
            }
            if character.isWhitespace { break }
            pathCharacters.append(character)
            characterIndex = userText.index(after: characterIndex)
        }
        while let lastScalar = pathCharacters.unicodeScalars.last, trailingPunctuation.contains(lastScalar), pathCharacters.count > 1 {
            pathCharacters.removeLast()
        }
        return (pathCharacters, characterIndex)
    }

    private static func expandingHome(in rawPath: String, homeDirectoryPath: String) -> String {
        guard rawPath.hasPrefix("~/") else { return rawPath }
        return (homeDirectoryPath as NSString).appendingPathComponent(String(rawPath.dropFirst(2)))
    }
}
