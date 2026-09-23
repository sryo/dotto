import SwiftUI

/// A direct route while it runs: the overall count with a bar, and each group's own count. Opened from the pill's
/// chevron; the pill carries the same count while the popover is folded away.
struct DirectRouteProgressView: View {
    let checklist: Checklist
    let directRoutePlan: DirectRoutePlan
    @ObservedObject var directRouteSessionState: DirectRouteSessionState
    let statusLine: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            overallProgress
            if case .fileOperations(let fileOperationsPlan) = directRoutePlan {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(fileOperationsPlan.groups.enumerated()), id: \.element.groupIdentifier) { groupIndex, operationGroup in
                        groupProgressRow(operationGroup, groupIndex: groupIndex, fileOperationsPlan: fileOperationsPlan)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var overallProgress: some View {
        if let runProgress = directRouteSessionState.runProgress, runProgress.totalCount > 0 {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: Double(runProgress.completedCount), total: Double(runProgress.totalCount))
                    .progressViewStyle(.linear)
                    .tint(DesignSystem.Colors.accent)
                Text("\(runProgress.completedCount) / \(runProgress.totalCount) · \(runProgress.operationDescription)")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundColor(DesignSystem.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(statusLine)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DesignSystem.Colors.textSecondary)
                    .lineLimit(2)
            }
        }
    }

    private func groupProgressRow(_ operationGroup: FileOperationGroup, groupIndex: Int,
                                  fileOperationsPlan: FileOperationsPlan) -> some View {
        let groupOperationCount = fileOperationsPlan.operations.filter { $0.groupIdentifier == operationGroup.groupIdentifier }.count
        let completedGroupOperationCount = Self.completedOperationCount(inGroup: operationGroup.groupIdentifier,
                                                                        fileOperationsPlan: fileOperationsPlan,
                                                                        overallCompletedCount: directRouteSessionState.runProgress?.completedCount ?? 0)
        // One checklist item per group, in the plan's order.
        let groupItem = checklist.items.count == fileOperationsPlan.groups.count ? checklist.items[groupIndex] : nil
        return HStack(spacing: 6) {
            DirectRouteItemStatusIcon(runStatus: groupItem?.runStatus ?? .pending)
            Text(operationGroup.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DesignSystem.Colors.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text("\(completedGroupOperationCount) / \(groupOperationCount)")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundColor(DesignSystem.Colors.textTertiary)
        }
    }

    /// Operations run in the plan's order, so the first `overallCompletedCount` of them are the ones done so far.
    static func completedOperationCount(inGroup groupIdentifier: String, fileOperationsPlan: FileOperationsPlan,
                                        overallCompletedCount: Int) -> Int {
        fileOperationsPlan.operations.prefix(max(0, overallCompletedCount))
            .filter { $0.groupIdentifier == groupIdentifier }.count
    }
}

/// A direct route once it has ended: what changed and how long it took, what failed and why, a script's or
/// shortcut's output, and an undo in progress or its result.
struct DirectRouteResultView: View {
    let checklist: Checklist
    let directRoutePlan: DirectRoutePlan
    @ObservedObject var directRouteSessionState: DirectRouteSessionState

