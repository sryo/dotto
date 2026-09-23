import SwiftUI

/// The planning thread: the user's command and replies on the right in task-color bubbles, Dotto's questions on the
/// left in neutral ones, answer chips under the newest question, and a typing indicator while the planner works.
struct PlannerThreadView: View {
    let transcript: PlannerConversationTranscript
    let taskColor: Color
    /// Shown as Dotto's last bubble while it works; nil while it waits on the user.
    let typingIndicatorText: String?
    /// nil when the chips can't be used (the checklist's "Show conversation", or while Dotto works).
    let onChoiceChosen: ((String) -> Void)?

    private static let typingIndicatorIdentifier = "planner-thread-typing"

    /// The entry to keep in view: the typing indicator while Dotto works, otherwise the newest bubble.
    static func bottomScrollTargetIdentifier(transcript: PlannerConversationTranscript, showsTypingIndicator: Bool) -> String? {
        if showsTypingIndicator { return typingIndicatorIdentifier }
        return transcript.entries.last.map { entryScrollIdentifier($0) }
    }

    private static func entryScrollIdentifier(_ entry: PlannerConversationEntry) -> String {
        "planner-thread-entry-\(entry.id)"
    }

    var body: some View {
        let latestQuestionEntryIdentifier = transcript.latestUnansweredQuestionEntry?.id
        VStack(alignment: .leading, spacing: 8) {
            ForEach(transcript.entries) { entry in
                VStack(alignment: .leading, spacing: 6) {
                    PlannerThreadBubble(text: entry.text, author: entry.author, taskColor: taskColor)
                    if entry.id == latestQuestionEntryIdentifier, !entry.choices.isEmpty, let onChoiceChosen {
                        PlannerChoiceChips(choices: entry.choices, taskColor: taskColor, onChoiceChosen: onChoiceChosen)
                    }
                }
                .id(Self.entryScrollIdentifier(entry))
            }
            if let typingIndicatorText {
                PlannerTypingIndicator(text: typingIndicatorText)
                    .id(Self.typingIndicatorIdentifier)
            }
        }
    }
}

private struct PlannerThreadBubble: View {
    let text: String
    let author: PlannerConversationEntry.Author
    let taskColor: Color

    private static let maximumBubbleWidth: CGFloat = 290

    var body: some View {
        HStack(spacing: 0) {
            if author == .user { Spacer(minLength: 40) }
            bubbleText
                .font(.system(size: 13))
                .foregroundColor(author == .user ? DesignSystem.Colors.textOnAccent : DesignSystem.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(author == .user ? taskColor : DesignSystem.Colors.surface2)
                )
                .frame(maxWidth: Self.maximumBubbleWidth, alignment: author == .user ? .trailing : .leading)
            if author == .dotto { Spacer(minLength: 40) }
        }
    }

    /// Dotto's text is plain by the time it gets here; any markdown left is rendered inline only (no headings,
    /// lists or blocks) and with links removed, so a model-written link can never be clicked.
    private var bubbleText: Text {
        guard author == .dotto else { return Text(text) }
        return Text(Self.inlineOnlyAttributedString(fromMarkdown: text))
    }

    private static func inlineOnlyAttributedString(fromMarkdown markdownText: String) -> AttributedString {
        let parsingOptions = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard var attributedText = try? AttributedString(markdown: markdownText, options: parsingOptions) else {
            return AttributedString(markdownText)
        }
        for run in attributedText.runs where run.link != nil {
            attributedText[run.range].link = nil
        }
        return attributedText
    }
}

/// The newest question's answers. Tapping one sends its label as the reply.
private struct PlannerChoiceChips: View {
    let choices: [PlannerQuestionChoice]
    let taskColor: Color
    let onChoiceChosen: (String) -> Void

