import AppKit

/// What the executor reports about the run, reached only through the run's TaskRunDelegateBridge, so a stopped run
/// that is still unwinding never updates a newer task.
extension TaskSessionController {
    func taskExecutionDidStartItem(itemIdentifier: String) {
        apply(.itemStarted(itemIdentifier: itemIdentifier))
        let itemLabel = labelOfItem(withIdentifier: itemIdentifier) ?? ""
        statusLine = "\(itemPositionDescription(forItemIdentifier: itemIdentifier)): \(itemLabel)"
    }

    func taskExecutionDidReportProgress(itemIdentifier: String, progressDescription: String) {
        apply(.itemProgressed(itemIdentifier: itemIdentifier))
        statusLine = "\(itemPositionDescription(forItemIdentifier: itemIdentifier)): \(progressDescription)"
    }

    func taskExecutionDidFinishItem(itemIdentifier: String, runStatus: ChecklistItemRunStatus, resultSummary: String) {
        apply(.itemFinished(itemIdentifier: itemIdentifier, runStatus: runStatus, resultSummary: resultSummary))
        cursorController.handle(.itemFinished(runStatus))
    }

    func taskExecutionDidReportCursorActivity(_ cursorActivityEvent: CursorActivityEvent) {
        recordDirectRouteProgress(from: cursorActivityEvent)
        cursorController.handle(cursorActivityEvent)
    }

    /// The routine replays for the rest of this task right away; it reaches the library only if the user saves it
    /// after reviewing it.
    func taskExecutionDidUpdateRoutine(_ routine: Routine, wasNewlyLearned: Bool) {
        attachedRoutine = routine
        learnedRoutineAwaitingReview = routine
        if wasNewlyLearned {
            statusLine = "Learned a routine — replaying the remaining items"
        }
    }

    func taskExecutionDidUpdateMetrics(_ metrics: TaskRunMetrics) {
        currentRunMetrics = metrics
    }

    private func labelOfItem(withIdentifier itemIdentifier: String) -> String? {
        sessionState.currentChecklist?.items.first(where: { $0.itemIdentifier == itemIdentifier })?.label
    }

    private func itemPositionDescription(forItemIdentifier itemIdentifier: String) -> String {
        guard let includedItems = sessionState.currentChecklist?.includedItems,
              let zeroBasedItemPosition = includedItems.firstIndex(where: { $0.itemIdentifier == itemIdentifier }) else {
            return "Item"
        }
        return "Item \(zeroBasedItemPosition + 1) of \(includedItems.count)"
    }
}
