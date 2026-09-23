import Foundation

/// Turns user-picked paths into the canonical form the upload allowlist compares, so a symlink or a
/// "~" can never make a path look like it's inside a grant when it isn't.
enum UploadFilePathResolver {
    /// Expands "~" and resolves every symlink (realpath); nil unless the result is an existing regular file.
    static func canonicalizeExistingRegularFile(_ path: String) -> String? {
        guard let canonicalItem = canonicalizeExistingItem(path), !canonicalItem.isDirectory else { return nil }
        return canonicalItem.canonicalPath
    }

    static func canonicalizeExistingItem(_ path: String) -> (canonicalPath: String, isDirectory: Bool)? {
        let expandedPath = (path as NSString).expandingTildeInPath
        guard let resolvedPathPointer = realpath(expandedPath, nil) else { return nil }
        defer { free(resolvedPathPointer) }
        let resolvedPath = String(cString: resolvedPathPointer)
        var fileStatus = stat()
        guard stat(resolvedPath, &fileStatus) == 0 else { return nil }
        switch fileStatus.st_mode & S_IFMT {
        case S_IFREG: return (resolvedPath, false)
        case S_IFDIR: return (resolvedPath, true)
        default: return nil
        }
    }

    /// A file or folder the user chose in an open panel.
    static func makeUserPickedGrant(forPath path: String) -> UploadFileGrant? {
        canonicalizeExistingItem(path).map { canonicalItem in
            UploadFileGrant.userPicked(canonicalPath: canonicalItem.canonicalPath, isDirectory: canonicalItem.isDirectory)
        }
    }

    /// The planner sees concrete file paths, so folders are listed one level deep (regular, non-hidden files). Only
    /// grants an upload can actually draw on are listed.
    static func filePathsForPlannerPrompt(from uploadFileGrants: [UploadFileGrant]) -> [String] {
        var listedFilePaths: [String] = []
        for uploadFileGrant in UploadFileAllowlist(grants: uploadFileGrants).grantsHonoredForUpload {
            guard uploadFileGrant.isDirectory else {
                listedFilePaths.append(uploadFileGrant.canonicalPath)
                continue
            }
            let folderEntryURLs = (try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: uploadFileGrant.canonicalPath), includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles])) ?? []
            let regularFilePaths = folderEntryURLs
                .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
                .map(\.path)
                .sorted()
            listedFilePaths.append(contentsOf: regularFilePaths.prefix(UploadFileAllowlist.maximumPromptListedFileCount))
        }
        return listedFilePaths
    }
}
