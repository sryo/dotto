import Foundation

struct SkippedRoutineFile: Equatable, Sendable {
    var fileName: String
    var reason: String
}

struct RoutineLibraryContents: Equatable, Sendable {
    /// Newest first.
    var routines: [Routine]
    var skippedFiles: [SkippedRoutineFile]
}

/// Saved routines as one signed JSON file each. Routine files are data: loading one never bypasses SafetyGate,
/// and a file that isn't a regular file owned by this user, isn't signed with this Mac's key, or doesn't name its
/// app's bundle identifier is reported as skipped instead of loaded.
final class RoutineLibraryStore: @unchecked Sendable {
    static var defaultDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Dotto/Routines", isDirectory: true)
    }

    /// Far above any real routine (200 steps of locators), so a huge planted file isn't read into memory.
    private static let maximumRoutineFileByteCount = 4 * 1024 * 1024

    private let directoryURL: URL
    private let signingKeyProvider: RoutineSigningKeyProviding?

    /// Without a signing key provider nothing can be saved and every file is skipped.
    init(directoryURL: URL = RoutineLibraryStore.defaultDirectoryURL, signingKeyProvider: RoutineSigningKeyProviding? = nil) {
        self.directoryURL = directoryURL
        self.signingKeyProvider = signingKeyProvider
    }

    func loadRoutineLibrary() -> RoutineLibraryContents {
        let fileURLs = ((try? FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !fileURLs.isEmpty else { return RoutineLibraryContents(routines: [], skippedFiles: []) }

        let signingKey: Data
        do {
            signingKey = try requireSigningKey()
        } catch {
            let reason = "Dotto can't check routine signatures: \(Self.describe(error))"
            return RoutineLibraryContents(routines: [], skippedFiles: fileURLs.map { SkippedRoutineFile(fileName: $0.lastPathComponent, reason: reason) })
        }
        var loadedRoutines: [Routine] = []
        var skippedFiles: [SkippedRoutineFile] = []
        for fileURL in fileURLs {
            switch loadRoutine(at: fileURL, signingKey: signingKey) {
            case .success(let routine): loadedRoutines.append(routine)
            case .failure(let loadError): skippedFiles.append(SkippedRoutineFile(fileName: fileURL.lastPathComponent, reason: loadError.message))
            }
        }
        return RoutineLibraryContents(routines: loadedRoutines.sorted { $0.updatedAt > $1.updatedAt }, skippedFiles: skippedFiles)
    }

    func save(_ routine: Routine) throws {
        let fileURL = try routineFileURL(forIdentifier: routine.routineIdentifier)
        guard Self.nonEmpty(routine.targetApplicationBundleIdentifier) != nil else {
            throw RoutineTemplateError(message: "A routine can only be saved for an app with a bundle identifier.")
        }
        var signedRoutine = routine
        signedRoutine.integritySignature = try RoutineIntegritySigning.signature(for: routine, signingKey: try requireSigningKey())
        // Routines hold file names and field values from the user's apps, so only the user's account may read them.
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(signedRoutine).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    func deleteRoutine(withIdentifier routineIdentifier: String) throws {
        try FileManager.default.removeItem(at: try routineFileURL(forIdentifier: routineIdentifier))
    }

    // MARK: - Loading one file

    private struct FormatVersionProbe: Decodable { var formatVersion: Int }

    private func loadRoutine(at fileURL: URL, signingKey: Data) -> Result<Routine, RoutineTemplateError> {
        func skipped(_ reason: String) -> Result<Routine, RoutineTemplateError> { .failure(RoutineTemplateError(message: reason)) }
        let fileData: Data
        switch Self.readOwnedRegularFile(at: fileURL) {
        case .success(let readData): fileData = readData
        case .failure(let readError): return .failure(readError)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // The version is read on its own first, so a file from another Dotto version is reported as such rather
        // than as damaged.
        guard let formatVersionProbe = try? decoder.decode(FormatVersionProbe.self, from: fileData) else {
            return skipped("Not an Dotto routine file.")
        }
        guard formatVersionProbe.formatVersion == Routine.currentFormatVersion else {
            return skipped("Saved by a different version of Dotto (format \(formatVersionProbe.formatVersion)).")
        }
        let routine: Routine
        do {
            routine = try decoder.decode(Routine.self, from: fileData)
        } catch {
            return skipped("The file is damaged and can't be read.")
        }
        guard routine.integritySignature != nil else { return skipped("Not signed by Dotto on this Mac.") }
        guard RoutineIntegritySigning.hasValidSignature(routine, signingKey: signingKey) else {
            return skipped("Changed outside Dotto: its signature doesn't match.")
        }
        guard fileURL.lastPathComponent == "\(routine.routineIdentifier).json" else {
            return skipped("The file name doesn't match the routine inside it.")
        }
        guard Self.nonEmpty(routine.targetApplicationBundleIdentifier) != nil else {
            return skipped("It doesn't name its app's bundle identifier.")
        }
        return .success(routine)
    }

    /// Opens without following symlinks and checks the open descriptor itself, so the file can't be swapped for a
    /// link or another user's file between the check and the read.
    private static func readOwnedRegularFile(at fileURL: URL) -> Result<Data, RoutineTemplateError> {
        func skipped(_ reason: String) -> Result<Data, RoutineTemplateError> { .failure(RoutineTemplateError(message: reason)) }
        // O_NONBLOCK keeps a planted FIFO from blocking the open; it is rejected as not regular right after.
        let fileDescriptor = open(fileURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fileDescriptor >= 0 else {
            return skipped(errno == ELOOP ? "It is a symbolic link, not a routine file." : "It can't be opened.")
        }
        let fileHandle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
        var fileStatus = stat()
        guard fstat(fileDescriptor, &fileStatus) == 0 else { return skipped("It can't be inspected.") }
        guard fileStatus.st_mode & S_IFMT == S_IFREG else { return skipped("It is not a regular file.") }
        guard fileStatus.st_uid == getuid() else { return skipped("It is owned by another user.") }
        guard fileStatus.st_size <= maximumRoutineFileByteCount else { return skipped("It is too large to be a routine.") }
        do {
            return .success(try fileHandle.readToEnd() ?? Data())
        } catch {
            return skipped("It can't be read.")
        }
    }

    // MARK: - Helpers

    private func requireSigningKey() throws -> Data {
        guard let signingKeyProvider else { throw RoutineTemplateError(message: "No routine signing key is available.") }
        let signingKey = try signingKeyProvider.routineSigningKey()
        guard signingKey.count >= RoutineIntegritySigning.minimumSigningKeyByteCount else {
            throw RoutineTemplateError(message: "The routine signing key is too short.")
        }
        return signingKey
    }

    private static func describe(_ error: Error) -> String {
        (error as? RoutineTemplateError)?.message ?? error.localizedDescription
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let trimmedText = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmedText.isEmpty else { return nil }
        return trimmedText
    }

    /// The identifier becomes a file name, so anything outside [a-z0-9-] (like "../") is rejected.
    private func routineFileURL(forIdentifier routineIdentifier: String) throws -> URL {
        guard routineIdentifier.range(of: #"\A[a-z0-9-]{1,80}\z"#, options: .regularExpression) != nil else {
            throw RoutineTemplateError(message: "Invalid routine identifier “\(routineIdentifier)”.")
        }
        return directoryURL.appendingPathComponent("\(routineIdentifier).json")
    }
}
