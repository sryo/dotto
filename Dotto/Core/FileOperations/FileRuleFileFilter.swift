import Foundation

/// Which files a date folder rule or a rename rule applies to: the regular, non-hidden files directly inside the
/// source folder that pass every filter the rule sets. Shared so both rules pick files the same way.
struct FileRuleFileFilter: Equatable, Sendable {
    var sourceFolderPath: String
    var nameContains: String?
    var lowercasedExtensions: [String]
    var typeIdentifiers: [String]

    /// The filters that need only the name: extensions and name_contains (case-insensitive); never hidden names.
    /// Checked before any metadata is read, so files the rule can't match are never read.
    func nameMatches(_ fileName: String) -> Bool {
        if fileName.hasPrefix(".") { return false }
        let wantedExtensions = Set(lowercasedExtensions.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { !$0.isEmpty })
        if !wantedExtensions.isEmpty && !wantedExtensions.contains((fileName as NSString).pathExtension.lowercased()) { return false }
        let nameFilter = nameContains?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        if !nameFilter.isEmpty && !fileName.lowercased().contains(nameFilter) { return false }
        return true
    }

    /// A regular, non-hidden file directly inside the source folder that passes the name and type filters.
    func matches(_ entry: FileMetadataRecord) -> Bool {
        let fileName = FileOperationPathRules.name(of: entry.path)
        guard entry.kind == .regularFile, !entry.isHidden, !fileName.hasPrefix("."),
              FileOperationPathRules.collisionKey(forPath: FileOperationPathRules.parentPath(of: entry.path))
                == FileOperationPathRules.collisionKey(forPath: sourceFolderPath)
        else { return false }
        if !nameMatches(fileName) { return false }
        let wantedTypeIdentifiers = Set(typeIdentifiers.filter { !$0.isEmpty })
        if !wantedTypeIdentifiers.isEmpty {
            let entryTypeIdentifiers = Set(entry.conformingTypeIdentifiers + [entry.contentTypeIdentifier].compactMap { $0 })
            if wantedTypeIdentifiers.isDisjoint(with: entryTypeIdentifiers) { return false }
        }
        return true
    }
}
