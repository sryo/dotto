import SwiftUI

/// "Undo “Sort screenshots by month” · 27 changes · 2 min ago" with an Undo button: the newest direct-route task
/// that can still be undone, for a day after it ran. A task Dotto was interrupted in (a quit or a crash) is offered
/// too, since its journal still says what it did, and so is one an earlier undo reverted only part of.
struct UndoLastTaskRow: View {
    @ObservedObject var taskSessionController: TaskSessionController
    @ObservedObject var directRouteSessionState: DirectRouteSessionState

    var body: some View {
        if directRouteSessionState.undoIsRunning {
            DirectRouteUndoProgressLine(undoProgress: directRouteSessionState.undoProgress,
                                        onStop: { directRouteSessionState.stopUndo() })
                .padding(.vertical, 4)
        } else if let undoableJournal = directRouteSessionState.mostRecentUndoableJournal,
                  Date().timeIntervalSince(undoableJournal.finishedAt) < UndoableJournalSummary.maximumOfferedAgeSeconds,
                  !taskSessionController.sessionState.isBusy {
            row(for: undoableJournal)
        } else if let undoReport = directRouteSessionState.lastUndoReport, !taskSessionController.sessionState.isBusy {
            DirectRouteUndoReportView(undoReport: undoReport)
                .padding(.vertical, 4)
        }
    }

    private func row(for undoableJournal: UndoableJournalSummary) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "arrow.uturn.backward.circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(undoableJournal.wasInterrupted ? DesignSystem.Colors.warningText : DesignSystem.Colors.textTertiary)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(undoableJournal.wasInterrupted
                     ? "Dotto stopped while doing “\(undoableJournal.taskTitle)”. Undo what it did?"
                     : undoableJournal.wasPartiallyUndone
                        ? "Undo the rest of “\(undoableJournal.taskTitle)”"
                        : "Undo “\(undoableJournal.taskTitle)”")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DesignSystem.Colors.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detailText(for: undoableJournal))
                    .font(.system(size: 10))
                    .foregroundColor(DesignSystem.Colors.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button("Undo") {
                taskSessionController.undoDirectRouteTask(journalIdentifier: undoableJournal.journalIdentifier)
            }
            .dsTextButtonStyle()
            .disabled(directRouteSessionState.isUndoInProgress)
            .nativeTooltip("Put every file back where it was")
        }
        .padding(.vertical, 4)
    }

    /// "27 changes · 2 min ago", or "3 changes left · 2 min ago" after a partial undo.
    private func detailText(for undoableJournal: UndoableJournalSummary) -> String {
        var changeCountText = undoableJournal.changeCount == 1 ? "1 change" : "\(undoableJournal.changeCount) changes"
        if undoableJournal.wasPartiallyUndone { changeCountText += " left" }
        let relativeDateFormatter = RelativeDateTimeFormatter()
        relativeDateFormatter.unitsStyle = .short
        let agoText = relativeDateFormatter.localizedString(for: undoableJournal.finishedAt, relativeTo: Date())
        return "\(changeCountText) · \(agoText)"
    }
}
