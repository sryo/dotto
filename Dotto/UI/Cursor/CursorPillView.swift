import SwiftUI

/// The status pill beside the cursor's tip: one line of text, the typing caret, and while Dotto needs the user its
/// compact answers; while planning or a run is live, Pause (while working), Stop and the checklist chevron. The text
/// follows the status style; the buttons stay even where the style hides the text, so Stop is always there.
struct CursorPillView: View {
    let appearance: CursorAppearance
    let configuration: CursorStyleConfiguration
    let reducesMotion: Bool
    let onPillDecision: (UserDecisionOptionIdentifier) -> Void
    /// nil where the pill can't be clicked (drawn in the click-through overlay).
    var onToggleChecklist: (() -> Void)? = nil
    var checklistIsOpen: Bool = false

    @Environment(\.colorScheme) private var colorScheme

    private var isPaused: Bool { appearance.activity == .paused }
    private var stateColor: Color { configuration.stateColor(for: appearance.activity) }
    /// The lab's `--win` / `--wintext`: the paused pill turns into a hollow window-colored pill.
    private var pausedFillColor: Color { colorScheme == .dark ? Color(hex: "#23222C") : .white }
    private var pausedTextColor: Color { colorScheme == .dark ? Color(hex: "#ECEAF4") : Color(hex: "#1D1C25") }

    /// A question always shows its text; otherwise the status style decides (never in ring, briefly in quiet).
    private var showsText: Bool {
        !appearance.decisionOptions.isEmpty || appearance.statusStyleShowsTextOnlyPill(configuration.statusStyle)
    }

    private var checklistToggleAction: (() -> Void)? {
        appearance.offersChecklistToggle ? onToggleChecklist : nil
    }

    private var showsButtons: Bool {
        !appearance.decisionOptions.isEmpty || appearance.offersStop || appearance.offersPause || checklistToggleAction != nil
    }

    /// The pill grows to this width, then wraps its text to a second line (with the buttons on a row below) before
    /// anything is cut.
    static let maximumPillWidth: CGFloat = 420
    private var horizontalPadding: CGFloat { showsText ? 12 : 6 }

    var body: some View {
        // A single-line pill keeps its capsule ends; a wrapped one is a rounded card with the same corners.
        let pillShape = RoundedRectangle(cornerRadius: 15, style: .continuous)
        CursorPillWrappingLayout(maximumContentWidth: Self.maximumPillWidth - horizontalPadding * 2, spacing: 8) {
            if showsText {
                HStack(alignment: .lastTextBaseline, spacing: 1) {
                    Text(appearance.pillText)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                    if appearance.showsTypingCaret {
                        CursorTypingCaret(reducesMotion: reducesMotion)
                    }
                }
            }
            if showsButtons {
                CursorDecisionButtonRow(decisionOptions: appearance.decisionOptions, stateColor: stateColor,
                                             isOnHollowPill: isPaused, includesPause: appearance.offersPause,
                                             includesStop: appearance.offersStop, onToggleChecklist: checklistToggleAction,
                                             checklistIsOpen: checklistIsOpen, onDecision: onPillDecision)
            }
        }
        .font(.system(size: 12.5, weight: .semibold))
        .foregroundColor(isPaused ? pausedTextColor : .white)
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, 6)
        .background(
            pillShape
                .fill(isPaused ? pausedFillColor : stateColor)
                .overlay(pillShape.strokeBorder(configuration.taskAccentColor, lineWidth: isPaused ? 2 : 0))
                .shadow(color: CursorPalette.pillShadowColor.opacity(0.2), radius: 9, x: 0, y: 6)
        )
        .fixedSize()
        .animation(reducesMotion ? nil : .easeInOut(duration: 0.2), value: appearance.activity)
        .keyframeAnimator(initialValue: CursorPillNudge(), trigger: appearance.attentionNudgeCount) { nudgedPill, pillNudge in
            nudgedPill
                .scaleEffect(reducesMotion ? 1 : pillNudge.scale, anchor: .topLeading)
                .offset(y: reducesMotion ? 0 : pillNudge.verticalOffset)
        } keyframes: { _ in
            // The lab's `pillnudge`: a hop up with a slight swell, a small dip, then rest, over 0.6 s.
            KeyframeTrack(\.verticalOffset) {
                CubicKeyframe(-5, duration: 0.21)
                CubicKeyframe(1, duration: 0.18)
                CubicKeyframe(0, duration: 0.21)
            }
            KeyframeTrack(\.scale) {
                CubicKeyframe(1.04, duration: 0.21)
                CubicKeyframe(1, duration: 0.39)
            }
        }
    }
}

