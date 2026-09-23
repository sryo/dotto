import Foundation

struct FileOperationJournalEntry: Codable, Equatable, Sendable {
    var operationIdentifier: String
    var kind: FileOperationKind
    var sourcePath: String?
    /// The actual destination (after run-time suffixing).
    var destinationPath: String?
    var previousTags: [String]?
    var trashedItemPath: String?
    var performedAt: Date
}

struct FileOperationJournalHeader: Codable, Equatable, Sendable {
    /// The task identifier.
    var journalIdentifier: String
    var taskTitle: String
    var scope: DirectRouteScope
    var startedAt: Date
}

enum FileOperationJournalStatus: String, Codable, Sendable { case running, finished, interrupted, undone, partiallyUndone }

enum FileOperationJournalStoreError: Error, Equatable {
    case invalidJournalIdentifier
    case journalAlreadyExists
    case journalMissing
    case journalUnreadable
}

/// Undo records for file-operation tasks: one `<task-id>.jsonl` file per task (mode 0600, in a 0700 folder), holding a
/// header line, one line per completed operation, one line per operation undo has put back, and status lines (the
/// last one wins). Each line is flushed to disk before the change is reported as done, so a crash leaves at most one
/// change without a record, and an undo that stopped partway can carry on from where it stopped.
/// The folder sits inside Application Support/Dotto, which ProtectedPathPolicy keeps out of every file operation.
final class FileOperationJournalStore: @unchecked Sendable {
    static var defaultJournalsDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Dotto/Journals", isDirectory: true)
    }

    static let retainedJournalCount = 20
    static let retainedJournalAgeSeconds: TimeInterval = 7 * 24 * 60 * 60

    let journalsDirectoryURL: URL
    private let storeLock = NSLock()
    private var openFileHandlesByJournalIdentifier: [String: FileHandle] = [:]
    /// Journals begun by this process and not yet given a final status. A `running` journal that isn't in this set
    /// was left behind by a crash or a quit, so it reads as `interrupted`.
    private var journalIdentifiersRunningInThisProcess: Set<String> = []

    private struct JournalLine: Codable {
        var header: FileOperationJournalHeader?
        var entry: FileOperationJournalEntry?
        var status: FileOperationJournalStatus?
        /// An operation whose change undo reversed.
        var revertedOperationIdentifier: String?
    }

    struct LoadedJournal {
        var header: FileOperationJournalHeader
        var entries: [FileOperationJournalEntry]
        var status: FileOperationJournalStatus
        var revertedOperationIdentifiers: Set<String>

        /// Entries undo hasn't reversed yet.
        var entriesNotYetReverted: [FileOperationJournalEntry] {
            entries.filter { !revertedOperationIdentifiers.contains($0.operationIdentifier) }
        }

        /// Finished, interrupted, or partly undone with something left to reverse; never while its task runs.
        var isUndoable: Bool {
            switch status {
            case .finished, .interrupted, .partiallyUndone: return !entriesNotYetReverted.isEmpty
            case .running, .undone: return false
            }
        }
    }

    init(journalsDirectoryURL: URL = FileOperationJournalStore.defaultJournalsDirectoryURL) throws {
        self.journalsDirectoryURL = journalsDirectoryURL
        try FileManager.default.createDirectory(at: journalsDirectoryURL, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: journalsDirectoryURL.path)
    }

    deinit {
        for fileHandle in openFileHandlesByJournalIdentifier.values { try? fileHandle.close() }
    }

    func beginJournal(_ header: FileOperationJournalHeader) throws {
        let journalFileURL = try fileURL(ofJournal: header.journalIdentifier)
        try storeLock.withLock {
            if FileManager.default.fileExists(atPath: journalFileURL.path) { throw FileOperationJournalStoreError.journalAlreadyExists }
            guard FileManager.default.createFile(atPath: journalFileURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw FileOperationJournalStoreError.journalUnreadable
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalFileURL.path)
            journalIdentifiersRunningInThisProcess.insert(header.journalIdentifier)
        }
        try appendLine(JournalLine(header: header), toJournal: header.journalIdentifier)
        try appendLine(JournalLine(status: .running), toJournal: header.journalIdentifier)
    }

    func append(_ entry: FileOperationJournalEntry, toJournal journalIdentifier: String) throws {
        try appendLine(JournalLine(entry: entry), toJournal: journalIdentifier)
    }

    func markReverted(operationIdentifier: String, inJournal journalIdentifier: String) throws {
        try appendLine(JournalLine(revertedOperationIdentifier: operationIdentifier), toJournal: journalIdentifier)
    }

    func markStatus(_ status: FileOperationJournalStatus, ofJournal journalIdentifier: String) throws {
        try appendLine(JournalLine(status: status), toJournal: journalIdentifier)
        if status != .running {
            storeLock.withLock {
                journalIdentifiersRunningInThisProcess.remove(journalIdentifier)
                if let fileHandle = openFileHandlesByJournalIdentifier.removeValue(forKey: journalIdentifier) {
                    try? fileHandle.close()
                }
            }
        }
    }

    func loadJournal(_ journalIdentifier: String) throws -> LoadedJournal {
        let journalFileURL = try fileURL(ofJournal: journalIdentifier)
        guard FileManager.default.fileExists(atPath: journalFileURL.path) else { throw FileOperationJournalStoreError.journalMissing }
        let journalData = try Data(contentsOf: journalFileURL)
        var header: FileOperationJournalHeader?
        var entries: [FileOperationJournalEntry] = []
        var status: FileOperationJournalStatus = .running
        var revertedOperationIdentifiers: Set<String> = []
        let lineDecoder = JSONDecoder()
        for lineData in journalData.split(separator: 0x0A) where !lineData.isEmpty {
            // A line cut short by a crash is skipped; every complete line before it still counts.
            guard let journalLine = try? lineDecoder.decode(JournalLine.self, from: Data(lineData)) else { continue }
            if let lineHeader = journalLine.header { header = lineHeader }
            if let lineEntry = journalLine.entry { entries.append(lineEntry) }
            if let lineStatus = journalLine.status { status = lineStatus }
            if let revertedOperationIdentifier = journalLine.revertedOperationIdentifier {
                revertedOperationIdentifiers.insert(revertedOperationIdentifier)
            }
        }
        guard let header, header.journalIdentifier == journalIdentifier else { throw FileOperationJournalStoreError.journalUnreadable }
        let isRunningInThisProcess = storeLock.withLock { journalIdentifiersRunningInThisProcess.contains(journalIdentifier) }
        if status == .running && !isRunningInThisProcess { status = .interrupted }
        return LoadedJournal(header: header, entries: entries, status: status, revertedOperationIdentifiers: revertedOperationIdentifiers)
    }

    /// The newest journal (by start) that can still be undone (`LoadedJournal.isUndoable`); a journal left `running`
    /// at launch counts as `interrupted`, and one undone partway stays offered for what is left.
    func mostRecentUndoableJournalIdentifier() -> String? {
        loadAllJournalSummaries()
            .filter(\.isUndoable)
            .max { $0.startedAt < $1.startedAt }?
            .journalIdentifier
    }

    /// Keeps the newest 20 journals and anything younger than 7 days; deletes the rest.
    func pruneOldJournals(now: Date) throws {
        let journalSummariesNewestFirst = loadAllJournalSummaries().sorted { $0.startedAt > $1.startedAt }
        for (journalOffset, journalSummary) in journalSummariesNewestFirst.enumerated() {
            let isAmongNewest = journalOffset < Self.retainedJournalCount
            let isRecent = now.timeIntervalSince(journalSummary.startedAt) < Self.retainedJournalAgeSeconds
            let isRunningInThisProcess = storeLock.withLock {
                journalIdentifiersRunningInThisProcess.contains(journalSummary.journalIdentifier)
            }
            if isAmongNewest || isRecent || isRunningInThisProcess { continue }
            try FileManager.default.removeItem(at: try fileURL(ofJournal: journalSummary.journalIdentifier))
        }
    }

    // MARK: - Files

    private struct JournalSummary {
        var journalIdentifier: String
        var startedAt: Date
        var isUndoable: Bool
    }

    private func loadAllJournalSummaries() -> [JournalSummary] {
        let journalFileNames = (try? FileManager.default.contentsOfDirectory(atPath: journalsDirectoryURL.path)) ?? []
        return journalFileNames.filter { $0.hasSuffix(".jsonl") }.compactMap { journalFileName in
            let journalIdentifier = String(journalFileName.dropLast(".jsonl".count))
            guard let loadedJournal = try? loadJournal(journalIdentifier) else { return nil }
            return JournalSummary(journalIdentifier: journalIdentifier, startedAt: loadedJournal.header.startedAt,
                                  isUndoable: loadedJournal.isUndoable)
        }
    }

    /// Journal identifiers are task identifiers ("20260922-153012-ab12cd"); anything that could leave the folder is refused.
    private func fileURL(ofJournal journalIdentifier: String) throws -> URL {
        let isFileNameSafe = !journalIdentifier.isEmpty && journalIdentifier.count <= 128
            && journalIdentifier.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        guard isFileNameSafe else { throw FileOperationJournalStoreError.invalidJournalIdentifier }
        return journalsDirectoryURL.appendingPathComponent("\(journalIdentifier).jsonl")
    }

    private func appendLine(_ journalLine: JournalLine, toJournal journalIdentifier: String) throws {
        let journalFileURL = try fileURL(ofJournal: journalIdentifier)
        // Dates keep their full precision (JSONEncoder's default), so a journal reads back exactly as it was written.
        let lineEncoder = JSONEncoder()
        lineEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var encodedLine = try lineEncoder.encode(journalLine)
        encodedLine.append(0x0A)
        try storeLock.withLock {
            let fileHandle: FileHandle
            if let openFileHandle = openFileHandlesByJournalIdentifier[journalIdentifier] {
                fileHandle = openFileHandle
            } else {
                guard FileManager.default.fileExists(atPath: journalFileURL.path) else { throw FileOperationJournalStoreError.journalMissing }
                fileHandle = try FileHandle(forWritingTo: journalFileURL)
                openFileHandlesByJournalIdentifier[journalIdentifier] = fileHandle
            }
            try fileHandle.seekToEnd()
            try fileHandle.write(contentsOf: encodedLine)
            try fileHandle.synchronize()
        }
    }
}
