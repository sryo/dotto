import Foundation

/// Paths no upload and no file operation may ever touch, whoever granted the folder around them: credential stores,
/// app data under any home's Library folder, and Dotto's own records.
enum ProtectedPathPolicy {
    /// Protected at any depth. Browser credential stores are listed by file name because Chrome profiles can live
    /// outside ~/Library.
    static let deniedPathComponents: Set<String> = [".ssh", ".gnupg", ".aws", ".kube", ".docker", ".netrc",
        "Keychains", "Cookies", ".config", ".password-store", "1Password", "Bitwarden",
        "Login Data", "Login Data For Account", "Web Data", "Local State"]

    /// `normalizedPathComponents` are the components of an absolute path after `UploadFileAllowlist.normalizedPath`,
    /// without the leading empty component.
    static func isProtected(normalizedPathComponents: [Substring], homeDirectoryPath: String) -> Bool {
        normalizedPathComponents.contains { deniedPathComponents.contains(String($0)) }
            || isInsideProtectedLibraryFolder(normalizedPathComponents: normalizedPathComponents, homeDirectoryPath: homeDirectoryPath)
    }

    /// A home's Library folder itself ("<home>/Library", or "Users/<name>/Library" at any depth). Everything inside it
    /// is protected, so a folder operation on the folder itself (a scope root, a move) is refused too.
    static func isHomeLibraryFolder(normalizedPathComponents: [Substring], homeDirectoryPath: String) -> Bool {
        let homeComponents = UploadFileAllowlist.normalizedPath(homeDirectoryPath).split(separator: "/")
        if !homeComponents.isEmpty, normalizedPathComponents.count == homeComponents.count + 1,
           Array(normalizedPathComponents.prefix(homeComponents.count)) == homeComponents,
           normalizedPathComponents[homeComponents.count] == "Library" {
            return true
        }
        return normalizedPathComponents.indices.contains { usersComponentIndex in
            normalizedPathComponents[usersComponentIndex] == "Users"
                && normalizedPathComponents.count == usersComponentIndex + 3
                && normalizedPathComponents[usersComponentIndex + 2] == "Library"
        }
    }

    /// `<home>/Library/…` for the current home, and "Users/<name>/Library/…" at any depth (another volume's or the
    /// data volume's copy of a home), plus any "Application Support/Dotto" folder, wherever the canonicalizer resolved it.
    private static func isInsideProtectedLibraryFolder(normalizedPathComponents: [Substring], homeDirectoryPath: String) -> Bool {
        let homeComponents = UploadFileAllowlist.normalizedPath(homeDirectoryPath).split(separator: "/")
        if !homeComponents.isEmpty, normalizedPathComponents.count > homeComponents.count + 1,
           Array(normalizedPathComponents.prefix(homeComponents.count)) == homeComponents,
           normalizedPathComponents[homeComponents.count] == "Library" {
            return true
        }
        let isInsideAnyUsersLibrary = normalizedPathComponents.indices.contains { usersComponentIndex in
            normalizedPathComponents[usersComponentIndex] == "Users"
                && normalizedPathComponents.count > usersComponentIndex + 3
                && normalizedPathComponents[usersComponentIndex + 2] == "Library"
        }
        if isInsideAnyUsersLibrary { return true }
        return zip(normalizedPathComponents, normalizedPathComponents.dropFirst()).contains { $0 == "Application Support" && $1 == "Dotto" }
    }
}
