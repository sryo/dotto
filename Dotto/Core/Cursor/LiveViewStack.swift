import Foundation
import CoreGraphics

/// The live views of several tasks whose windows are covered share one screen corner. Only one is expanded, showing
/// its window; the others are chips (the collapsed live view) stacked away from the corner, in the order they
/// appeared. A new live view is expanded only when no other is and the user hasn't collapsed it during its task; the
/// user expands a chip by toggling it, which collapses the one that was expanded.
struct LiveViewStack: Equatable, Sendable {
    static let spacingBetweenLiveViewsInPoints: CGFloat = 8

    private(set) var shownIdentifiersInOrder: [String] = []
    private(set) var expandedIdentifier: String?
    /// Live views the user collapsed; they come back as chips until their task ends (`forgetUserChoice`).
    private(set) var collapsedByUserIdentifiers: Set<String> = []

    mutating func show(_ identifier: String) {
        guard !shownIdentifiersInOrder.contains(identifier) else { return }
        shownIdentifiersInOrder.append(identifier)
        if expandedIdentifier == nil, !collapsedByUserIdentifiers.contains(identifier) { expandedIdentifier = identifier }
    }

    /// The others stay as they are: a chip the user collapsed doesn't spring open because another went away.
    mutating func hide(_ identifier: String) {
        shownIdentifiersInOrder.removeAll { $0 == identifier }
        if expandedIdentifier == identifier { expandedIdentifier = nil }
    }

    mutating func toggle(_ identifier: String) {
        guard shownIdentifiersInOrder.contains(identifier) else { return }
        if expandedIdentifier == identifier {
            expandedIdentifier = nil
            collapsedByUserIdentifiers.insert(identifier)
        } else {
            expandedIdentifier = identifier
            collapsedByUserIdentifiers.remove(identifier)
        }
    }

    /// The task ended: its next task's live view starts expanded again.
    mutating func forgetUserChoice(_ identifier: String) {
        collapsedByUserIdentifiers.remove(identifier)
    }

    func isCollapsed(_ identifier: String) -> Bool {
        expandedIdentifier != identifier
    }

    /// How far each shown live view sits from the corner: the heights of the ones before it, plus spacing.
    func stackOffsetsInPoints(heightsInPoints: [String: CGFloat]) -> [String: CGFloat] {
        var stackOffsets: [String: CGFloat] = [:]
        var nextOffset: CGFloat = 0
        for identifier in shownIdentifiersInOrder {
            stackOffsets[identifier] = nextOffset
            nextOffset += (heightsInPoints[identifier] ?? 0) + Self.spacingBetweenLiveViewsInPoints
        }
        return stackOffsets
    }
}