    var body: some View {
        PlannerChipFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(Array(choices.enumerated()), id: \.offset) { _, choice in
                HoverAwarePlainButton(action: { onChoiceChosen(choice.label) }) { isHovered in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(choice.label)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(isHovered ? DesignSystem.Colors.textOnAccent : taskColor)
                            .lineLimit(1)
                        if let detail = choice.detail {
                            Text(detail)
                                .font(.system(size: 11))
                                .foregroundColor(isHovered ? DesignSystem.Colors.textOnAccent.opacity(0.85) : DesignSystem.Colors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: 260, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(isHovered ? taskColor : taskColor.opacity(0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(taskColor.opacity(isHovered ? 0 : 0.45), lineWidth: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .accessibilityLabel(choice.detail.map { "\(choice.label), \($0)" } ?? choice.label)
            }
        }
    }
}

/// Dotto's bubble while it works: three pulsing dots and what it is doing.
private struct PlannerTypingIndicator: View {
    let text: String

    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    var body: some View {
        HStack(spacing: 8) {
            if reducesMotion {
                typingDots(phase: 0)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { timelineContext in
                    typingDots(phase: timelineContext.date.timeIntervalSinceReferenceDate)
                }
            }
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DesignSystem.Colors.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(DesignSystem.Colors.surface1))
        .accessibilityElement(children: .combine)
    }

    private func typingDots(phase: TimeInterval) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { dotIndex in
                // Each dot brightens in turn, a third of a 1.2 s cycle apart.
                let dotPhase = (phase / 1.2 - Double(dotIndex) / 3).truncatingRemainder(dividingBy: 1)
                let brightness = reducesMotion ? 0.6 : 0.35 + 0.65 * max(0, sin(dotPhase * .pi * 2))
                Circle()
                    .fill(DesignSystem.Colors.textSecondary.opacity(brightness))
                    .frame(width: 5, height: 5)
            }
        }
    }
}

/// The reply field and Send, pinned under the thread. Return sends and Shift-Return adds a line (both handled by
/// the panel, `ChecklistKeyablePanel`); Esc closes the thread and ends the task.
struct PlannerReplyComposer: View {
    @ObservedObject var replyComposerModel: PlannerReplyComposerModel
    let allowsFreeText: Bool
    let taskColor: Color
    let onSend: () -> Void

    @FocusState private var isReplyFieldFocused: Bool

    private var canSend: Bool {
        !replyComposerModel.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if allowsFreeText {
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("", text: $replyComposerModel.draftText,
                              prompt: Text("Reply to Dotto…").foregroundColor(DesignSystem.Colors.textTertiary),
                              axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundColor(DesignSystem.Colors.textPrimary)
                        .lineLimit(1...5)
                        .focused($isReplyFieldFocused)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(DesignSystem.Colors.surface2)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(isReplyFieldFocused ? taskColor.opacity(0.7) : DesignSystem.Colors.borderSubtle, lineWidth: 1)
                                )
                        )
                        .accessibilityLabel("Reply to Dotto")
                    sendButton
                }
            }
            hintText
        }
        .onAppear { isReplyFieldFocused = allowsFreeText }
        .onChange(of: replyComposerModel.focusRequestCount) {
            isReplyFieldFocused = allowsFreeText
        }
    }

    private var sendButton: some View {
        HoverAwarePlainButton(action: onSend) { isHovered in
            Text("Send")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DesignSystem.Colors.textOnAccent)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(taskColor)
                        .brightness(isHovered ? 0.08 : 0)
                )
                .opacity(canSend ? 1 : 0.45)
        }
        .disabled(!canSend)
        .accessibilityLabel("Send reply")
    }

    private var hintText: some View {
        let leadingHint = allowsFreeText
            ? Text("Return").fontWeight(.semibold).foregroundColor(DesignSystem.Colors.textSecondary) + Text(" to send · ")
            : Text("Choose an answer above · ")
        return (leadingHint
            + Text("Esc").fontWeight(.semibold).foregroundColor(DesignSystem.Colors.textSecondary)
            + Text(" to close"))
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(DesignSystem.Colors.textTertiary)
    }
}

/// Lays chips out in rows, wrapping to the next row when one doesn't fit the width offered.
private struct PlannerChipFlowLayout: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let availableWidth = proposal.width ?? .infinity
        let rowFrames = chipFrames(for: subviews, availableWidth: availableWidth)
        let usedWidth = rowFrames.map(\.maxX).max() ?? 0
        let usedHeight = rowFrames.map(\.maxY).max() ?? 0
        return CGSize(width: proposal.width ?? usedWidth, height: usedHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let chipFrames = chipFrames(for: subviews, availableWidth: bounds.width)
        for (subview, chipFrame) in zip(subviews, chipFrames) {
            subview.place(at: CGPoint(x: bounds.minX + chipFrame.minX, y: bounds.minY + chipFrame.minY),
                          proposal: ProposedViewSize(chipFrame.size))
        }
    }

    private func chipFrames(for subviews: Subviews, availableWidth: CGFloat) -> [CGRect] {
        var chipFrames: [CGRect] = []
        var nextChipOrigin = CGPoint.zero
        var currentRowHeight: CGFloat = 0
        for subview in subviews {
            let chipSize = subview.sizeThatFits(ProposedViewSize(width: availableWidth, height: nil))
            if nextChipOrigin.x > 0, nextChipOrigin.x + chipSize.width > availableWidth {
                nextChipOrigin = CGPoint(x: 0, y: nextChipOrigin.y + currentRowHeight + verticalSpacing)
                currentRowHeight = 0
            }
            chipFrames.append(CGRect(origin: nextChipOrigin, size: chipSize))
            nextChipOrigin.x += chipSize.width + horizontalSpacing
            currentRowHeight = max(currentRowHeight, chipSize.height)
        }
        return chipFrames
    }
}
