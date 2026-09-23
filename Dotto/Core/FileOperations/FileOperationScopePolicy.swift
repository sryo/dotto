import Foundation

enum FileOperationScopeRootDecision: Equatable, Sendable {
    case accepted(DirectRouteScopeRoot)
    case refused(reason: String)
}

enum FileOperationPathDecision: Equatable, Sendable {
    case allowed
    case denied(reasonForModel: String)
}

/// Where file operations may read and change things. Scope roots come only from the user (the Finder window they
/// summoned Dotto over, folders they attached, paths they typed), and every check is component-wise, never a string
/// prefix: "/a/bc" is not inside "/a/b".
enum FileOperationScopePolicy {
    /// Allowed roots are an allowlist, so this fails closed:
    /// - a folder strictly below the home folder, not under ~/Library
    /// - or /Volumes/<name>/<at least one more component>
    /// Refused: "/", /Users, the home folder itself, /Volumes and /Volumes/<name>, /System, /Library,
    /// /Applications, /private, /usr, /bin, /sbin, /etc, /opt, anything protected, any package (.app, .photoslibrary…),
    /// and any hidden folder (a component starting with ".").
    static func evaluateScopeRootCandidate(canonicalFolderPath: String, source: DirectRouteScopeRootSource,
                                           isPackage: Bool, homeDirectoryPath: String) -> FileOperationScopeRootDecision {
        let normalizedFolderPath = UploadFileAllowlist.normalizedPath(canonicalFolderPath)
        let displayedName = displayedName(ofPath: normalizedFolderPath)
        guard let folderComponents = normalizedComponents(ofCanonicalPath: normalizedFolderPath) else {
            return .refused(reason: "\(displayedName) isn't a usable folder path.")
        }
        if isPackage {
            return .refused(reason: "\(displayedName) is a package (an app or library bundle), not a folder.")
        }
        if isProtectedOrHomeLibraryFolder(folderComponents, homeDirectoryPath: homeDirectoryPath) {
            return .refused(reason: "\(displayedName) is inside a protected folder.")
        }
        if folderComponents.contains(where: { $0.hasPrefix(".") }) {
            return .refused(reason: "\(displayedName) is a hidden folder.")
        }
        let homeComponents = UploadFileAllowlist.normalizedPath(homeDirectoryPath).split(separator: "/")
        let isStrictlyBelowHome = !homeComponents.isEmpty && folderComponents.count > homeComponents.count
            && Array(folderComponents.prefix(homeComponents.count)) == homeComponents
            && folderComponents[homeComponents.count] != "Library"
        let isBelowNamedVolumeFolder = folderComponents.count >= 3 && folderComponents[0] == "Volumes"
        guard isStrictlyBelowHome || isBelowNamedVolumeFolder else {
            return .refused(reason: "\(displayedName) is too broad. Pick a folder inside your home folder or on a volume.")
        }
        return .accepted(DirectRouteScopeRoot(canonicalPath: normalizedFolderPath, source: source))
    }

    /// Reads (list_folder, read_file_metadata): inside some root (the root itself included), not protected.
    static func evaluateReadablePath(_ canonicalPath: String, scope: DirectRouteScope, homeDirectoryPath: String) -> FileOperationPathDecision {
        let normalizedPath = UploadFileAllowlist.normalizedPath(canonicalPath)
        let displayedName = displayedName(ofPath: normalizedPath)
        guard let pathComponents = normalizedComponents(ofCanonicalPath: normalizedPath) else {
            return .denied(reasonForModel: "\(displayedName) isn't an absolute path.")
        }
        if isProtectedOrHomeLibraryFolder(pathComponents, homeDirectoryPath: homeDirectoryPath) {
            return .denied(reasonForModel: "\(displayedName) is inside a protected folder.")
        }
        let isInsideAnyRoot = rootComponentLists(of: scope).contains { rootComponents in
            isComponentList(pathComponents, equalToOrInside: rootComponents)
        }
        guard isInsideAnyRoot else {
            return .denied(reasonForModel: "\(displayedName) is outside the scope folders. Only the folders listed in the first message can be read.")
        }
        return .allowed
    }

