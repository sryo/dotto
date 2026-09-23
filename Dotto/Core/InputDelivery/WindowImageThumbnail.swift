import Foundation

/// The task window drawn into a small grayscale grid, to tell whether input changed anything in apps that show
/// little or nothing to Accessibility (Zed, games, canvas apps). Fine enough to see a typed word, a new tab or a
/// highlighted button; a blinking text caret touches about one cell, so one or two changed cells never count.
struct WindowImageThumbnail: Equatable, Sendable {
    static let sideLengthInCells = 64
    /// Mean gray-level change of a cell (0–255) for it to count as changed.
    static let changedCellMinimumDifference = 12
    static let changedCellMinimumCount = 3

    /// Row-major, `sideLengthInCells`² bytes.
    var grayscaleCells: [UInt8]

    init?(grayscaleCells: [UInt8]) {
        guard grayscaleCells.count == Self.sideLengthInCells * Self.sideLengthInCells else { return nil }
        self.grayscaleCells = grayscaleCells
    }

    func changedCellCount(comparedWith otherThumbnail: WindowImageThumbnail) -> Int {
        zip(grayscaleCells, otherThumbnail.grayscaleCells).reduce(0) { changedCellCount, cellPair in
            abs(Int(cellPair.0) - Int(cellPair.1)) >= Self.changedCellMinimumDifference ? changedCellCount + 1 : changedCellCount
        }
    }

    func showsChange(comparedWith otherThumbnail: WindowImageThumbnail) -> Bool {
        changedCellCount(comparedWith: otherThumbnail) >= Self.changedCellMinimumCount
    }
}
