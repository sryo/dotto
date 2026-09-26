import SwiftUI

// The cards that interrupt a run and wait for the user: paused, item failed, teaching in progress and safety
// confirmation.

struct ChecklistPausedBanner: View {
    @ObservedObject var sessionScope: TaskSessionScope
    let pauseReason: TaskPauseReason
    let currentItemIdentifier: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ChecklistCardHeader(
                iconSystemName: "pause.circle.fill", iconColor: DesignSystem.Colors.warning,
                title: pauseReason.pausedStatusText(targetApplicationName: sessionScope.targetApplication?.applicationName ?? "the app"))
            HStack(spacing: 8) {
                Button("Resume") { sessionScope.resumeTask() }
                    .dsPrimaryButtonStyle()
                // Paused between items, the skip is kept for the item that starts next.
                ChecklistSkipItemButton(sessionScope: sessionScope,
                                        title: currentItemIdentifier == nil ? "Skip next item" : "Skip item")
                ChecklistStopTaskButton(sessionScope: sessionScope)
            }
        }
        .modifier(ChecklistCardBackground(borderColor: DesignSystem.Colors.warning))
    }
}

struct ChecklistItemFailureDecisionCard: View {
    @ObservedObject var sessionScope: TaskSessionScope
    let request: ChecklistItemFailureDecisionRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ChecklistCardHeader(iconSystemName: "exclamationmark.triangle.fill", iconColor: DesignSystem.Colors.destructiveText,
                                title: "This item didn't work")
            WrappingText(request.itemLabel, weight: .medium)
            WrappingText(request.failureSummary, color: DesignSystem.Colors.destructiveText)
            Text(request.attemptCount == 1 ? "Tried once" : "Tried \(request.attemptCount) times")
                .font(.system(size: 11))
                .foregroundColor(DesignSystem.Colors.textTertiary)
            HStack(spacing: 8) {
                Button("Retry") { sessionScope.answerPendingItemFailureDecision(.retry) }
                    .dsPrimaryButtonStyle()
                Button("Skip item") { sessionScope.answerPendingItemFailureDecision(.skipItem) }
                    .dsSecondaryButtonStyle()
                Button("Stop task") { sessionScope.answerPendingItemFailureDecision(.stopTask) }
                    .dsDestructiveButtonStyle()
            }
        }
        .modifier(ChecklistCardBackground(borderColor: DesignSystem.Colors.destructive))
    }
}

struct ChecklistTeachingCard: View {
    @ObservedObject var sessionScope: TaskSessionScope
    let checklist: Checklist
    let itemIdentifier: String
    let isCompilingRoutine: Bool

    var body: some View {
        let demonstratedItem = checklist.items.first(where: { $0.itemIdentifier == itemIdentifier })
        return VStack(alignment: .leading, spacing: 10) {
            if isCompilingRoutine {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    WrappingText("Learning the routine…", size: 13, weight: .semibold, color: DesignSystem.Colors.textPrimary)
                }
            } else {
                ChecklistCardHeader(
                    iconSystemName: "record.circle", iconColor: DesignSystem.Colors.destructiveText,
                    title: "Do “\(demonstratedItem?.label ?? "the first item")” in \(checklist.targetApplication.applicationName) yourself. Dotto is recording your clicks and typing.")
                if let demonstratedItem, !demonstratedItem.parameters.isEmpty {
                    ChecklistItemParameterList(parameters: demonstratedItem.parameters)
                }
                Text(sessionScope.recordedDemonstrationEventCount == 1
                     ? "1 step recorded" : "\(sessionScope.recordedDemonstrationEventCount) steps recorded")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DesignSystem.Colors.textTertiary)
                ForEach(sessionScope.demonstrationRecordingNotes, id: \.self) { recordingNote in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.circle")
                            .font(.system(size: 11))
                            .foregroundColor(DesignSystem.Colors.warningText)
                        WrappingText(recordingNote, size: 11, color: DesignSystem.Colors.warningText)
                    }
                }
            }
            HStack(spacing: 8) {
                if !isCompilingRoutine {
                    Button("Done") { sessionScope.finishTeaching() }
                        .dsPrimaryButtonStyle()
                }
                Button("Cancel") { sessionScope.cancelTeaching() }
                    .dsSecondaryButtonStyle()
            }
        }
        .modifier(ChecklistCardBackground(borderColor: DesignSystem.Colors.accent))
    }
}

struct ChecklistSafetyConfirmationCard: View {
    @ObservedObject var sessionScope: TaskSessionScope
    let request: SafetyConfirmationRequest