    private static let maximumListedFailureCount = 50

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let runReport = directRouteSessionState.lastRunReport {
                WrappingText(DirectRouteResultText.summary(of: runReport, plan: directRoutePlan), size: 13, weight: .medium,
                             color: DesignSystem.Colors.textPrimary)
                failureList(runReport)
                if let outputText = runReport.outputText, !outputText.isEmpty {
                    outputBox(outputText)
                }
                undoSection(runReport)
            } else {
                // Stopped before the executor handed back its report: the items say how far it got.
                WrappingText("Stopped. Some changes may already have been made.", size: 12)
            }
            itemFailureSummaries
            switch directRoutePlan {
            case .script(let scriptPlan):
                DirectRouteNoteLine(iconSystemName: "arrow.uturn.backward.circle", color: DesignSystem.Colors.textTertiary,
                                    text: "Dotto can't undo this. Check the result in \(scriptPlan.targetApplicationName).")
            case .shortcut:
                DirectRouteNoteLine(iconSystemName: "arrow.uturn.backward.circle", color: DesignSystem.Colors.textTertiary,
                                    text: "Dotto can't undo what a shortcut does. Check its result.")
            case .fileOperations:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func failureList(_ runReport: DirectRouteRunReport) -> some View {
        if !runReport.failures.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(runReport.failures.prefix(Self.maximumListedFailureCount).enumerated()), id: \.offset) { _, failure in
                    DirectRouteNoteLine(iconSystemName: "xmark.circle.fill", color: DesignSystem.Colors.destructiveText,
                                        text: failure.userFacingReason)
                }
            }
        }
    }

    /// When no operation failed on its own (the plan was refused as a whole, or a confirmation was declined), the
    /// items carry the reason.
    @ViewBuilder
    private var itemFailureSummaries: some View {
        let reportHasFailures = !(directRouteSessionState.lastRunReport?.failures.isEmpty ?? true)
        let failedItemSummaries = checklist.items.compactMap { item -> String? in
            guard item.runStatus == .failed, let resultSummary = item.resultSummary, !resultSummary.isEmpty else { return nil }
            return resultSummary
        }
        if !reportHasFailures, !failedItemSummaries.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(Set(failedItemSummaries)).sorted(), id: \.self) { failedItemSummary in
                    DirectRouteNoteLine(iconSystemName: "exclamationmark.triangle.fill", color: DesignSystem.Colors.warningText,
                                        text: failedItemSummary)
                }
            }
        }
    }

    /// Script and shortcut output is untrusted text: shown as plain monospaced text and nothing else.
    private func outputBox(_ outputText: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Output")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(DesignSystem.Colors.textTertiary)
            ScrollView {
                Text(verbatim: outputText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(DesignSystem.Colors.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(8)
            }
            .frame(maxHeight: 160)
            .fixedSize(horizontal: false, vertical: true)
            .background(RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.medium, style: .continuous)
                .fill(DesignSystem.Colors.surface1))
        }
    }

    @ViewBuilder
    private func undoSection(_ runReport: DirectRouteRunReport) -> some View {
        if let journalIdentifier = runReport.undoJournalIdentifier,
           directRouteSessionState.undoJournalIdentifier == journalIdentifier {
            if directRouteSessionState.undoIsRunning {
                DirectRouteUndoProgressLine(undoProgress: directRouteSessionState.undoProgress,
                                            onStop: { directRouteSessionState.stopUndo() })
            } else if let undoReport = directRouteSessionState.lastUndoReport {
                DirectRouteUndoReportView(undoReport: undoReport)
            }
            if let undoFailureMessage = directRouteSessionState.undoFailureMessage {
                WrappingText(undoFailureMessage, size: 12, color: DesignSystem.Colors.destructiveText)
            }
        }
    }
}

/// "Undoing… 12 / 27", or just "Undoing…" before the first count arrives, with Stop: what is left stays as it is
/// and can be undone later.
struct DirectRouteUndoProgressLine: View {
    let undoProgress: FileOperationProgress?
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(undoProgress.map { "Undoing… \($0.completedCount) / \($0.totalCount)" } ?? "Undoing…")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundColor(DesignSystem.Colors.textSecondary)
            Spacer(minLength: 4)
            Button("Stop", action: onStop)
                .dsTextButtonStyle()
                .nativeTooltip("Stop undoing; what is left stays as it is and can be undone later")
        }
    }
}