/// Blinks once a second, visible for the first half, on its own timeline so nothing else redraws for it.
private struct CursorTypingCaret: View {
    let reducesMotion: Bool

    @State private var blinkStartDate = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.5, paused: reducesMotion)) { timelineContext in
            let secondsIntoBlink = timelineContext.date.timeIntervalSince(blinkStartDate).truncatingRemainder(dividingBy: 1)
            Rectangle()
                .frame(width: 1.5, height: 13)
                .opacity(reducesMotion || secondsIntoBlink < 0.5 ? 1 : 0)
        }
    }
}

private struct CursorPillNudge {
    var verticalOffset: CGFloat = 0
    var scale: CGFloat = 1
}

/// The cursor's pill with its answer buttons, shared by the clickable pill panel and the live view.
struct DecisionPill: View {
    @ObservedObject var viewModel: CursorViewModel
    let onDecisionOptionChosen: DecisionOptionHandler
    let onToggleChecklist: () -> Void

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    var body: some View {
        var pillAppearance = viewModel.appearance
        pillAppearance.decisionOptions = viewModel.pillDecisionOptions
        return CursorPillView(
            appearance: pillAppearance, configuration: viewModel.styleConfiguration,
            reducesMotion: viewModel.styleConfiguration.reducesMotion(systemReduceMotion: systemReduceMotion),
            onPillDecision: viewModel.decisionHandlerForDisplayedQuestion(onDecisionOptionChosen),
            onToggleChecklist: onToggleChecklist, checklistIsOpen: viewModel.checklistIsOpen)
        .scaleEffect(CGFloat(viewModel.styleConfiguration.cursorScale), anchor: .topLeading)
    }
}

/// The pill's compact answers in one row: the primary answer first (Allow, Resume, Retry, or for a bring-forward
/// "Allow for this task"), then Skip, then Pause while a run works and Stop while planning or a run is live, then the
/// chevron that opens the checklist. When an Allow also has a rest-of-task grant that isn't already a button of its
/// own, a small chevron beside Allow reveals it inline, as a regular button on a line below: panels that never
/// activate Dotto can't open menus.
struct CursorDecisionButtonRow: View {
    let decisionOptions: [UserDecisionOption]
    let stateColor: Color
    /// The paused pill is window-colored, so its buttons invert.
    let isOnHollowPill: Bool
    var includesPause: Bool = false
    var includesStop: Bool = false
    var onToggleChecklist: (() -> Void)? = nil
    var checklistIsOpen: Bool = false
    let onDecision: (UserDecisionOptionIdentifier) -> Void

    @State private var isRestOfTaskOptionRevealed = false

    private static let pauseOption = UserDecisionOption(identifier: .pause, title: "Pause", isPrimary: false)
    private static let stopOption = UserDecisionOption(identifier: .stop, title: "Stop", isPrimary: false)

    /// A rest-of-task grant offered as the primary answer is a button like any other; otherwise it hides behind
    /// Allow's chevron.
    private var hiddenRestOfTaskOption: UserDecisionOption? {
        decisionOptions.first { $0.identifier == .allowRestOfTask && !$0.isPrimary }
    }

    private var rowOptions: [UserDecisionOption] {
        let answerOptions = decisionOptions.filter { decisionOption in
            decisionOption.identifier != .stop && !(decisionOption.identifier == .allowRestOfTask && !decisionOption.isPrimary)
        }
        return answerOptions + (includesPause ? [Self.pauseOption] : []) + (includesStop ? [Self.stopOption] : [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                ForEach(rowOptions, id: \.identifier) { decisionOption in
                    let revealsRestOfTaskOption = decisionOption.identifier == .allow && hiddenRestOfTaskOption != nil
                    CursorPillButtonView(
                        decisionOption: decisionOption, stateColor: stateColor, isOnHollowPill: isOnHollowPill,
                        restOfTaskRevealState: revealsRestOfTaskOption ? $isRestOfTaskOptionRevealed : nil,
                        onDecision: onDecision)
                }
                if let onToggleChecklist {
                    CursorPillChecklistToggleButton(isChecklistOpen: checklistIsOpen, stateColor: stateColor,
                                                    isOnHollowPill: isOnHollowPill, action: onToggleChecklist)
                }
            }
            if isRestOfTaskOptionRevealed, let hiddenRestOfTaskOption {
                CursorPillButtonView(decisionOption: hiddenRestOfTaskOption, stateColor: stateColor, isOnHollowPill: isOnHollowPill,
                                     restOfTaskRevealState: nil, onDecision: onDecision)
            }
        }
        .fixedSize()
        // A new question starts folded.
        .onChange(of: decisionOptions) { isRestOfTaskOptionRevealed = false }
    }
}