    /// Pasting, bringing the app forward and attaching files get their own wording: "Skip item" alone wouldn't say
    /// what stays untouched.
    private var cardPresentation: (iconSystemName: String, title: String, allowOnceTitle: String?, skipTitle: String) {
        switch request.riskCategory {
        case .pastingClipboard: return ("doc.on.clipboard", "Paste what's on your clipboard?", "Paste", "Don't paste (skip item)")
        case .bringingAppForward:
            let bringForwardTitle = CursorPresentationStateMapper.bringAppForwardQuestionText(
                targetApplicationName: sessionScope.targetApplication?.applicationName ?? "")
            return ("macwindow.on.rectangle", bringForwardTitle, "Just this once", "Not now (skip item)")
        case .uploadingFiles: return ("paperclip", "Attach files?", "Attach", "Don't attach (skip item)")
        case .runningShortcut: return ("square.2.layers.3d", "Run your shortcut?", "Run shortcut", "Don't run")
        case .runningScript: return ("applescript", "Run the script?", "Run script", "Don't run")
        default: return ("exclamationmark.shield.fill", "Confirm before continuing", nil, "Skip item")
        }
    }

    /// Everything a rest-of-task upload grant could cover: the files and folders attached to this task.
    private var attachedItemNames: [String] {
        sessionScope.currentUploadFileAllowlist.grants.map { uploadFileGrant in
            let itemName = (uploadFileGrant.canonicalPath as NSString).lastPathComponent
            return uploadFileGrant.isDirectory ? "\(itemName) (folder)" : itemName
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ChecklistCardHeader(iconSystemName: cardPresentation.iconSystemName, iconColor: DesignSystem.Colors.warning,
                                title: cardPresentation.title)
            WrappingText(request.itemLabel, weight: .medium)
            WrappingText(request.reason, color: DesignSystem.Colors.warningText)
            if !request.itemParameters.isEmpty {
                ChecklistItemParameterList(parameters: request.itemParameters)
            }
            if request.riskCategory == .uploadingFiles, !attachedItemNames.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Attached to this task")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DesignSystem.Colors.textTertiary)
                    ForEach(attachedItemNames, id: \.self) { attachedItemName in
                        Label(attachedItemName, systemImage: "doc")
                            .font(.system(size: 11))
                            .foregroundColor(DesignSystem.Colors.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            if request.riskCategory == .bringingAppForward {
                // The same app comes forward for many steps of one task, so the task-wide grant leads here. Each
                // bring-forward still waits for the user to pause and counts down with Cancel.
                Button("Allow for this task") { sessionScope.answerPendingSafetyConfirmation(.allowForAllRemainingItems) }
                    .dsPrimaryButtonStyle()
                WrappingText("Dotto still waits until you pause and counts down before each time.",
                             size: 11, color: DesignSystem.Colors.textTertiary)
                Button(cardPresentation.allowOnceTitle ?? "Just this once") {
                    sessionScope.answerPendingSafetyConfirmation(.allowOnce)
                }
                .dsOutlinedButtonStyle()
            } else {
                Button(cardPresentation.allowOnceTitle ?? (request.isActionLevel ? "Allow this step only" : "Allow this item")) {
                    sessionScope.answerPendingSafetyConfirmation(.allowOnce)
                }
                .dsPrimaryButtonStyle()
                // A shortcut asks before every run, so its card has no rest-of-task grant.
                if request.riskCategory.offersRestOfTaskGrant {
                    restOfTaskGrant
                }
            }
            HStack(spacing: 8) {
                Button(cardPresentation.skipTitle) { sessionScope.answerPendingSafetyConfirmation(.skipItem) }
                    .dsSecondaryButtonStyle()
                Button("Stop task") { sessionScope.answerPendingSafetyConfirmation(.stopTask) }
                    .dsDestructiveButtonStyle()
            }
        }
        .modifier(ChecklistCardBackground(borderColor: DesignSystem.Colors.warning))
    }

    private var restOfTaskGrant: some View {
        // Honest about scope: the grant covers one risk category, not every remaining item or step.
        VStack(alignment: .leading, spacing: 4) {
            Button("Allow \(request.riskCategory.userFacingScopeDescription) for the rest of this task") {
                sessionScope.answerPendingSafetyConfirmation(.allowForAllRemainingItems)
            }
            .dsOutlinedButtonStyle()
            WrappingText("Dotto stops asking about this kind of step. Other risky steps still ask.",
                         size: 11, color: DesignSystem.Colors.textTertiary)
        }
    }
}

/// A card's icon and bold title, which wraps next to the icon.
struct ChecklistCardHeader: View {
    let iconSystemName: String
    let iconColor: Color
    let title: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: iconSystemName)
                .foregroundColor(iconColor)
            WrappingText(title, size: 13, weight: .semibold, color: DesignSystem.Colors.textPrimary)
        }
    }
}

struct ChecklistStopTaskButton: View {
    @ObservedObject var sessionScope: TaskSessionScope

    var body: some View {
        Button("Stop") { sessionScope.stopTask() }
            .dsDestructiveButtonStyle()
    }
}

struct ChecklistSkipItemButton: View {
    @ObservedObject var sessionScope: TaskSessionScope
    let title: String

    var body: some View {
        Button(title) { sessionScope.skipCurrentItem() }
            .dsSecondaryButtonStyle()
    }
}

struct ChecklistCardBackground: ViewModifier {
    let borderColor: Color

    func body(content: Content) -> some View {
        content
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.large, style: .continuous)
                    .fill(DesignSystem.Colors.surface2)
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.large, style: .continuous)
                            .stroke(borderColor.opacity(0.5), lineWidth: 1)
                    )
            )
    }
}
