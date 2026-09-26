import SwiftUI

/// The checklist popover's content, one layout per task session state. Every layout has the same three parts: a
/// pinned header, one scroll region (the checklist's items or the planning thread) and a pinned footer with the
/// buttons. The card never grows past `maximumCardHeight`, the room its anchor leaves on screen: the scroll region
/// takes what the header and footer leave.
struct ChecklistPanelView: View {
    @ObservedObject var sessionScope: TaskSessionScope
    @ObservedObject var replyComposerModel: PlannerReplyComposerModel
    let maximumCardHeight: CGFloat
    let onSubmitReplyDraft: () -> Void
    let onContentHeightChange: (CGFloat) -> Void

    @State private var measuredHeaderHeight: CGFloat = 0
    @State private var measuredFooterHeight: CGFloat = 0
    @State private var measuredScrollContentHeight: CGFloat = 0
    @State private var isConversationShownWithChecklist = false

    /// A design cap: even on a tall screen the card stays a popover, not a window.
    private static let designMaximumCardHeight: CGFloat = 560
    private static let cardPadding: CGFloat = 16
    private static let sectionSpacing: CGFloat = 12
    /// A scroll region shorter than this can't show a useful slice, so the card overflows its room instead.
    private static let minimumScrollRegionHeight: CGFloat = 72
    static let cardWidth: CGFloat = 380

    private var cardHeightLimit: CGFloat {
        min(Self.designMaximumCardHeight, max(maximumCardHeight, 120))
    }

