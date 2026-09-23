import Foundation

enum ShortcutsCommandRunnerError: Error, Equatable, LocalizedError {
    case listingFailed(String)
    case refusedName(String)
    case inputFileUnwritable

    var errorDescription: String? {
        switch self {
        case .listingFailed(let standardErrorText):
            return "Dotto couldn't list your shortcuts" + (standardErrorText.isEmpty ? "." : ": \(standardErrorText)")
        case .refusedName(let reason):
            return "Dotto won't run that shortcut: \(reason)"
        case .inputFileUnwritable:
            return "Dotto couldn't prepare the shortcut's input."
        }
    }
}

/// The user's shortcuts through `/usr/bin/shortcuts`, with an argument array (never a shell). The name goes after
/// `--`, so a name can never be read as an option. Text input goes through a 0600 file in a per-run temporary folder
/// that is deleted afterwards; output is read back from a file, at most 4 KB of text.
final class ShortcutsCommandRunner: ShortcutRunning, @unchecked Sendable {
    static let maximumListedShortcutNames = 500
    static let listingTimeoutSeconds: TimeInterval = 20
    static let outputTextByteLimit = 4 * 1024
    static let standardErrorByteLimit = 16 * 1024

    init() {}

    func listShortcutNames(abortSignal: TaskAbortSignal) async throws -> [String] {
        let processResult = try await BoundedProcessRunner.run(
            executablePath: BoundedProcessRunner.shortcutsExecutablePath, arguments: ["list"], standardInputData: nil,
            workingDirectoryURL: FileManager.default.temporaryDirectory, timeoutSeconds: Self.listingTimeoutSeconds,
            abortSignal: abortSignal, standardOutputByteLimit: 256 * 1024, standardErrorByteLimit: Self.standardErrorByteLimit)
        try abortSignal.throwIfAborted()
        guard processResult.exitStatus == 0, !processResult.timedOut else {
            throw ShortcutsCommandRunnerError.listingFailed(
                String(decoding: processResult.standardErrorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let listedNames = String(decoding: processResult.standardOutputData, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Array(listedNames.prefix(Self.maximumListedShortcutNames))
    }

    func run(_ shortcutPlan: ShortcutPlan, abortSignal: TaskAbortSignal) async throws -> ShortcutRunOutput {
        if let nameProblem = ShortcutNameRules.validate(shortcutPlan.shortcutName) {
            throw ShortcutsCommandRunnerError.refusedName(nameProblem)
        }
        let runFolderURL = FileManager.default.temporaryDirectory.appendingPathComponent("Dotto-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: runFolderURL, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: runFolderURL) }
        let outputFileURL = runFolderURL.appendingPathComponent("output")

        var runArguments = ["run"]
        switch shortcutPlan.input {
        case .none:
            break
        case .text(let inputText):
            let inputFileURL = runFolderURL.appendingPathComponent("input.txt")
            guard FileManager.default.createFile(atPath: inputFileURL.path, contents: Data(inputText.utf8),
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw ShortcutsCommandRunnerError.inputFileUnwritable
            }
            runArguments += ["--input-path", inputFileURL.path]
        case .files(let inputFilePaths):
            runArguments += ["--input-path"] + inputFilePaths
        }
        runArguments += ["--output-path", outputFileURL.path, "--", shortcutPlan.shortcutName]

        let processResult = try await BoundedProcessRunner.run(
            executablePath: BoundedProcessRunner.shortcutsExecutablePath, arguments: runArguments, standardInputData: nil,
            workingDirectoryURL: runFolderURL, timeoutSeconds: TimeInterval(min(max(shortcutPlan.timeoutSeconds, 5), 300)),
            abortSignal: abortSignal, standardOutputByteLimit: Self.outputTextByteLimit,
            standardErrorByteLimit: Self.standardErrorByteLimit)

        return ShortcutRunOutput(
            exitStatus: processResult.exitStatus,
            outputText: Self.outputText(atFileURL: outputFileURL, fallbackStandardOutputData: processResult.standardOutputData),
            standardErrorText: String(decoding: processResult.standardErrorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            timedOut: processResult.timedOut,
            wasStopped: processResult.wasStopped)
    }

    /// The output file's first 4 KB as text; a shortcut that outputs an image or other data yields no text.
    private static func outputText(atFileURL outputFileURL: URL, fallbackStandardOutputData: Data) -> String {
        var outputData = fallbackStandardOutputData
        if let outputFileHandle = try? FileHandle(forReadingFrom: outputFileURL) {
            outputData = (try? outputFileHandle.read(upToCount: outputTextByteLimit)) ?? Data()
            try? outputFileHandle.close()
        }
        // The 4 KB cut can split a multi-byte character, so up to 3 trailing bytes may be dropped; anything that still
        // isn't UTF-8 is not text.
        for droppedTrailingByteCount in 0...min(3, outputData.count) {
            if let outputText = String(data: outputData.dropLast(droppedTrailingByteCount), encoding: .utf8) {
                return outputText.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return ""
    }
}
