import Foundation
import CoreGraphics

/// Each running task draws its cursor, pill, ripples and checklist accents in its own color, so the user can tell up
/// to three tasks apart at a glance. The first task always gets the owner's task color; red stays reserved for errors.
enum TaskColorPalette {
    /// Chosen to be told apart from each other and from the owner's default orange, and never red.
    static let additionalTaskColorHexes = ["#2F7BF5", "#1FA37A"]

    /// The owner's color, then the palette's, in order.
    static func taskColorHexes(ownerTaskColorHex: String) -> [String] {
        [ownerTaskColorHex] + additionalTaskColorHexes.filter { $0.caseInsensitiveCompare(ownerTaskColorHex) != .orderedSame }
    }

    /// The first color no other running task uses; with every color taken, the one used least.
    static func colorHex(forNewTaskWithOwnerTaskColorHex ownerTaskColorHex: String, colorHexesInUse: [String]) -> String {
        let candidateColorHexes = taskColorHexes(ownerTaskColorHex: ownerTaskColorHex)
        func useCount(of colorHex: String) -> Int {
            colorHexesInUse.filter { $0.caseInsensitiveCompare(colorHex) == .orderedSame }.count
        }
        return candidateColorHexes.first { useCount(of: $0) == 0 }
            ?? candidateColorHexes.min { useCount(of: $0) < useCount(of: $1) }
            ?? ownerTaskColorHex
    }
}
