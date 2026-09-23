import Foundation

/// The real file system behind direct routes. Every mutation is a single system call that refuses to replace
/// anything (mkdir, renamex_np with RENAME_EXCL, copyfile with COPYFILE_EXCL, rmdir), and each one re-checks the
/// source with lstat first, so a file that changed since the dry run fails instead of being touched. Creating,
/// renaming and removing folders go through descriptors of the parent folders opened one component at a time with
/// O_NOFOLLOW (mkdirat, renameatx_np, unlinkat), so no folder on the path can be a symbolic link at that moment; Core
/// has already checked each operand's real folder (`FileOperationContainmentCheck`). Reading lives in
/// `FileManagerFileSystem+Reading`.
final class FileManagerFileSystem: FileSystemMutating, DirectRouteFileSystemReading, @unchecked Sendable {
    init() {}

    // MARK: - Mutations

    func createFolder(atCanonicalPath canonicalPath: String) throws {
        guard existingItemKind(atCanonicalPath: canonicalPath) == nil else { throw FileSystemMutationError.destinationExists }
        let parentFolderDescriptor = try Self.openFolderWithoutFollowingLinks(FileOperationPathRules.parentPath(of: canonicalPath))
        defer { close(parentFolderDescriptor) }
        guard mkdirat(parentFolderDescriptor, FileOperationPathRules.name(of: canonicalPath), 0o755) == 0 else {
            throw Self.mutationError(forErrorNumber: errno)
        }
    }

    func moveItemWithoutReplacing(fromCanonicalPath sourcePath: String, toCanonicalPath destinationPath: String) throws {
        guard existingItemKind(atCanonicalPath: sourcePath) != nil else { throw FileSystemMutationError.sourceMissing }
        // A case- or accent-only rename ("foto.png" → "Foto.png") finds the item itself at the destination on a
        // case-insensitive volume; RENAME_EXCL still refuses anything else that is there.
        if existingItemKind(atCanonicalPath: destinationPath) != nil && !Self.isSameItem(sourcePath, destinationPath) {
            throw FileSystemMutationError.destinationExists
        }
        let sourceFolderDescriptor = try Self.openFolderWithoutFollowingLinks(FileOperationPathRules.parentPath(of: sourcePath))
        defer { close(sourceFolderDescriptor) }
        let destinationFolderDescriptor = try Self.openFolderWithoutFollowingLinks(FileOperationPathRules.parentPath(of: destinationPath))
        defer { close(destinationFolderDescriptor) }
        // RENAME_EXCL makes the kernel refuse an existing destination atomically, closing the gap after the check above.
        guard renameatx_np(sourceFolderDescriptor, FileOperationPathRules.name(of: sourcePath),
                           destinationFolderDescriptor, FileOperationPathRules.name(of: destinationPath), UInt32(RENAME_EXCL)) == 0 else {
            throw Self.mutationError(forErrorNumber: errno)
        }
    }

