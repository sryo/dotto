import Foundation

private let homeDirectoryPath = "/Users/me"
private let screenshotsScope = DirectRouteScope(roots: [
    DirectRouteScopeRoot(canonicalPath: "/Users/me/Desktop/Screenshots", source: .finderWindowUnderSummonPoint),
])

private func isAccepted(_ canonicalFolderPath: String, isPackage: Bool = false) -> Bool {
    if case .accepted = FileOperationScopePolicy.evaluateScopeRootCandidate(canonicalFolderPath: canonicalFolderPath, source: .typedInCommand,
                                                                             isPackage: isPackage, homeDirectoryPath: homeDirectoryPath) {
        return true
    }
    return false
}

private func isReadable(_ canonicalPath: String, scope: DirectRouteScope = screenshotsScope) -> Bool {
    FileOperationScopePolicy.evaluateReadablePath(canonicalPath, scope: scope, homeDirectoryPath: homeDirectoryPath) == .allowed
}

private func isChangeable(_ canonicalPath: String, scope: DirectRouteScope = screenshotsScope, isInsidePackage: Bool = false) -> Bool {
    FileOperationScopePolicy.evaluateChangeablePath(canonicalPath, scope: scope, homeDirectoryPath: homeDirectoryPath,
                                                    isInsidePackage: isInsidePackage) == .allowed
}

let fileOperationScopePolicyTestSuite = CoreTestSuite(name: "FileOperationScopePolicy", testCases: [
    CoreTestCase(name: "a folder below the home folder or below a named volume folder is an accepted root") {
        try expectEqual(FileOperationScopePolicy.evaluateScopeRootCandidate(
            canonicalFolderPath: "/Users/me/Desktop/Screenshots", source: .finderWindowUnderSummonPoint, isPackage: false,
            homeDirectoryPath: homeDirectoryPath),
                        .accepted(DirectRouteScopeRoot(canonicalPath: "/Users/me/Desktop/Screenshots", source: .finderWindowUnderSummonPoint)))
        try expectTrue(isAccepted("/Users/me/Desktop"))
        try expectTrue(isAccepted("/Volumes/Backup/Photos"))
    },
    CoreTestCase(name: "whole-disk, system, other users', Library, Dotto's own and package roots are refused") {
        for refusedPath in ["/", "/Users", "/Users/me", "/Volumes", "/Volumes/Backup", "/Applications", "/System", "/Library",
                            "/private/tmp", "/usr/local", "/etc", "/opt/homebrew", "/Users/other/Documents", "/Users/me/Library",
                            "/Users/me/Library/Mobile Documents", "/Users/me/Documents/Application Support/Dotto",
                            "/Volumes/Backup/Users/me/Library/Mail", "/Users/me/.ssh", "/Users/me/.dotfiles", "Users/me/Desktop",
                            "/Users/me/Desktop/../Library"] {
            try expectTrue(!isAccepted(refusedPath), refusedPath)
        }
        try expectTrue(!isAccepted("/Users/me/Pictures/Photos Library.photoslibrary", isPackage: true))
    },
    CoreTestCase(name: "the data volume's spelling of a path is judged as its plain spelling") {
        try expectTrue(isAccepted("/System/Volumes/Data/Users/me/Desktop/Shots"))
        try expectTrue(!isAccepted("/System/Volumes/Data/Users/me"))
        try expectTrue(isReadable("/System/Volumes/Data/Users/me/Desktop/Screenshots/a.png"))
    },
    CoreTestCase(name: "inside is component-wise, never a string prefix") {
        try expectTrue(isReadable("/Users/me/Desktop/Screenshots/a.png"))
        try expectTrue(!isReadable("/Users/me/Desktop/Screenshots-private/a.png"))
        try expectTrue(!isChangeable("/Users/me/Desktop/Screenshots-private/a.png"))
    },
    CoreTestCase(name: "the root itself is readable but never changeable") {
        try expectTrue(isReadable("/Users/me/Desktop/Screenshots"))
        try expectTrue(!isChangeable("/Users/me/Desktop/Screenshots"))
        try expectTrue(isChangeable("/Users/me/Desktop/Screenshots/2026-09/a.png"))
    },
    CoreTestCase(name: "protected components stay protected at any depth inside a root") {
        let homeSubfolderScope = DirectRouteScope(roots: [DirectRouteScopeRoot(canonicalPath: "/Users/me/Projects", source: .attachedByUser)])
        for protectedPath in ["/Users/me/Projects/.ssh/id_rsa", "/Users/me/Projects/x/Keychains/login.keychain-db",
                              "/Users/me/Projects/Chrome/Default/Login Data", "/Users/me/Projects/.config/tool"] {
            try expectTrue(!isReadable(protectedPath, scope: homeSubfolderScope), protectedPath)
            try expectTrue(!isChangeable(protectedPath, scope: homeSubfolderScope), protectedPath)
        }
    },
    CoreTestCase(name: "paths with dot components, relative paths and paths inside packages are not changeable") {
        try expectTrue(!isChangeable("/Users/me/Desktop/Screenshots/../Other/a.png"))
        try expectTrue(!isChangeable("/Users/me/Desktop/Screenshots/./a.png"))
        try expectTrue(!isChangeable("Users/me/Desktop/Screenshots/a.png"))
        try expectTrue(!isChangeable("/Users/me/Desktop/Screenshots/App.app/Contents/Info.plist", isInsidePackage: true))
        try expectTrue(isChangeable("/Users/me/Desktop/Screenshots/App.app"))
    },
    CoreTestCase(name: "the deepest containing root is found for nested roots") {
        let nestedScope = DirectRouteScope(roots: [
            DirectRouteScopeRoot(canonicalPath: "/Users/me/Desktop", source: .typedInCommand),
            DirectRouteScopeRoot(canonicalPath: "/Users/me/Desktop/Screenshots", source: .finderWindowUnderSummonPoint),
        ])
        try expectEqual(FileOperationScopePolicy.containingRoot(ofCanonicalPath: "/Users/me/Desktop/Screenshots/a.png", scope: nestedScope)?.source,
                        .finderWindowUnderSummonPoint)
        try expectEqual(FileOperationScopePolicy.containingRoot(ofCanonicalPath: "/Users/me/Desktop/b.png", scope: nestedScope)?.source,
                        .typedInCommand)
        try expectTrue(FileOperationScopePolicy.containingRoot(ofCanonicalPath: "/Users/me/Documents/b.png", scope: nestedScope) == nil)
    },
])

