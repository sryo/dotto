import Foundation

/// What one tool call in an item showed about the app, as far as the stall check cares.
enum AgentStepProgress: Equatable, Sendable {
    /// An action that changed something visible, a met expectation, or a wait_for that found its text.
    case changedSomething
    /// An action that changed nothing visible or wasn't delivered, a wait_for that timed out, or a read_ui query with
    /// no matches.
    case changedNothing(isAction: Bool)
    /// Says nothing about progress: a read_ui without a query or with matches, a screenshot, an error about Dotto's own
    /// bookkeeping (a stale id, a pause).
    case neutral
}

/// Ends an item whose steps keep changing nothing, instead of letting the model search, wait and click for minutes.
/// Reads and waits count only once the item has acted: before its first action the model is still finding its way.
struct ChecklistItemStallPolicy: Equatable, Sendable {
    static let standardMaximumConsecutiveStepsWithoutChange = 4
    static let stalledItemSummary = "Nothing changed after the last \(standardMaximumConsecutiveStepsWithoutChange) steps."

    var maximumConsecutiveStepsWithoutChange = Self.standardMaximumConsecutiveStepsWithoutChange
    private(set) var consecutiveStepsWithoutChange = 0
    private(set) var itemHasActed = false

    mutating func record(_ stepProgress: AgentStepProgress) {
        switch stepProgress {
        case .changedSomething:
            itemHasActed = true
            consecutiveStepsWithoutChange = 0
        case .changedNothing(let isAction):
            if isAction { itemHasActed = true }
            if itemHasActed { consecutiveStepsWithoutChange += 1 }
        case .neutral:
            break
        }
    }

    var itemHasStalled: Bool { consecutiveStepsWithoutChange >= maximumConsecutiveStepsWithoutChange }
}