/// The small chevron at the end of the pill: it opens the checklist beside the cursor, or folds it back.
private struct CursorPillChecklistToggleButton: View {
    let isChecklistOpen: Bool
    let stateColor: Color
    let isOnHollowPill: Bool
    let action: () -> Void

    private var tooltip: String { isChecklistOpen ? "Hide checklist" : "Show checklist" }

    var body: some View {
        HoverAwarePlainButton(action: action) { isHovered in
            Image(systemName: isChecklistOpen ? "chevron.up" : "chevron.down")
                .font(.system(size: 8, weight: .heavy))
                .foregroundColor(isOnHollowPill ? stateColor : .white)
                // As tall as a 12-point answer title, so the chevron lines up with the buttons beside it.
                .frame(width: 20, height: 15)
                .padding(.vertical, 3)
                .background(
                    Capsule(style: .continuous)
                        .fill(isOnHollowPill ? stateColor.opacity(0.14) : Color.white.opacity(0.22))
                        .brightness(isHovered ? 0.06 : 0)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke((isOnHollowPill ? stateColor.opacity(0.3) : Color.white.opacity(0.35)).opacity(isHovered ? 1 : 0),
                                lineWidth: 2)
                        .padding(-1)
                )
                .contentShape(Rectangle())
        }
        .fixedSize(horizontal: true, vertical: false)
        .nativeTooltip(tooltip)
        .accessibilityLabel(tooltip)
    }
}

/// One answer. When it can reveal the rest-of-task grant it becomes the lab's split button: the answer on the left
/// and a chevron on the right, 1 point apart, which shows or hides that grant below the row.
private struct CursorPillButtonView: View {
    let decisionOption: UserDecisionOption
    let stateColor: Color
    let isOnHollowPill: Bool
    /// Bound to the row's reveal state when this answer carries the chevron; nil for a plain button.
    let restOfTaskRevealState: Binding<Bool>?
    let onDecision: (UserDecisionOptionIdentifier) -> Void

    private var fillColor: Color {
        if decisionOption.isPrimary { return isOnHollowPill ? stateColor : .white }
        return isOnHollowPill ? stateColor.opacity(0.14) : Color.white.opacity(0.22)
    }

    private var titleColor: Color {
        if decisionOption.isPrimary { return isOnHollowPill ? .white : stateColor }
        return isOnHollowPill ? stateColor : .white
    }

    private var hoverRingColor: Color { isOnHollowPill ? stateColor.opacity(0.3) : Color.white.opacity(0.35) }

    /// The card spells answers out ("Not now (skip item)"); the pill keeps one short row.
    static func compactTitle(of decisionOption: UserDecisionOption) -> String {
        switch decisionOption.identifier {
        case .skip: return "Skip"
        default: return decisionOption.title
        }
    }

