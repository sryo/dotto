import Foundation

enum AuditLogEventKind: String, Codable, Sendable {
    case taskStarted, checklistRequested, modelResponse, checklistProduced, checklistApproved, itemStarted, toolCall, toolResult,
         safetyDecision, userConfirmation, itemFinished, taskFinished, taskAborted, error,
         pause, resume, verification, retry, replayStep, replayFallback, routineSaved, demonstration,
         routineReadyForReview, foregroundAssist, takeoverWatch,
         fileOperation, directRouteValidation, scriptRun, shortcutRun, undo
}

struct AuditLogEntry: Codable, Equatable, Sendable {
    var timestamp: Date
    var taskIdentifier: String
    var itemIdentifier: String?
    var eventKind: AuditLogEventKind
    var message: String
    var details: [String: String]
}

final class AuditLogWriter: @unchecked Sendable {
    static var defaultLogsDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Dotto", isDirectory: true)
    }

    static let maximumDetailValueLength = 500
    static let maximumMessageLength = 500
    static let minimumRedactedTextLength = 4

    let logFileURL: URL
    private let taskIdentifier: String
    private let logFileHandle: FileHandle
    private let writeLock = NSLock()
    private var typedTextsToRedact: Set<String> = []
    private let entryEncoder: JSONEncoder = {
        let encoder = CanonicalJSONEncoding.makeEncoder()
        encoder.dateEncodingStrategy = .custom { date, dateEncoder in
            let timestampFormatter = ISO8601DateFormatter()
            timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var singleValueContainer = dateEncoder.singleValueContainer()
            try singleValueContainer.encode(timestampFormatter.string(from: date))
        }
        return encoder
    }()

    init(taskIdentifier: String, logsDirectoryURL: URL = AuditLogWriter.defaultLogsDirectoryURL) throws {
        self.taskIdentifier = taskIdentifier
        // Logs describe what the user did in their apps, so only the user's own account may read them.
        try FileManager.default.createDirectory(at: logsDirectoryURL, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: logsDirectoryURL.path)
        logFileURL = logsDirectoryURL.appendingPathComponent("\(taskIdentifier).jsonl")
        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logFileURL.path)
        logFileHandle = try FileHandle(forWritingTo: logFileURL)
        try logFileHandle.seekToEnd()
    }

    /// Registers text Dotto typed so every later entry replaces it with its fingerprint. This catches the
    /// typed text wherever it resurfaces: a field value in an outline, a model's finish_item summary, and so on.
    func registerTypedTextForRedaction(_ typedText: String) {
        let trimmedTypedText = typedText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Very short strings ("a", "42") would shred unrelated text, and reveal little on their own.
        guard trimmedTypedText.count >= AuditLogWriter.minimumRedactedTextLength else { return }
        writeLock.lock()
        defer { writeLock.unlock() }
        typedTextsToRedact.insert(trimmedTypedText)
    }

    deinit {
        try? logFileHandle.close()
    }

    func append(_ entry: AuditLogEntry) {
        writeLock.lock()
        defer { writeLock.unlock() }
        // Redact before truncating so a typed string cut in half by truncation can't slip through.
        var truncatedEntry = entry
        truncatedEntry.message = Self.truncated(redactingTypedTexts(in: entry.message), toLength: Self.maximumMessageLength)
        truncatedEntry.details = entry.details.mapValues { detailValue in
            Self.truncated(redactingTypedTexts(in: detailValue), toLength: Self.maximumDetailValueLength)
        }
        do {
            var encodedLine = try entryEncoder.encode(truncatedEntry)
            encodedLine.append(0x0A)
            try logFileHandle.write(contentsOf: encodedLine)
        } catch {
            // The audit log must never interrupt a running task, so failures only go to stderr.
            FileHandle.standardError.write(Data("Dotto audit log write failed: \(error)\n".utf8))
        }
    }

    func append(eventKind: AuditLogEventKind, itemIdentifier: String?, message: String, details: [String: String]) {
        append(AuditLogEntry(timestamp: Date(), taskIdentifier: taskIdentifier, itemIdentifier: itemIdentifier,
                             eventKind: eventKind, message: message, details: details))
    }

    private func redactingTypedTexts(in text: String) -> String {
        // Longest first, so a typed string that contains another typed string is replaced whole.
        typedTextsToRedact.sorted { $0.count > $1.count }.reduce(text) { partiallyRedactedText, typedText in
            partiallyRedactedText.replacingOccurrences(of: typedText, with: AuditLogRedaction.fingerprint(of: typedText))
        }
    }

    private static func truncated(_ text: String, toLength maximumLength: Int) -> String {
        text.count > maximumLength ? String(text.prefix(maximumLength)) + "…" : text
    }
}

enum AuditLogRedaction {
    /// e.g. "[typed sha256:9f86d081884c len=4]": enough to tell two typed values apart or match one against a
    /// known value, without storing the text itself.
    static func fingerprint(of sensitiveText: String) -> String {
        let hexDigest = SHA256Digest.hexDigest(of: Data(sensitiveText.utf8))
        return "[typed sha256:\(hexDigest.prefix(12)) len=\(sensitiveText.count)]"
    }
}
