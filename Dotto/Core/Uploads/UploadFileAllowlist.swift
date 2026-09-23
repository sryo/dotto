import Foundation

/// Files come only from the user: attached or dropped in the command bar, or inside a folder picked for a folder
/// routine. Nothing typed in a command ever grants a file or folder.
enum UploadFileGrantSource: String, Codable, Sendable {
    case pickedByUser = "picked_by_user"
    case pickedFolderByUser = "picked_folder_by_user"
}

struct UploadFileGrant: Codable, Equatable, Sendable {
    /// Absolute, symlinks resolved, standardized: Platform canonicalizes before building a grant.
    var canonicalPath: String
    var isDirectory: Bool
    var source: UploadFileGrantSource

    /// A file or folder the user chose in an open panel, a folder picker or by dropping it on the command bar.
    static func userPicked(canonicalPath: String, isDirectory: Bool) -> UploadFileGrant {
        UploadFileGrant(canonicalPath: canonicalPath, isDirectory: isDirectory,
                        source: isDirectory ? .pickedFolderByUser : .pickedByUser)
    }

    /// Only a folder the user picked covers the files inside it.
    var isHonoredFolderGrant: Bool { isDirectory && source == .pickedFolderByUser }
    var isHonoredFileGrant: Bool { !isDirectory }
}

enum UploadFileAllowlistDecision: Equatable, Sendable {
    case allowed(canonicalPaths: [String])
    case denied(reasonForModel: String)
}

/// Only files the user attached can be uploaded, however the model or a page asks. The backend enforces it for
/// agent steps and routine replay alike.
struct UploadFileAllowlist: Equatable, Sendable {
    static let maximumFilesPerUpload = 20
    static let maximumPromptListedFileCount = 50
    /// Never uploadable, even inside a granted folder (e.g. the user picked their home folder).
    static let deniedPathComponents: Set<String> = ProtectedPathPolicy.deniedPathComponents
    var grants: [UploadFileGrant]
    /// ~/Library holds app data, browser profiles and credentials, so nothing under it is uploadable, even when
    /// granted directly.
    var homeDirectoryPath: String = NSHomeDirectory()
    static let empty = UploadFileAllowlist(grants: [])

    /// The APFS data volume's firmlink: "/System/Volumes/Data/Users/me/a.pdf" is "/Users/me/a.pdf".
    static let dataVolumeMountPath = "/System/Volumes/Data"

    /// Grants that would cover the whole disk, every user's home or a whole volume are never honored, whoever picked
    /// them: "/", "/Users", "/Volumes" and each "/Volumes/<name>", in either spelling of the data volume.
    var grantsHonoredForUpload: [UploadFileGrant] {
        grants.filter { grant in
            (grant.isHonoredFileGrant || grant.isHonoredFolderGrant) && !Self.isRefusedGrantRoot(grant.canonicalPath)
        }
    }

    /// Strips the data volume's mount path, so both spellings of a path compare (and are protected) alike.
    static func normalizedPath(_ canonicalPath: String) -> String {
        if canonicalPath == dataVolumeMountPath || canonicalPath == dataVolumeMountPath + "/" { return "/" }
        if canonicalPath.hasPrefix(dataVolumeMountPath + "/") { return String(canonicalPath.dropFirst(dataVolumeMountPath.count)) }
        return canonicalPath
    }

    static func isRefusedGrantRoot(_ canonicalPath: String) -> Bool {
        let normalizedComponents = normalizedPath(canonicalPath).split(separator: "/")
        if normalizedComponents.isEmpty { return true }
        if normalizedComponents == ["Users"] { return true }
        return normalizedComponents.first == "Volumes" && normalizedComponents.count <= 2
    }

    init(grants: [UploadFileGrant], homeDirectoryPath: String = NSHomeDirectory()) {
        self.grants = grants
        self.homeDirectoryPath = homeDirectoryPath
    }