    /// Sources and destinations of changes: strictly inside a root (never the root itself), not protected, no
    /// "." / ".." / empty components, absolute, not inside a package unless the package itself is the operand.
    static func evaluateChangeablePath(_ canonicalPath: String, scope: DirectRouteScope, homeDirectoryPath: String,
                                       isInsidePackage: Bool) -> FileOperationPathDecision {
        let normalizedPath = UploadFileAllowlist.normalizedPath(canonicalPath)
        let displayedName = displayedName(ofPath: normalizedPath)
        guard let pathComponents = normalizedComponents(ofCanonicalPath: normalizedPath) else {
            return .denied(reasonForModel: "\(displayedName) isn't an absolute path.")
        }
        if isProtectedOrHomeLibraryFolder(pathComponents, homeDirectoryPath: homeDirectoryPath) {
            return .denied(reasonForModel: "\(displayedName) is inside a protected folder.")
        }
        let rootComponentLists = rootComponentLists(of: scope)
        if rootComponentLists.contains(where: { $0 == pathComponents }) {
            return .denied(reasonForModel: "\(displayedName) is a scope folder itself; only what is inside it can change.")
        }
        let isStrictlyInsideAnyRoot = rootComponentLists.contains { rootComponents in
            pathComponents.count > rootComponents.count && isComponentList(pathComponents, equalToOrInside: rootComponents)
        }
        guard isStrictlyInsideAnyRoot else {
            return .denied(reasonForModel: "\(displayedName) is outside the scope folders. Only files inside the folders listed in the first message can change.")
        }
        if isInsidePackage {
            return .denied(reasonForModel: "\(displayedName) is inside a package (an app or library bundle); change the package as a whole instead.")
        }
        return .allowed
    }

    /// The root that contains the path (the root itself included), the deepest one when roots nest.
    static func containingRoot(ofCanonicalPath canonicalPath: String, scope: DirectRouteScope) -> DirectRouteScopeRoot? {
        guard let pathComponents = normalizedComponents(ofCanonicalPath: UploadFileAllowlist.normalizedPath(canonicalPath)) else {
            return nil
        }
        return scope.roots
            .compactMap { root -> (root: DirectRouteScopeRoot, componentCount: Int)? in
                guard let rootComponents = normalizedComponents(ofCanonicalPath: UploadFileAllowlist.normalizedPath(root.canonicalPath)),
                      isComponentList(pathComponents, equalToOrInside: rootComponents) else { return nil }
                return (root, rootComponents.count)
            }
            .max { $0.componentCount < $1.componentCount }?.root
    }

    /// The components of an absolute path without its leading empty component, or nil when the path is relative or
    /// has an empty, "." or ".." component (a trailing "/" counts as an empty component). "/" itself yields nil.
    static func normalizedComponents(ofCanonicalPath canonicalPath: String) -> [Substring]? {
        guard canonicalPath.hasPrefix("/") else { return nil }
        let pathComponents = Array(canonicalPath.split(separator: "/", omittingEmptySubsequences: false).dropFirst())
        guard !pathComponents.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        return pathComponents
    }

    static func isComponentList(_ pathComponents: [Substring], equalToOrInside ancestorComponents: [Substring]) -> Bool {
        pathComponents.count >= ancestorComponents.count && Array(pathComponents.prefix(ancestorComponents.count)) == ancestorComponents
    }

    private static func rootComponentLists(of scope: DirectRouteScope) -> [[Substring]] {
        scope.roots.compactMap { normalizedComponents(ofCanonicalPath: UploadFileAllowlist.normalizedPath($0.canonicalPath)) }
    }

    private static func isProtectedOrHomeLibraryFolder(_ pathComponents: [Substring], homeDirectoryPath: String) -> Bool {
        ProtectedPathPolicy.isProtected(normalizedPathComponents: pathComponents, homeDirectoryPath: homeDirectoryPath)
            || ProtectedPathPolicy.isHomeLibraryFolder(normalizedPathComponents: pathComponents, homeDirectoryPath: homeDirectoryPath)
    }

    private static func displayedName(ofPath path: String) -> String {
        "“\((path as NSString).lastPathComponent)”"
    }
}
