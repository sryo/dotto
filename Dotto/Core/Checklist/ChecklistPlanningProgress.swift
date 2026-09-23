import Foundation

/// What the planner is doing right now. The checklist panel's status line and the cursor's pill both follow it,
/// so it is a value rather than a sentence: each surface words it its own way.
enum ChecklistPlanningProgress: Equatable, Sendable {
    case readingApplication(applicationName: String)
    case takingScreenshot
    /// A folder the planner lists or reads file details from (direct routes).
    case readingFolder(folderName: String)
    case thinking
    /// The planner is writing its checklist (submit_plan streams in); the count is items written so far. Writing a
    /// long checklist takes a while, so the pill says it is under way instead of showing a bare "Planning…".
    case writingChecklist(itemsWrittenSoFar: Int)

    /// The status line the menu bar panel and the checklist card show.
    var statusLineText: String {
        switch self {
        case .readingApplication(let applicationName): return "Reading \(applicationName)…"
        case .takingScreenshot: return "Taking a screenshot…"
        case .readingFolder(let folderName): return "Reading “\(folderName)”…"
        case .thinking: return "Thinking…"
        case .writingChecklist(let itemsWrittenSoFar):
            return "Planning… (\(itemsWrittenSoFar) \(itemsWrittenSoFar == 1 ? "item" : "items") written)"
        }
    }
}