    var body: some View {
        let sections = stateSections
        VStack(alignment: .leading, spacing: Self.sectionSpacing) {
            if let header = sections.header {
                header
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { geometryProxy in geometryProxy.size.height } action: { headerHeight in
                        measuredHeaderHeight = headerHeight
                    }
            }
            if let scrollContent = sections.scrollContent {
                scrollRegion(scrollContent, scrollTargetIdentifier: sections.scrollTargetIdentifier,
                             scrollTargetAnchor: sections.scrollTargetAnchor,
                             height: scrollRegionHeight(for: sections))
            }
            if let footer = sections.footer {
                footer
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { geometryProxy in geometryProxy.size.height } action: { footerHeight in
                        measuredFooterHeight = footerHeight
                    }
            }
        }
        .padding(Self.cardPadding)
        .frame(width: Self.cardWidth, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.extraLarge, style: .continuous)
                .fill(DesignSystem.Colors.background)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.extraLarge, style: .continuous)
                        .stroke(DesignSystem.Colors.borderSubtle, lineWidth: 1)
                )
        )
        .onGeometryChange(for: CGFloat.self) { geometryProxy in geometryProxy.size.height } action: { contentHeight in
            onContentHeightChange(contentHeight)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// The header and footer never depend on the scroll region's height, so measuring them can't feed back into it.
    private func scrollRegionHeight(for sections: PopoverSections) -> CGFloat {
        var roomForScrollRegion = cardHeightLimit - Self.cardPadding * 2
        if sections.header != nil { roomForScrollRegion -= measuredHeaderHeight + Self.sectionSpacing }
        if sections.footer != nil { roomForScrollRegion -= measuredFooterHeight + Self.sectionSpacing }
        let contentHeight = max(measuredScrollContentHeight, 1)
        return min(contentHeight, max(roomForScrollRegion, min(contentHeight, Self.minimumScrollRegionHeight)))
    }

    private func scrollRegion(_ scrollContent: AnyView, scrollTargetIdentifier: String?, scrollTargetAnchor: UnitPoint,
                              height: CGFloat) -> some View {
        ScrollViewReader { scrollViewProxy in
            ScrollView {
                scrollContent
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { geometryProxy in geometryProxy.size.height } action: { contentHeight in
                        measuredScrollContentHeight = contentHeight
                    }
            }
            // ScrollView has no intrinsic height, so it is sized to its content up to the room left.
            .frame(height: height)
            .onAppear {
                guard let scrollTargetIdentifier else { return }
                scrollViewProxy.scrollTo(scrollTargetIdentifier, anchor: scrollTargetAnchor)
            }
            .onChange(of: scrollTargetIdentifier) { _, newScrollTargetIdentifier in
                guard let newScrollTargetIdentifier else { return }
                withAnimation(.easeInOut(duration: DesignSystem.Animation.normal)) {
                    scrollViewProxy.scrollTo(newScrollTargetIdentifier, anchor: scrollTargetAnchor)
                }
            }
        }
    }

    // MARK: - Layout per state

    private struct PopoverSections {
        var header: AnyView?
        var scrollContent: AnyView?
        /// Scrolled into view whenever it changes: the running item, or the thread's newest entry.
        var scrollTargetIdentifier: String?
        var scrollTargetAnchor: UnitPoint = .center
        var footer: AnyView?
    }

    private var stateSections: PopoverSections {
        switch sessionScope.sessionState {
        case .idle:
            return PopoverSections()

        case .planning:
            return threadSections(footer: AnyView(HStack(spacing: 8) {
                Spacer(minLength: 0)
                ChecklistStopTaskButton(sessionScope: sessionScope)
            }))

        case .plannerNeedsInput(_, let plannerQuestion):
            if plannerQuestion.acceptsReply {
                return threadSections(footer: AnyView(PlannerReplyComposer(
                    replyComposerModel: replyComposerModel, allowsFreeText: plannerQuestion.allowsFreeText,
                    taskColor: sessionScope.taskStyleConfiguration.taskAccentColor,
                    onSend: onSubmitReplyDraft)))
            }
            return threadSections(footer: AnyView(HStack(spacing: 8) {
                Button("Edit command") { sessionScope.reopenCommandBarWithPreviousCommand() }
                    .dsPrimaryButtonStyle()
                Button("Close") { sessionScope.dismissFinishedTask() }
                    .dsSecondaryButtonStyle()
            }))

        case .awaitingApproval(let checklist):
            if let directRoutePlan = checklist.directRoutePlan {
                return directRouteApprovalSections(checklist: checklist, directRoutePlan: directRoutePlan)
            }
            let subtitle = sessionScope.attachedRoutine.map { attachedRoutine in
                "Using routine “\(attachedRoutine.name)” · \(attachedRoutine.steps.count) steps"
            } ?? (sessionScope.currentTaskFocusPolicy == .backgroundOnly
                   ? "Dotto won't bring the target forward. Steps needing it in front stay undone."
                   : "Review the checklist, then run it.")
            return PopoverSections(
                header: AnyView(VStack(alignment: .leading, spacing: 6) {
                    panelHeader(title: checklist.title, subtitle: subtitle)
                    conversationDisclosureButton
                }),
                scrollContent: AnyView(VStack(alignment: .leading, spacing: 12) {
                    if isConversationShownWithChecklist && sessionScope.plannerConversationTranscript.containsPlannerMessages {
                        PlannerThreadView(transcript: sessionScope.plannerConversationTranscript,
                                          taskColor: sessionScope.taskStyleConfiguration.taskAccentColor,
                                          typingIndicatorText: nil, onChoiceChosen: nil)
                        Divider().overlay(DesignSystem.Colors.borderSubtle)
                    }
                    itemRows(checklist: checklist, currentItemIdentifier: nil, isEditable: true)
                }),
                footer: AnyView(approvalFooter(checklist: checklist)))

        case .executing(let checklist, let currentItemIdentifier):
            if let directRoutePlan = checklist.directRoutePlan {
                return PopoverSections(
                    header: AnyView(panelHeader(title: checklist.title, subtitle: DirectRoutePreviewView.subtitle(for: directRoutePlan))),
                    scrollContent: AnyView(directRouteProgress(checklist: checklist, directRoutePlan: directRoutePlan)),
                    footer: AnyView(HStack(spacing: 8) {
                        Button("Pause") { sessionScope.pauseTask() }
                            .dsSecondaryButtonStyle()
                        ChecklistStopTaskButton(sessionScope: sessionScope)
                    }))
            }
            return PopoverSections(
                header: AnyView(panelHeader(title: checklist.title, subtitle: nil)),
                scrollContent: AnyView(itemRows(checklist: checklist, currentItemIdentifier: currentItemIdentifier, isEditable: false)),
                scrollTargetIdentifier: currentItemIdentifier,
                footer: AnyView(VStack(alignment: .leading, spacing: 8) {
                    metricsSummaryLine
                    statusLineText
                    HStack(spacing: 8) {
                        Button("Pause") { sessionScope.pauseTask() }
                            .dsSecondaryButtonStyle()
                        if currentItemIdentifier != nil {
                            ChecklistSkipItemButton(sessionScope: sessionScope, title: "Skip item")
                        }
                        ChecklistStopTaskButton(sessionScope: sessionScope)
                    }
                }))

        case .paused(let checklist, let currentItemIdentifier, let pauseReason):
            return PopoverSections(
                header: AnyView(VStack(alignment: .leading, spacing: 12) {
                    panelHeader(title: checklist.title, subtitle: nil)
                    ChecklistPausedBanner(sessionScope: sessionScope, pauseReason: pauseReason,
                                          currentItemIdentifier: currentItemIdentifier)
                }),
                scrollContent: checklist.directRoutePlan.map { directRoutePlan in
                    AnyView(directRouteProgress(checklist: checklist, directRoutePlan: directRoutePlan))
                } ?? AnyView(itemRows(checklist: checklist, currentItemIdentifier: currentItemIdentifier, isEditable: false)),
                scrollTargetIdentifier: currentItemIdentifier)

        case .awaitingItemFailureDecision(let checklist, let request):
            return PopoverSections(
                header: AnyView(VStack(alignment: .leading, spacing: 12) {
                    panelHeader(title: checklist.title, subtitle: nil)
                    ChecklistItemFailureDecisionCard(sessionScope: sessionScope, request: request)
                }),
                scrollContent: AnyView(itemRows(checklist: checklist, currentItemIdentifier: request.itemIdentifier, isEditable: false)),
                scrollTargetIdentifier: request.itemIdentifier)

        case .demonstrating(let checklist, let itemIdentifier, let isCompilingRoutine):
            if let taughtRoutine = sessionScope.taughtRoutineAwaitingReview {
                return PopoverSections(
                    header: AnyView(panelHeader(title: checklist.title, subtitle: nil)),
                    scrollContent: AnyView(RoutineReviewCard(
                        routine: taughtRoutine,
                        closingExplanation: "Saving also uses it for the rest of this checklist.",
                        onDiscard: { sessionScope.discardTaughtRoutine() },
                        onSave: { sessionScope.saveTaughtRoutine() })))
            }
            return PopoverSections(
                header: AnyView(VStack(alignment: .leading, spacing: 12) {
                    panelHeader(title: checklist.title, subtitle: nil)
                    ChecklistTeachingCard(sessionScope: sessionScope, checklist: checklist, itemIdentifier: itemIdentifier,
                                          isCompilingRoutine: isCompilingRoutine)
                }),
                scrollContent: AnyView(itemRows(checklist: checklist, currentItemIdentifier: itemIdentifier, isEditable: false)),
                scrollTargetIdentifier: itemIdentifier)

        case .awaitingSafetyConfirmation(let checklist, let request):
            return PopoverSections(
                header: AnyView(VStack(alignment: .leading, spacing: 12) {
                    panelHeader(title: checklist.title, subtitle: nil)
                    ChecklistSafetyConfirmationCard(sessionScope: sessionScope, request: request)
                }),
                scrollContent: checklist.directRoutePlan.map { directRoutePlan in
                    AnyView(directRouteProgress(checklist: checklist, directRoutePlan: directRoutePlan))
                } ?? AnyView(itemRows(checklist: checklist, currentItemIdentifier: request.itemIdentifier, isEditable: false)),
                scrollTargetIdentifier: request.itemIdentifier)

        case .finished(let checklist, let summary):
            if let directRoutePlan = checklist.directRoutePlan {
                return directRouteResultSections(checklist: checklist, directRoutePlan: directRoutePlan,
                                                 subtitle: TaskUserFacingMessages.userFacingDescription(ofStopReason: summary.stopReason))
            }
            return PopoverSections(
                header: AnyView(VStack(alignment: .leading, spacing: 12) {
                    panelHeader(title: checklist.title, subtitle: TaskUserFacingMessages.userFacingDescription(ofStopReason: summary.stopReason))
                    runSummaryCounts(summary)
                    metricsSummaryLine
                }),
                scrollContent: AnyView(itemListOrLearnedRoutineReview(checklist: checklist)),
                footer: AnyView(completionFooter))

        case .failed(let checklist, let reason):
            if let checklist, let directRoutePlan = checklist.directRoutePlan {
                return directRouteResultSections(checklist: checklist, directRoutePlan: directRoutePlan, subtitle: reason)
            }
            return PopoverSections(
                header: AnyView(VStack(alignment: .leading, spacing: 12) {
                    panelHeader(title: checklist?.title ?? "Task failed", subtitle: nil)
                    WrappingText(reason, color: DesignSystem.Colors.destructiveText)
                }),
                scrollContent: checklist.map { AnyView(itemListOrLearnedRoutineReview(checklist: $0)) },
                footer: AnyView(completionFooter))

        case .aborted(let checklist):
            if let checklist, let directRoutePlan = checklist.directRoutePlan {
                return directRouteResultSections(checklist: checklist, directRoutePlan: directRoutePlan, subtitle: "Stopped by you")
            }
            return PopoverSections(
                header: AnyView(VStack(alignment: .leading, spacing: 12) {
                    panelHeader(title: checklist?.title ?? "Stopped", subtitle: "Stopped by you")
                    if let checklist {
                        runSummaryCounts(TaskRunSummary.summarize(checklist: checklist, stopReason: .userAborted))
                    }
                }),
                scrollContent: checklist.map { AnyView(itemListOrLearnedRoutineReview(checklist: $0)) },
                footer: AnyView(completionFooter))
        }
    }

    // MARK: - Direct routes

    /// A direct plan is approved as a whole: its preview replaces the item list, with no toggles, label fields or Teach.
    private func directRouteApprovalSections(checklist: Checklist, directRoutePlan: DirectRoutePlan) -> PopoverSections {
        PopoverSections(
            header: AnyView(VStack(alignment: .leading, spacing: 6) {
                panelHeader(title: checklist.title, subtitle: DirectRoutePreviewView.subtitle(for: directRoutePlan))
                conversationDisclosureButton
            }),
            scrollContent: AnyView(VStack(alignment: .leading, spacing: 12) {
                if isConversationShownWithChecklist && sessionScope.plannerConversationTranscript.containsPlannerMessages {
                    PlannerThreadView(transcript: sessionScope.plannerConversationTranscript,
                                      taskColor: sessionScope.taskStyleConfiguration.taskAccentColor,
                                      typingIndicatorText: nil, onChoiceChosen: nil)
                    Divider().overlay(DesignSystem.Colors.borderSubtle)
                }
                DirectRoutePreviewView(directRoutePlan: directRoutePlan,
                                       directRouteSessionState: sessionScope.directRouteSessionState)
            }),
            footer: AnyView(DirectRouteApprovalFooter(sessionScope: sessionScope, directRoutePlan: directRoutePlan)))
    }

    private func directRouteProgress(checklist: Checklist, directRoutePlan: DirectRoutePlan) -> some View {
        DirectRouteProgressView(checklist: checklist, directRoutePlan: directRoutePlan,
                                directRouteSessionState: sessionScope.directRouteSessionState,
                                statusLine: sessionScope.statusLine)
    }

    private func directRouteResultSections(checklist: Checklist, directRoutePlan: DirectRoutePlan, subtitle: String) -> PopoverSections {
        PopoverSections(
            header: AnyView(panelHeader(title: checklist.title, subtitle: subtitle)),
            scrollContent: AnyView(DirectRouteResultView(checklist: checklist, directRoutePlan: directRoutePlan,
                                                         directRouteSessionState: sessionScope.directRouteSessionState)),
            footer: AnyView(DirectRouteResultFooter(sessionScope: sessionScope,
                                                    directRouteSessionState: sessionScope.directRouteSessionState,
                                                    checklist: checklist, directRoutePlan: directRoutePlan)))
    }

    /// Planning and the planner's questions: the thread from the command on, newest at the bottom.
    private func threadSections(footer: AnyView) -> PopoverSections {
        let transcript = sessionScope.plannerConversationTranscript
        let typingIndicatorText = typingIndicatorTextWhilePlanning
        let isWaitingForReply = sessionScope.isWaitingForPlannerReply
        return PopoverSections(
            scrollContent: AnyView(PlannerThreadView(
                transcript: transcript,
                taskColor: sessionScope.taskStyleConfiguration.taskAccentColor,
                typingIndicatorText: typingIndicatorText,
                onChoiceChosen: isWaitingForReply ? { choiceLabel in
                    replyComposerModel.draftText = ""
                    sessionScope.sendPlannerReply(choiceLabel)
                } : nil)),
            scrollTargetIdentifier: PlannerThreadView.bottomScrollTargetIdentifier(transcript: transcript,
                                                                                   showsTypingIndicator: typingIndicatorText != nil),
            scrollTargetAnchor: .bottom,
            footer: footer)
    }

    /// While the planner works: what it is reading, or that it is thinking. nil while it waits on the user.
    private var typingIndicatorTextWhilePlanning: String? {
        guard case .planning = sessionScope.sessionState else { return nil }
        switch sessionScope.currentPlanningProgress {
        case .readingApplication, .takingScreenshot, .readingFolder, .writingChecklist:
            return sessionScope.currentPlanningProgress?.statusLineText
        case .thinking, nil:
            return "Dotto is thinking…"
        }
    }

    @ViewBuilder
    private var conversationDisclosureButton: some View {
        if sessionScope.plannerConversationTranscript.containsPlannerMessages {
            HoverAwarePlainButton(action: { isConversationShownWithChecklist.toggle() }) { isHovered in
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(isConversationShownWithChecklist ? 90 : 0))
                    Text(isConversationShownWithChecklist ? "Hide conversation" : "Show conversation")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(isHovered ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textSecondary)
                .animation(.easeOut(duration: DesignSystem.Animation.fast), value: isConversationShownWithChecklist)
            }
        }
    }

    // MARK: - Shared pieces

    private func panelHeader(title: String, subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(DesignSystem.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(DesignSystem.Colors.textTertiary)
                    .lineLimit(3)
            }
        }
    }

    private var statusLineText: some View {
        Text(sessionScope.statusLine)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(DesignSystem.Colors.textSecondary)
            .lineLimit(2)
    }

    @ViewBuilder
    private var metricsSummaryLine: some View {
        if let metricsSummaryLine = sessionScope.currentRunMetrics?.summaryLine {
            Text(metricsSummaryLine)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DesignSystem.Colors.accentText)
        }
    }

    private var completionFooter: some View {
        HStack(spacing: 8) {
            if sessionScope.currentAuditLogFileURL != nil {
                Button("Open log") { sessionScope.openCurrentAuditLog() }
                    .dsSecondaryButtonStyle()
            }
            Button("Done") { sessionScope.dismissFinishedTask() }
                .dsPrimaryButtonStyle()
        }
    }

    private func approvalFooter(checklist: Checklist) -> some View {
        let includedItemCount = checklist.includedItems.count
        // A routine needs a parameter to vary per item, so an item without parameters can't be taught.
        let canTeachFirstItem = sessionScope.attachedRoutine == nil
            && checklist.includedItems.first(where: { $0.runStatus == .pending }).map { !$0.parameters.isEmpty } == true
        return VStack(spacing: 8) {
            Button("Teach first item") { sessionScope.startTeachingFirstItem() }
                .dsOutlinedButtonStyle()
                .disabled(!canTeachFirstItem)
                .nativeTooltip("Do item 1 yourself; Dotto learns it and does the rest")
            HStack(spacing: 8) {
                Button("Cancel") { sessionScope.cancelChecklist() }
                    .dsSecondaryButtonStyle()
                Button(includedItemCount == 1 ? "Run 1 item" : "Run \(includedItemCount) items") {
                    sessionScope.approveChecklistAndRun()
                }
                .dsPrimaryButtonStyle()
                .disabled(includedItemCount == 0)
            }
        }
    }

    private func runSummaryCounts(_ summary: TaskRunSummary) -> some View {
        HStack(spacing: 12) {
            summaryCount(summary.completedItemCount, label: "done", color: DesignSystem.Colors.success)
            summaryCount(summary.failedItemCount, label: "failed", color: DesignSystem.Colors.destructiveText)
            summaryCount(summary.needsUserItemCount, label: "need you", color: DesignSystem.Colors.warningText)
            summaryCount(summary.skippedItemCount, label: "skipped", color: DesignSystem.Colors.textTertiary)
        }
    }

    private func summaryCount(_ count: Int, label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Text("\(count)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(color)
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(DesignSystem.Colors.textTertiary)
        }
    }

    // MARK: - Items

    /// A routine Dotto learned during the run is offered for saving once the run is over, in place of the item list
    /// (the panel has no room for both), like a taught routine's review.
    @ViewBuilder
    private func itemListOrLearnedRoutineReview(checklist: Checklist) -> some View {
        if let learnedRoutine = sessionScope.learnedRoutineAwaitingReview {
            RoutineReviewCard(
                routine: learnedRoutine,
                closingExplanation: "Dotto learned this while running the checklist. Save it to run it on another list later.",
                onDiscard: { sessionScope.discardLearnedRoutine() },
                onSave: { sessionScope.saveLearnedRoutine() })
        } else {
            itemRows(checklist: checklist, currentItemIdentifier: nil, isEditable: false)
        }
    }

    private func itemRows(checklist: Checklist, currentItemIdentifier: String?, isEditable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(checklist.items) { item in
                ChecklistItemRow(
                    item: item,
                    isCurrentItem: item.itemIdentifier == currentItemIdentifier,
                    isEditable: isEditable,
                    sessionScope: sessionScope
                )
                .id(item.itemIdentifier)
            }
        }
    }
}
