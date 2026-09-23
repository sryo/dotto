import Foundation

/// Name rules for files and folders Dotto creates, and the collision key and suffixing that keep it from ever
/// overwriting anything.
enum FileOperationPathRules {
    static let maximumNameByteCount = 255
    static let maximumSuffixAttempt = 99
    /// Files Finder writes into any folder it shows ("Icon\r" holds a custom folder icon). They are not the user's
    /// content, so a folder holding only these still counts as empty when undo removes a folder Dotto created.
    static let finderMetadataFileNames: Set<String> = [".DS_Store", "Icon\r"]

    /// Non-empty, not "." or "..", no "/" ":" NUL or control characters, no leading or trailing whitespace,
    /// ≤ 255 UTF-8 bytes, not starting with "." (Dotto never creates hidden names) unless unchanged from the source.
    /// Returns nil when the name is fine, else the reason.
    static func validateNewName(_ name: String, sourceName: String?) -> String? {
        let displayedName = "“\(name)”"
        if name.isEmpty { return "A new name can't be empty." }
        if name == "." || name == ".." { return "\(displayedName) isn't a valid name." }
        if name.contains("/") || name.contains(":") {
            return "\(displayedName) contains “/” or “:”, which macOS doesn't allow in names."
        }
        if name.unicodeScalars.contains(where: isControlScalar) {
            return "\(displayedName) contains a control character."
        }
        if name.first?.isWhitespace == true || name.last?.isWhitespace == true {
            return "\(displayedName) starts or ends with a space."
        }
        if name.utf8.count > maximumNameByteCount {
            return "\(displayedName) is longer than \(maximumNameByteCount) bytes."
        }
        if name.hasPrefix("."), name != sourceName {
            return "\(displayedName) starts with “.”, which would hide it. Dotto never creates hidden names."
        }
        return nil
    }

    /// APFS is normalization-insensitive and case-insensitive by default: the key is NFD + case-folded. On a
    /// case-sensitive volume this only makes the collision check stricter (an extra " 2"), never looser.
    static func collisionKey(forPath path: String) -> String {
        path.decomposedStringWithCanonicalMapping.lowercased().decomposedStringWithCanonicalMapping
    }

    /// "IMG_1.png" → "IMG_1 2.png", "IMG_1 3.png"…; folders and extensionless names get " 2" at the end. Only the
    /// last extension counts ("archive.tar.gz" → "archive.tar 2.gz"). Packages count their extension (.app, .bundle)
    /// as an extension, so only plain folders pass `isPlainFolder`.
    static func suffixedPath(_ path: String, attempt: Int, isPlainFolder: Bool = false) -> String {
        let parentPath = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let suffixedName: String
        if !isPlainFolder, let extensionSeparatorIndex = name.lastIndex(of: "."),
           extensionSeparatorIndex != name.startIndex, name.index(after: extensionSeparatorIndex) != name.endIndex {
            let nameStem = name[name.startIndex..<extensionSeparatorIndex]
            let nameExtension = name[extensionSeparatorIndex...]
            suffixedName = "\(nameStem) \(attempt)\(nameExtension)"
        } else {
            suffixedName = "\(name) \(attempt)"
        }
        return (parentPath as NSString).appendingPathComponent(suffixedName)
    }

    /// Splits "/a/b/new1/new2" into ("/a/b", ["new1", "new2"]) given an existence probe. "/" always exists.
    static func splitAtNearestExistingAncestor(_ path: String, exists: (String) -> Bool)
        -> (existingAncestorPath: String, missingComponents: [String]) {
        var existingAncestorPath = path
        var missingComponents: [String] = []
        while existingAncestorPath != "/" && !existingAncestorPath.isEmpty && !exists(existingAncestorPath) {
            missingComponents.insert((existingAncestorPath as NSString).lastPathComponent, at: 0)
            existingAncestorPath = (existingAncestorPath as NSString).deletingLastPathComponent
        }
        return (existingAncestorPath.isEmpty ? "/" : existingAncestorPath, missingComponents)
    }

    /// C0 and C1 control characters (NUL, tab, newline, DEL…). Format characters such as the zero-width joiner inside
    /// emoji are not controls and stay allowed.
    static func isControlScalar(_ unicodeScalar: Unicode.Scalar) -> Bool {
        unicodeScalar.value < 0x20 || (0x7F...0x9F).contains(unicodeScalar.value)
    }

    static func parentPath(of path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    static func name(of path: String) -> String {
        (path as NSString).lastPathComponent
    }
}