    /// `canonicalizeExistingRegularFile` is supplied by Platform: expands "~", resolves symlinks (realpath) and
    /// returns nil unless the result is an existing regular file.
    func evaluate(requestedPaths: [String], canonicalizeExistingRegularFile: (String) -> String?) -> UploadFileAllowlistDecision {
        guard (1...Self.maximumFilesPerUpload).contains(requestedPaths.count) else {
            return .denied(reasonForModel: "upload_files needs between 1 and \(Self.maximumFilesPerUpload) file paths.")
        }
        var allowedCanonicalPaths: [String] = []
        for requestedPath in requestedPaths {
            let displayedName = "“\((requestedPath as NSString).lastPathComponent)”"
            guard requestedPath.hasPrefix("/") || requestedPath.hasPrefix("~/") else {
                return .denied(reasonForModel: "\(displayedName) isn't an absolute path. Use the exact paths of the files attached to this task.")
            }
            guard let resolvedPath = canonicalizeExistingRegularFile(requestedPath) else {
                return .denied(reasonForModel: "\(displayedName) doesn't exist or isn't a regular file.")
            }
            let canonicalPath = Self.normalizedPath(resolvedPath)
            let canonicalComponents = Array(canonicalPath.split(separator: "/", omittingEmptySubsequences: false).dropFirst())
            // A canonicalizer that let "." or ".." through would make the prefix test below meaningless.
            guard canonicalPath.hasPrefix("/"), !canonicalComponents.contains(where: { $0 == "." || $0 == ".." || $0.isEmpty }) else {
                return .denied(reasonForModel: "\(displayedName) doesn't exist or isn't a regular file.")
            }
            if ProtectedPathPolicy.isProtected(normalizedPathComponents: canonicalComponents, homeDirectoryPath: homeDirectoryPath) {
                return .denied(reasonForModel: "\(displayedName) is inside a protected folder and can't be uploaded.")
            }
            let honoredGrants = grantsHonoredForUpload
            let isGrantedDirectly = honoredGrants.contains { $0.isHonoredFileGrant && Self.normalizedPath($0.canonicalPath) == canonicalPath }
            if !isGrantedDirectly {
                let containingFolderPath = honoredGrants.filter(\.isHonoredFolderGrant).map { Self.normalizedPath($0.canonicalPath) }
                    .first { folderPath in canonicalPath.hasPrefix(folderPath.hasSuffix("/") ? folderPath : folderPath + "/") }
                guard let containingFolderPath else {
                    return .denied(reasonForModel: "\(displayedName) isn't one of the files attached to this task. Only files the user attached can be uploaded.")
                }
                let pathBelowGrant = canonicalPath.dropFirst(containingFolderPath.count)
                if pathBelowGrant.split(separator: "/").contains(where: { $0.hasPrefix(".") }) {
                    return .denied(reasonForModel: "\(displayedName) is a hidden file. Hidden files can only be uploaded when the user attaches them one by one.")
                }
            }
            if !allowedCanonicalPaths.contains(canonicalPath) { allowedCanonicalPaths.append(canonicalPath) }
        }
        return .allowed(canonicalPaths: allowedCanonicalPaths)
    }

    /// The native open panel selects several files in one folder only, so a multi-file upload needs one parent.
    static func sharedParentFolderPath(ofCanonicalPaths canonicalPaths: [String]) -> String? {
        let parentFolderPaths = Set(canonicalPaths.map { ($0 as NSString).deletingLastPathComponent })
        guard parentFolderPaths.count == 1 else { return nil }
        return parentFolderPaths.first
    }

    /// What a rest-of-task upload grant can cover, for the confirmation card: file basenames, then picked folders
    /// by name. Never full paths, because folder names above the attachment can be personal.
    var userFacingCoverageDescription: String {
        let honoredGrants = grantsHonoredForUpload
        guard !honoredGrants.isEmpty else { return "nothing (no files are attached)" }
        let fileNames = honoredGrants.filter(\.isHonoredFileGrant).map { "“\(($0.canonicalPath as NSString).lastPathComponent)”" }
        let folderNames = honoredGrants.filter(\.isHonoredFolderGrant)
            .map { "files in the folder “\(($0.canonicalPath as NSString).lastPathComponent)”" }
        return SafetyGate.namedListDescription(fileNames + folderNames, maximumNamedCount: 5)
    }

    /// Planner-facing list of "- /abs/path" lines; Platform expands folders beforehand.
    static func promptListing(ofFilePaths filePaths: [String]) -> String {
        var listingLines = filePaths.prefix(maximumPromptListedFileCount).map { "- " + $0 }
        if filePaths.count > maximumPromptListedFileCount {
            listingLines.append("- … and \(filePaths.count - maximumPromptListedFileCount) more files not listed")
        }
        return listingLines.joined(separator: "\n")
    }
}
