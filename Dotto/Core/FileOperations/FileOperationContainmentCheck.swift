import Foundation

/// The run-time half of keeping file operations in scope. The dry run checks paths as text, so if a folder on an
/// operand's path is swapped for a symbolic link (or moved) after it, the kernel would follow that link somewhere
/// else. Right before each change the operand's parent folder is resolved with realpath, and the change goes ahead
/// only when that real folder is the one the plan named, lies inside a scope root, and isn't protected.
enum FileOperationContainmentCheck {
    /// nil when the change may go ahead, else Dotto's reason (basenames only). `resolvedParentPath` is the realpath of
    /// the operand's parent, nil when it doesn't exist.
    static func problem(operandPath: String, resolvedParentPath: String?, scope: DirectRouteScope,
                        homeDirectoryPath: String) -> String? {
        let normalizedOperandPath = UploadFileAllowlist.normalizedPath(operandPath)
        let operandName = FileOperationPathRules.name(of: normalizedOperandPath)
        let displayedName = "“\(operandName)”"
        let plannedParentPath = FileOperationPathRules.parentPath(of: normalizedOperandPath)
        guard let resolvedParentPath else {
            return "\(displayedName): its folder is no longer there."
        }
        let normalizedResolvedParentPath = UploadFileAllowlist.normalizedPath(resolvedParentPath)
        // Compared by collision key: realpath spells names as they are on disk, the plan as the model wrote them.
        guard FileOperationPathRules.collisionKey(forPath: normalizedResolvedParentPath)
                == FileOperationPathRules.collisionKey(forPath: plannedParentPath) else {
            return "\(displayedName): its folder now leads somewhere else (a link or a moved folder), so Dotto left it alone."
        }
        guard let resolvedParentComponents = FileOperationScopePolicy.normalizedComponents(ofCanonicalPath: normalizedResolvedParentPath) else {
            return "\(displayedName): its folder is outside the scope folders."
        }
        let isParentInsideAnyRoot = scope.roots.contains { root in
            guard let rootComponents = FileOperationScopePolicy.normalizedComponents(
                ofCanonicalPath: UploadFileAllowlist.normalizedPath(root.canonicalPath)) else { return false }
            return FileOperationScopePolicy.isComponentList(resolvedParentComponents, equalToOrInside: rootComponents)
        }
        guard isParentInsideAnyRoot else {
            return "\(displayedName): its folder is outside the scope folders."
        }
        let resolvedOperandComponents = resolvedParentComponents + [Substring(operandName)]
        if ProtectedPathPolicy.isProtected(normalizedPathComponents: resolvedOperandComponents, homeDirectoryPath: homeDirectoryPath)
            || ProtectedPathPolicy.isHomeLibraryFolder(normalizedPathComponents: resolvedOperandComponents, homeDirectoryPath: homeDirectoryPath) {
            return "\(displayedName) is inside a protected folder."
        }
        return nil
    }

    /// Resolves the parent through the file system and applies `problem(…)`.
    static func problem(operandPath: String, fileSystem: FileSystemMutating, scope: DirectRouteScope,
                        homeDirectoryPath: String) -> String? {
        let parentPath = FileOperationPathRules.parentPath(of: UploadFileAllowlist.normalizedPath(operandPath))
        return problem(operandPath: operandPath, resolvedParentPath: fileSystem.fullyResolvedPath(ofExistingPath: parentPath),
                       scope: scope, homeDirectoryPath: homeDirectoryPath)
    }
}
