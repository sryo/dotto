import CoreGraphics
import Foundation

/// The folder a Finder window shows and the items selected in it.
struct FinderWindowContents: Equatable, Sendable {
    var folderPath: String
    /// POSIX paths of the items selected in that window; empty when it isn't Finder's front window.
    var selectedItemPaths: [String]
}

/// Parses the output of Dotto's fixed Finder windows script: "W<tab>left,top,right,bottom<tab>POSIX path" per window,
/// front to back, then "S<tab>POSIX path" per item selected in Finder's front window.
enum FinderWindowScriptOutput {
    /// Finder's `bounds` are top-left global points, like the summon point. Window lines come front to back, and
    /// Finder's `selection` belongs to its front window, so the selection counts only when the chosen window is that
    /// one, and only items directly inside its folder.
    static func chosenWindowContents(fromScriptOutputText outputText: String,
                                     summonOriginInTopLeftGlobalPoints: CGPoint?,
                                     accessibilityFolderPath: String?) -> FinderWindowContents? {
        var finderWindowTargets: [(bounds: CGRect, folderPath: String)] = []
        var selectedItemPaths: [String] = []
        for outputLine in outputText.split(whereSeparator: \.isNewline) {
            let lineParts = outputLine.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            if lineParts.count == 3 && lineParts[0] == "W" {
                let boundValues = lineParts[1].split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                guard boundValues.count == 4 else { continue }
                let windowBounds = CGRect(x: boundValues[0], y: boundValues[1],
                                          width: boundValues[2] - boundValues[0], height: boundValues[3] - boundValues[1])
                let folderPath = pathWithoutTrailingSlash(String(lineParts[2]))
                guard folderPath.hasPrefix("/") else { continue }
                finderWindowTargets.append((windowBounds, folderPath))
            } else if lineParts.count == 2 && lineParts[0] == "S" {
                let selectedItemPath = pathWithoutTrailingSlash(String(lineParts[1]))
                if selectedItemPath.hasPrefix("/") { selectedItemPaths.append(selectedItemPath) }
            }
        }

        let chosenWindowIndex: Int?
        if let accessibilityFolderPath {
            chosenWindowIndex = finderWindowTargets.firstIndex { $0.folderPath == accessibilityFolderPath }
        } else if let summonOriginInTopLeftGlobalPoints {
            chosenWindowIndex = finderWindowTargets.firstIndex { $0.bounds.contains(summonOriginInTopLeftGlobalPoints) }
        } else {
            chosenWindowIndex = finderWindowTargets.isEmpty ? nil : 0
        }
        guard let chosenWindowIndex else {
            return accessibilityFolderPath.map { FinderWindowContents(folderPath: $0, selectedItemPaths: []) }
        }
        let chosenFolderPath = finderWindowTargets[chosenWindowIndex].folderPath
        let selectedItemPathsInChosenFolder = chosenWindowIndex == 0
            ? selectedItemPaths.filter { (($0 as NSString).deletingLastPathComponent) == chosenFolderPath }
            : []
        return FinderWindowContents(folderPath: chosenFolderPath, selectedItemPaths: selectedItemPathsInChosenFolder)
    }

    private static func pathWithoutTrailingSlash(_ path: String) -> String {
        var trimmedPath = path
        if trimmedPath.count > 1 && trimmedPath.hasSuffix("/") { trimmedPath.removeLast() }
        return trimmedPath
    }
}