let protectedPathPolicyTestSuite = CoreTestSuite(name: "ProtectedPathPolicy", testCases: [
    CoreTestCase(name: "credential components, Library contents and Dotto's records are protected; ordinary folders are not") {
        func isProtected(_ path: String) -> Bool {
            ProtectedPathPolicy.isProtected(normalizedPathComponents: Array(path.split(separator: "/")), homeDirectoryPath: homeDirectoryPath)
        }
        try expectTrue(isProtected("/Users/me/.ssh/id_rsa"))
        try expectTrue(isProtected("/Users/me/Library/Mail/V10/x.emlx"))
        try expectTrue(isProtected("/Volumes/Old/Users/bob/Library/Cookies/x"))
        try expectTrue(isProtected("/Volumes/Data/Application Support/Dotto/key.json"))
        try expectTrue(!isProtected("/Users/me/Desktop/Screenshots/a.png"))
        // The Library folder itself holds no file to upload; file operations refuse it through isHomeLibraryFolder.
        try expectTrue(!isProtected("/Users/me/Library"))
        try expectTrue(ProtectedPathPolicy.isHomeLibraryFolder(normalizedPathComponents: ["Users", "me", "Library"], homeDirectoryPath: homeDirectoryPath))
        try expectTrue(ProtectedPathPolicy.isHomeLibraryFolder(normalizedPathComponents: ["Volumes", "Old", "Users", "bob", "Library"],
                                                               homeDirectoryPath: homeDirectoryPath))
    },
    CoreTestCase(name: "uploads keep the same denied components after the extraction") {
        try expectEqual(UploadFileAllowlist.deniedPathComponents, ProtectedPathPolicy.deniedPathComponents)
        try expectTrue(ProtectedPathPolicy.deniedPathComponents.isSuperset(of: [".ssh", "Keychains", "Login Data", "1Password"]))
    },
])