    var body: some View {
        HStack(spacing: 1) {
            HoverAwarePlainButton(action: { onDecision(decisionOption.identifier) }) { isHovered in
                Text(Self.compactTitle(of: decisionOption))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(titleColor)
                    .lineLimit(1)
                    .padding(.leading, 10)
                    .padding(.trailing, restOfTaskRevealState == nil ? 10 : 8)
                    .padding(.vertical, 3)
                    .modifier(segmentChrome(roundsTrailing: restOfTaskRevealState == nil, isHovered: isHovered))
            }

            if let restOfTaskRevealState {
                let isRevealed = restOfTaskRevealState.wrappedValue
                HoverAwarePlainButton(action: { restOfTaskRevealState.wrappedValue.toggle() }) { isHovered in
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundColor(titleColor)
                        .rotationEffect(.degrees(isRevealed ? 180 : 0))
                        .animation(.easeOut(duration: DesignSystem.Animation.fast), value: isRevealed)
                        .padding(.horizontal, 7)
                        .frame(maxHeight: .infinity)
                        .modifier(segmentChrome(roundsLeading: false, roundsTrailing: true, isHovered: isHovered))
                }
                .nativeTooltip(isRevealed ? "Fewer options" : "More options")
                .accessibilityLabel(isRevealed ? "Fewer options" : "More options for \(Self.compactTitle(of: decisionOption).lowercased())")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func segmentChrome(roundsLeading: Bool = true, roundsTrailing: Bool, isHovered: Bool) -> CursorPillSegmentChrome {
        CursorPillSegmentChrome(roundsLeading: roundsLeading, roundsTrailing: roundsTrailing, fillColor: fillColor,
                                     hoverRingColor: hoverRingColor, isHovered: isHovered)
    }
}

/// The fill and hover ring of one segment of a pill button. A rounded end is a full capsule end; the ends where
/// the answer and its chevron meet stay nearly square.
private struct CursorPillSegmentChrome: ViewModifier {
    let roundsLeading: Bool
    let roundsTrailing: Bool
    let fillColor: Color
    let hoverRingColor: Color
    let isHovered: Bool

    func body(content: Content) -> some View {
        let segmentShape = UnevenRoundedRectangle(
            topLeadingRadius: roundsLeading ? 999 : 4, bottomLeadingRadius: roundsLeading ? 999 : 4,
            bottomTrailingRadius: roundsTrailing ? 999 : 4, topTrailingRadius: roundsTrailing ? 999 : 4,
            style: .continuous)
        return content
            .background(segmentShape.fill(fillColor).brightness(isHovered ? 0.06 : 0))
            .overlay(segmentShape.stroke(hoverRingColor.opacity(isHovered ? 1 : 0), lineWidth: 2).padding(-1))
            .contentShape(Rectangle())
    }
}

/// The pill's text and its buttons side by side while both fit `maximumContentWidth`; otherwise the text wraps (up
/// to its own line limit) at that width and the buttons go on a row below it. It sizes from its subviews' ideal
/// sizes, so it works inside the pill's `fixedSize`.
private struct CursorPillWrappingLayout: Layout {
    let maximumContentWidth: CGFloat
    let spacing: CGFloat

    private struct Arrangement {
        var frames: [CGRect]
        var size: CGSize
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        arrangement(of: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        for (subview, subviewFrame) in zip(subviews, arrangement(of: subviews).frames) {
            subview.place(at: CGPoint(x: bounds.minX + subviewFrame.minX, y: bounds.minY + subviewFrame.minY),
                          proposal: ProposedViewSize(subviewFrame.size))
        }
    }

    private func arrangement(of subviews: Subviews) -> Arrangement {
        let idealSizes = subviews.map { $0.sizeThatFits(.unspecified) }
        if subviews.count == 1 {
            // Text alone (or buttons alone): wrapped at the maximum width when it is wider.
            let onlySize = subviews[0].sizeThatFits(ProposedViewSize(width: min(idealSizes[0].width, maximumContentWidth), height: nil))
            return Arrangement(frames: [CGRect(origin: .zero, size: onlySize)], size: onlySize)
        }
        let singleRowWidth = idealSizes.map(\.width).reduce(0, +) + spacing * CGFloat(max(0, idealSizes.count - 1))
        if singleRowWidth <= maximumContentWidth || subviews.isEmpty {
            let rowHeight = idealSizes.map(\.height).max() ?? 0
            var nextOriginX: CGFloat = 0
            var frames: [CGRect] = []
            for idealSize in idealSizes {
                frames.append(CGRect(x: nextOriginX, y: (rowHeight - idealSize.height) / 2,
                                     width: min(idealSize.width, maximumContentWidth), height: idealSize.height))
                nextOriginX += idealSize.width + spacing
            }
            return Arrangement(frames: frames, size: CGSize(width: max(0, singleRowWidth), height: rowHeight))
        }
        // Text first, wrapped at the maximum width; everything after it on its own rows below.
        var frames: [CGRect] = []
        let wrappedTextSize = subviews[0].sizeThatFits(ProposedViewSize(width: min(idealSizes[0].width, maximumContentWidth), height: nil))
        frames.append(CGRect(origin: .zero, size: wrappedTextSize))
        var nextOriginY = wrappedTextSize.height + spacing * 0.75
        var usedWidth = wrappedTextSize.width
        for idealSize in idealSizes.dropFirst() {
            frames.append(CGRect(x: 0, y: nextOriginY, width: idealSize.width, height: idealSize.height))
            nextOriginY += idealSize.height + spacing * 0.75
            usedWidth = max(usedWidth, idealSize.width)
        }
        return Arrangement(frames: frames, size: CGSize(width: usedWidth, height: nextOriginY - spacing * 0.75))
    }
}