    func copyItemWithoutReplacing(fromCanonicalPath sourcePath: String, toCanonicalPath destinationPath: String,
                                  abortSignal: TaskAbortSignal) throws {
        guard existingItemKind(atCanonicalPath: sourcePath) != nil else { throw FileSystemMutationError.sourceMissing }
        guard existingItemKind(atCanonicalPath: destinationPath) == nil else { throw FileSystemMutationError.destinationExists }
        try abortSignal.throwIfAborted()

        guard let copyState = copyfile_state_alloc() else { throw FileSystemMutationError.other("Dotto couldn't start the copy.") }
        defer { copyfile_state_free(copyState) }
        let abortSignalContext = Unmanaged.passUnretained(abortSignal).toOpaque()
        // copyfile calls this between files and data chunks; returning COPYFILE_QUIT stops the copy on Stop.
        let quitWhenAbortedCallback: copyfile_callback_t = { _, _, _, _, _, callbackContext in
            guard let callbackContext else { return COPYFILE_CONTINUE }
            let abortSignal = Unmanaged<TaskAbortSignal>.fromOpaque(callbackContext).takeUnretainedValue()
            return abortSignal.isAborted ? COPYFILE_QUIT : COPYFILE_CONTINUE
        }
        // copyfile_state_set stores the function pointer and the context pointer themselves (not pointers to them).
        _ = copyfile_state_set(copyState, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(quitWhenAbortedCallback, to: UnsafeRawPointer.self))
        _ = copyfile_state_set(copyState, UInt32(COPYFILE_STATE_STATUS_CTX), UnsafeRawPointer(abortSignalContext))

        let copyFlags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_EXCL | COPYFILE_NOFOLLOW_SRC)
        let copyResult = copyfile(sourcePath, destinationPath, copyState, copyFlags)
        let copyErrorNumber = errno
        if abortSignal.isAborted {
            // A copy stopped halfway is not the user's file: it goes to the Trash rather than being left or deleted.
            if existingItemKind(atCanonicalPath: destinationPath) != nil {
                _ = try? moveItemToTrash(atCanonicalPath: destinationPath)
            }
            throw FileSystemMutationError.stopped
        }
        guard copyResult == 0 else { throw Self.mutationError(forErrorNumber: copyErrorNumber) }
    }

    func finderTags(atCanonicalPath canonicalPath: String) throws -> [String] {
        guard existingItemKind(atCanonicalPath: canonicalPath) != nil else { throw FileSystemMutationError.sourceMissing }
        do {
            return try URL(fileURLWithPath: canonicalPath).resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
        } catch {
            throw Self.mutationError(forFoundationError: error)
        }
    }

    func setFinderTags(_ tags: [String], atCanonicalPath canonicalPath: String) throws {
        guard existingItemKind(atCanonicalPath: canonicalPath) != nil else { throw FileSystemMutationError.sourceMissing }
        do {
            try (URL(fileURLWithPath: canonicalPath) as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
        } catch {
            throw Self.mutationError(forFoundationError: error)
        }
    }

    func moveItemToTrash(atCanonicalPath canonicalPath: String) throws -> String {
        guard existingItemKind(atCanonicalPath: canonicalPath) != nil else { throw FileSystemMutationError.sourceMissing }
        var resultingItemURL: NSURL?
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: canonicalPath), resultingItemURL: &resultingItemURL)
        } catch {
            throw Self.mutationError(forFoundationError: error)
        }
        guard let trashedItemPath = resultingItemURL?.path else {
            throw FileSystemMutationError.other("macOS didn't say where in the Trash the item went.")
        }
        return trashedItemPath
    }

    func removeEmptyFolder(atCanonicalPath canonicalPath: String) throws {
        guard existingItemKind(atCanonicalPath: canonicalPath) == .folder else { throw FileSystemMutationError.sourceMissing }
        let parentFolderDescriptor = try Self.openFolderWithoutFollowingLinks(FileOperationPathRules.parentPath(of: canonicalPath))
        defer { close(parentFolderDescriptor) }
        let folderName = FileOperationPathRules.name(of: canonicalPath)
        // rmdir only ever removes an empty folder, so nothing the user put there can be lost.
        if unlinkat(parentFolderDescriptor, folderName, AT_REMOVEDIR) == 0 { return }
        let removeErrorNumber = errno
        guard removeErrorNumber == ENOTEMPTY else { throw Self.mutationError(forErrorNumber: removeErrorNumber) }
        try removeFinderMetadataFiles(inFolderNamed: folderName, parentFolderDescriptor: parentFolderDescriptor)
        guard unlinkat(parentFolderDescriptor, folderName, AT_REMOVEDIR) == 0 else { throw Self.mutationError(forErrorNumber: errno) }
    }

    /// Finder writes .DS_Store (and Icon\r) into a folder as soon as it shows it. When those regular files are all the
    /// folder holds, they go, so the folder Dotto created can be removed; anything else there keeps it (notEmpty).
    private func removeFinderMetadataFiles(inFolderNamed folderName: String, parentFolderDescriptor: Int32) throws {
        let folderDescriptor = openat(parentFolderDescriptor, folderName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folderDescriptor >= 0 else { throw Self.mutationError(forErrorNumber: errno) }
        defer { close(folderDescriptor) }
        var entryNames: [String] = []
        // fdopendir takes ownership of the descriptor it is given, so it gets a duplicate.
        let listingDescriptor = dup(folderDescriptor)
        guard listingDescriptor >= 0 else { throw Self.mutationError(forErrorNumber: errno) }
        guard let folderStream = fdopendir(listingDescriptor) else {
            close(listingDescriptor)
            throw FileSystemMutationError.notEmpty
        }
        defer { closedir(folderStream) }
        while let entryPointer = readdir(folderStream) {
            let entryName = withUnsafeBytes(of: entryPointer.pointee.d_name) { nameBytes in
                String(decoding: nameBytes.prefix(Int(entryPointer.pointee.d_namlen)), as: UTF8.self)
            }
            if entryName != "." && entryName != ".." { entryNames.append(entryName) }
        }
        guard !entryNames.isEmpty, entryNames.allSatisfy({ FileOperationPathRules.finderMetadataFileNames.contains($0) }) else {
            throw FileSystemMutationError.notEmpty
        }
        for entryName in entryNames {
            var entryStatus = stat()
            guard fstatat(folderDescriptor, entryName, &entryStatus, AT_SYMLINK_NOFOLLOW) == 0,
                  (entryStatus.st_mode & S_IFMT) == S_IFREG else { throw FileSystemMutationError.notEmpty }
            guard unlinkat(folderDescriptor, entryName, 0) == 0 else { throw Self.mutationError(forErrorNumber: errno) }
        }
    }

    func fullyResolvedPath(ofExistingPath path: String) -> String? {
        Self.resolvedPath(path).map(UploadFileAllowlist.normalizedPath)
    }

    // MARK: - Descriptors

    /// Opens the folder at an absolute path one component at a time with O_NOFOLLOW, so the open fails (ELOOP or
    /// ENOTDIR) if any component, the folder itself included, is a symbolic link. The caller closes the descriptor.
    /// Each folder is opened for search only (O_SEARCH, spelled O_EXEC | O_DIRECTORY): the *at calls need nothing
    /// more, and a folder macOS won't let Dotto list (the Trash, for putting an item back) still opens.
    static func openFolderWithoutFollowingLinks(_ folderPath: String) throws -> Int32 {
        guard folderPath.hasPrefix("/") else { throw FileSystemMutationError.other("Dotto only changes items by absolute path.") }
        let searchOnlyFolderFlags = O_EXEC | O_DIRECTORY | O_CLOEXEC
        var currentDescriptor = open("/", searchOnlyFolderFlags)
        guard currentDescriptor >= 0 else { throw mutationError(forErrorNumber: errno) }
        for pathComponent in folderPath.split(separator: "/") {
            let nextDescriptor = openat(currentDescriptor, String(pathComponent), searchOnlyFolderFlags | O_NOFOLLOW)
            let openErrorNumber = errno
            close(currentDescriptor)
            guard nextDescriptor >= 0 else {
                if openErrorNumber == ELOOP || openErrorNumber == ENOTDIR {
                    throw FileSystemMutationError.other("a folder on its path is now a link or a file, so Dotto left it alone")
                }
                throw mutationError(forErrorNumber: openErrorNumber)
            }
            currentDescriptor = nextDescriptor
        }
        return currentDescriptor
    }

    /// Same device and inode: the two paths name one item (a case- or accent-only spelling of the same name).
    private static func isSameItem(_ firstPath: String, _ secondPath: String) -> Bool {
        var firstStatus = stat()
        var secondStatus = stat()
        guard lstat(firstPath, &firstStatus) == 0, lstat(secondPath, &secondStatus) == 0 else { return false }
        return firstStatus.st_dev == secondStatus.st_dev && firstStatus.st_ino == secondStatus.st_ino
    }

    /// lstat: a symbolic link is reported as the link, never followed.
    func existingItemKind(atCanonicalPath canonicalPath: String) -> ExistingFileSystemItemKind? {
        var fileStatus = stat()
        guard lstat(canonicalPath, &fileStatus) == 0 else { return nil }
        switch fileStatus.st_mode & S_IFMT {
        case S_IFREG:
            return .regularFile
        case S_IFLNK:
            return .symbolicLink
        case S_IFDIR:
            let isPackage = (try? URL(fileURLWithPath: canonicalPath, isDirectory: true).resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false
            return isPackage == true ? .package : .folder
        default:
            return .other
        }
    }

    // MARK: - Errors

    static func mutationError(forErrorNumber errorNumber: Int32) -> FileSystemMutationError {
        switch errorNumber {
        case EEXIST: return .destinationExists
        case ENOENT: return .sourceMissing
        case EACCES, EPERM, EROFS: return .permissionDenied
        case ENOTEMPTY: return .notEmpty
        case EXDEV: return .crossVolume
        default: return .other(String(cString: strerror(errorNumber)))
        }
    }

    static func mutationError(forFoundationError error: Error) -> FileSystemMutationError {
        let foundationError = error as NSError
        if foundationError.domain == NSCocoaErrorDomain {
            switch foundationError.code {
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return .sourceMissing
            case NSFileWriteFileExistsError: return .destinationExists
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError, NSFileWriteVolumeReadOnlyError: return .permissionDenied
            default: break
            }
        }
        if foundationError.domain == NSPOSIXErrorDomain { return mutationError(forErrorNumber: Int32(foundationError.code)) }
        return .other(foundationError.localizedDescription)
    }
}