/// "Undone: 27 changes reverted", or what was reverted and what was left as it is, and why.
struct DirectRouteUndoReportView: View {
    let undoReport: FileOperationUndoReport

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if undoReport.skippedCount == 0 {
                DirectRouteNoteLine(iconSystemName: "arrow.uturn.backward.circle.fill", color: DesignSystem.Colors.success,
                                    text: undoReport.revertedCount == 1 ? "Undone: 1 change reverted"
                                                                        : "Undone: \(undoReport.revertedCount) changes reverted")
            } else {
                DirectRouteNoteLine(iconSystemName: "arrow.uturn.backward.circle", color: DesignSystem.Colors.warningText,
                                    text: "\(undoReport.revertedCount) reverted · \(undoReport.skippedCount) left as they are")
                ForEach(Array(undoReport.skippedReasons.enumerated()), id: \.offset) { _, skippedReason in
                    WrappingText(skippedReason, size: 11, color: DesignSystem.Colors.textTertiary)
                        .padding(.leading, 16)
                }
            }
        }
    }
}

/// The buttons under a finished direct route: Undo task, Show in Finder or Plan again, Open log and Done.
struct DirectRouteResultFooter: View {
    @ObservedObject var taskSessionController: TaskSessionController
    @ObservedObject var directRouteSessionState: DirectRouteSessionState
    let checklist: Checklist
    let directRoutePlan: DirectRoutePlan

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let undoableJournalIdentifier {
                Button(directRouteSessionState.lastUndoReport == nil ? "Undo task" : "Undo the rest") {
                    taskSessionController.undoDirectRouteTask(journalIdentifier: undoableJournalIdentifier)
                }
                    .dsOutlinedButtonStyle()
                    .disabled(directRouteSessionState.isUndoInProgress)
                    .nativeTooltip("Put every file back where it was")
            }
            HStack(spacing: 8) {
                if planWasRefusedBeforeAnythingChanged {
                    Button("Plan again") { taskSessionController.planAgainAfterDirectRouteValidationFailure() }
                        .dsSecondaryButtonStyle()
                        .nativeTooltip("The folder changed since the plan was made; plan the same command again")
                } else if case .fileOperations = directRoutePlan {
                    Button("Show in Finder") { taskSessionController.revealDirectRouteScopeInFinder() }
                        .dsSecondaryButtonStyle()
                }
                if taskSessionController.currentAuditLogFileURL != nil {
                    Button("Open log") { taskSessionController.openCurrentAuditLog() }
                        .dsSecondaryButtonStyle()
                }
                Button("Done") { taskSessionController.dismissFinishedTask() }
                    .dsPrimaryButtonStyle()
            }
        }
    }

    /// Offered until an undo of this journal has finished in this session.
    private var undoableJournalIdentifier: String? {
        guard let journalIdentifier = directRouteSessionState.lastRunReport?.undoJournalIdentifier,
              !directRouteSessionState.hasFinishedUndo(ofJournal: journalIdentifier) else { return nil }
        return journalIdentifier
    }

    /// The run-time check found the folder changed since planning and refused the plan before anything changed, so
    /// planning again from what is there now is the way on.
    private var planWasRefusedBeforeAnythingChanged: Bool {
        guard case .fileOperations = directRoutePlan, let runReport = directRouteSessionState.lastRunReport else { return false }
        return runReport.completedOperationCount == 0
            && runReport.failures.contains { $0.userFacingReason.hasPrefix(DirectRouteExecutor.folderChangedSincePlanningPrefix) }
    }
}

