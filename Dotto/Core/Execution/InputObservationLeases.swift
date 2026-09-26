import Foundation
import CoreGraphics

/// Who needs the user's real input observed right now: each running task and a demonstration being recorded hold a
/// lease. The one event tap runs while any lease is held, so one task ending never switches off takeover detection
/// or the real-input count (which refuses foreground-assist input while unknown) for the others.
struct InputObservationLeases: Equatable, Sendable {
    enum ObservationRequirement: Equatable, Sendable {
        case none
        case clicksScrollsAndKeys
        /// Recording a demonstration also needs pointer moves and drags.
        case includingPointerMoves
    }

    private(set) var includesPointerMovesByHolderIdentifier: [String: Bool] = [:]

    var requirement: ObservationRequirement {
        if includesPointerMovesByHolderIdentifier.isEmpty { return .none }
        return includesPointerMovesByHolderIdentifier.values.contains(true) ? .includingPointerMoves : .clicksScrollsAndKeys
    }

    /// Taking a lease again under the same holder replaces it.
    mutating func take(holderIdentifier: String, includingPointerMoves: Bool) {
        includesPointerMovesByHolderIdentifier[holderIdentifier] = includingPointerMoves
    }

    mutating func end(holderIdentifier: String) {
        includesPointerMovesByHolderIdentifier[holderIdentifier] = nil
    }

    mutating func endAll() {
        includesPointerMovesByHolderIdentifier = [:]
    }
}