/// The result's one-line summary: "Moved 23 items and created 4 folders in 0.8 s", or "21 of 23 changes made ·
/// 2 failed".
enum DirectRouteResultText {
    static func summary(of runReport: DirectRouteRunReport, plan directRoutePlan: DirectRoutePlan) -> String {
        let durationText = formattedDuration(runReport.durationSeconds)
        switch directRoutePlan {
        case .fileOperations(let fileOperationsPlan):
            let totalCount = fileOperationsPlan.operations.count
            let everythingCompleted = runReport.failedOperationCount == 0 && runReport.skippedOperationCount == 0
                && runReport.completedOperationCount == totalCount
            if everythingCompleted, totalCount > 0 {
                return "\(completedChangesSentence(fileOperationsPlan.operations)) in \(durationText)"
            }
            var summaryParts = ["\(runReport.completedOperationCount) of \(totalCount) changes made"]
            if runReport.failedOperationCount > 0 { summaryParts.append("\(runReport.failedOperationCount) failed") }
            if runReport.skippedOperationCount > 0 { summaryParts.append("\(runReport.skippedOperationCount) skipped") }
            return summaryParts.joined(separator: " · ")
        case .script(let scriptPlan):
            return runReport.failedOperationCount == 0 && runReport.completedOperationCount > 0
                ? "Ran the script in \(scriptPlan.targetApplicationName) in \(durationText)"
                : "The script in \(scriptPlan.targetApplicationName) didn't finish"
        case .shortcut(let shortcutPlan):
            return runReport.failedOperationCount == 0 && runReport.completedOperationCount > 0
                ? "Ran “\(shortcutPlan.shortcutName)” in \(durationText)"
                : "“\(shortcutPlan.shortcutName)” didn't finish"
        }
    }

    /// "Moved 23 items and created 4 folders": every kind of change, most common first.
    static func completedChangesSentence(_ operations: [PlannedFileOperation]) -> String {
        var operationCountByKind: [FileOperationKind: Int] = [:]
        for plannedOperation in operations { operationCountByKind[plannedOperation.kind, default: 0] += 1 }
        let orderedKinds = FileOperationKind.allCases.filter { operationCountByKind[$0] != nil }
            .sorted { (operationCountByKind[$0] ?? 0) > (operationCountByKind[$1] ?? 0) }
        let phrases = orderedKinds.map { operationKind in phrase(for: operationKind, count: operationCountByKind[operationKind] ?? 0) }
        let joinedPhrases: String
        if phrases.count <= 1 {
            joinedPhrases = phrases.first ?? ""
        } else {
            joinedPhrases = phrases.dropLast().joined(separator: ", ") + " and " + (phrases.last ?? "")
        }
        return joinedPhrases.prefix(1).uppercased() + joinedPhrases.dropFirst()
    }

    private static func phrase(for operationKind: FileOperationKind, count: Int) -> String {
        let itemsText = count == 1 ? "1 item" : "\(count) items"
        switch operationKind {
        case .createFolder: return count == 1 ? "created 1 folder" : "created \(count) folders"
        case .move: return "moved \(itemsText)"
        case .rename: return "renamed \(itemsText)"
        case .copy: return "copied \(itemsText)"
        case .setTags: return "tagged \(itemsText)"
        case .moveToTrash: return "moved \(itemsText) to the Trash"
        }
    }

    static func formattedDuration(_ durationSeconds: Double) -> String {
        if durationSeconds < 10 { return String(format: "%.1f s", max(durationSeconds, 0)) }
        if durationSeconds < 60 { return "\(Int(durationSeconds.rounded())) s" }
        let wholeSeconds = Int(durationSeconds.rounded())
        return "\(wholeSeconds / 60) min \(wholeSeconds % 60) s"
    }
}

/// The small status mark in front of a direct route's group while it runs.
struct DirectRouteItemStatusIcon: View {
    let runStatus: ChecklistItemRunStatus

    var body: some View {
        Group {
            switch runStatus {
            case .completed:
                Image(systemName: "checkmark.circle.fill").foregroundColor(DesignSystem.Colors.success)
            case .failed:
                Image(systemName: "xmark.circle.fill").foregroundColor(DesignSystem.Colors.destructiveText)
            case .running:
                Image(systemName: "circle.dotted").foregroundColor(DesignSystem.Colors.accentText)
            case .skipped:
                Image(systemName: "minus.circle").foregroundColor(DesignSystem.Colors.textTertiary)
            case .pending, .needsUser:
                Image(systemName: "circle").foregroundColor(DesignSystem.Colors.textTertiary)
            }
        }
        .font(.system(size: 11))
        .accessibilityHidden(true)
    }
}
