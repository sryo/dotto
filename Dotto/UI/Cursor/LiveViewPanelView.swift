import SwiftUI

/// The live view of a covered target window, from the cursor lab's picture-in-picture: a dark header with the app
/// and status, the streamed window with Dotto's cursor drawn where it works, and a collapse control. When Dotto
/// needs the user, the cursor's own pill docks to the panel (above it in a bottom corner, below it in a top corner)
/// with the same buttons, and the panel takes a task-color outline and bounces. Collapsed, the panel itself turns
/// task-colored and carries the buttons. While a run is live the header carries Stop.
struct LiveViewPanelView: View {
    @ObservedObject var viewModel: CursorViewModel
    let onToggleCollapsed: () -> Void
    let onToggleChecklist: () -> Void
    let onDecisionOptionChosen: DecisionOptionHandler
    /// The panel follows the size reported here; see `DeferredPanelFrameApplier`.
    let contentSizeBox: PanelContentSizeBox

    static let expandedWidth: CGFloat = 360
    static let collapsedWidth: CGFloat = 240
    /// Keeps the expanded panel itself at or under 260 points tall.
    static let maximumPreviewHeight: CGFloat = 196
    /// Room around the panel for its shadow and the bounce, inside the window.
    static let shadowPadding: CGFloat = 16
    private static let panelFillColor = Color(red: 24 / 255, green: 22 / 255, blue: 34 / 255).opacity(0.92)

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    private var reducesMotion: Bool { viewModel.styleConfiguration.reducesMotion(systemReduceMotion: systemReduceMotion) }
    private var stateColor: Color { viewModel.styleConfiguration.stateColor(for: viewModel.appearance.activity) }
    /// Dotto is waiting on a decision (or a pause) that the live view's buttons can answer.
    private var needsUser: Bool { !viewModel.pillDecisionOptions.isEmpty }
    private var isShowingFinishedNote: Bool { viewModel.presentationState.attentionRequest?.kind == .finished }
    private var showsDockedPill: Bool { (needsUser && !viewModel.isCollapsed) || isShowingFinishedNote }
    private var dockedPillIsBelowPanel: Bool { viewModel.liveViewCorner.isTop }
    private var panelWidth: CGFloat { viewModel.isCollapsed ? Self.collapsedWidth : Self.expandedWidth }
    private var decisionHandlerForDisplayedQuestion: (UserDecisionOptionIdentifier) -> Void {
        viewModel.decisionHandlerForDisplayedQuestion(onDecisionOptionChosen)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if dockedPillIsBelowPanel {
                panelCard
                if showsDockedPill { dockedPill.transition(dockedPillTransition) }
            } else {
                if showsDockedPill { dockedPill.transition(dockedPillTransition) }
                panelCard
            }
        }
        .animation(DesignSystem.Motion.animation(DesignSystem.Motion.appear, reducesMotion: reducesMotion), value: showsDockedPill)
        .keyframeAnimator(initialValue: CGFloat(0), trigger: viewModel.liveViewBounceCount) { bouncingPanel, verticalBounce in
            bouncingPanel.offset(y: verticalBounce)
        } keyframes: { _ in
            // The lab's `pipbounce`: up 9, down, up 3, settle, over 0.62 s.
            KeyframeTrack {
                CubicKeyframe(reducesMotion ? 0 : -9, duration: 0.17)
                CubicKeyframe(0, duration: 0.15)
                CubicKeyframe(reducesMotion ? 0 : -3, duration: 0.12)
                CubicKeyframe(0, duration: 0.18)
            }
        }
        .padding(Self.shadowPadding)
        .fixedSize()
        .reportingPanelContentSize(to: contentSizeBox)
    }

    private var dockedPillTransition: AnyTransition {
        .opacity.combined(with: .offset(y: dockedPillIsBelowPanel ? -10 : 10)).combined(with: .scale(scale: 0.95))
    }

    // MARK: Panel

    private var panelCard: some View {
        let isTaskColoredCollapsedPill = viewModel.isCollapsed && needsUser
        return VStack(alignment: .leading, spacing: 0) {
            header(onTaskColor: isTaskColoredCollapsedPill)
            if !viewModel.isCollapsed {
                preview
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            } else if needsUser {
                CursorDecisionButtonRow(decisionOptions: viewModel.pillDecisionOptions, stateColor: stateColor,
                                             isOnHollowPill: false, onDecision: decisionHandlerForDisplayedQuestion)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            } else {
                collapsedProgressBar
            }
        }
        .frame(width: panelWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(isTaskColoredCollapsedPill ? stateColor : Self.panelFillColor)
                .shadow(color: .black.opacity(0.35), radius: 16, x: 0, y: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(stateColor, lineWidth: needsUser && !isTaskColoredCollapsedPill ? 2 : 0)
        )
        .animation(reducesMotion ? nil : .easeInOut(duration: 0.2), value: needsUser)
    }

    private func header(onTaskColor: Bool) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(onTaskColor ? .white : stateColor)
                    .frame(width: 8, height: 8)
                (Text("Dotto").fontWeight(.bold) + Text(" · " + headerStatusText))
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .overlay(PanelDragArea(tooltip: nil))
            Spacer(minLength: 4)
            // Stop sits in the header, so it is there expanded and collapsed, with or without a question docked.
            if viewModel.appearance.offersStop {
                LiveViewHeaderButton(tooltip: "Stop Dotto", action: { decisionHandlerForDisplayedQuestion(.stop) }) {
                    Text("Stop")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 8)
                }
            }
            // While the target window is covered, the checklist opens beside this panel.
            if viewModel.appearance.offersChecklistToggle {
                let checklistToggleTooltip = viewModel.checklistIsOpen ? "Hide checklist" : "Show checklist"
                LiveViewHeaderButton(tooltip: checklistToggleTooltip, action: onToggleChecklist) {
                    Image(systemName: "checklist")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 22)
                }
            }
            let collapseToggleTooltip = viewModel.isCollapsed ? "Expand live view" : "Collapse live view"
            LiveViewHeaderButton(tooltip: collapseToggleTooltip, action: onToggleCollapsed) {
                Image(systemName: viewModel.isCollapsed ? "plus" : "minus")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 22)
            }
        }
        .padding(.leading, 11)
        .padding([.trailing, .vertical], 8)
        .background(PanelDragArea(tooltip: nil))
    }

    /// "Finder · Rename IMG_2042" expanded; "Finder · 12/49" collapsed, where the preview can't show progress.
    private var headerStatusText: String {
        let statusText = viewModel.isCollapsed && !needsUser
            ? (viewModel.itemPositionText ?? viewModel.appearance.pillText)
            : viewModel.appearance.pillText
        return [viewModel.targetApplicationName, statusText].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var preview: some View {
        let windowSize = viewModel.targetWindowSizeInPoints
        let availableWidth = Self.expandedWidth - 20
        let windowAspectRatio = windowSize.width > 0 ? windowSize.height / windowSize.width : 0.66
        let previewHeight = min(availableWidth * windowAspectRatio, Self.maximumPreviewHeight)
        let previewWidth = windowAspectRatio > 0 ? min(availableWidth, previewHeight / windowAspectRatio) : availableWidth
        let windowToPreviewScale = windowSize.width > 0 ? previewWidth / windowSize.width : 1
        var liveViewCursorConfiguration = viewModel.styleConfiguration
        // The lab shrinks the cursor to 55% inside the live view and hides its pill.
        liveViewCursorConfiguration.cursorScale = viewModel.styleConfiguration.cursorScale * 0.55

        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
            if let latestFrame = viewModel.latestFrame {
                Image(decorative: latestFrame, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .frame(width: previewWidth, height: previewHeight)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: previewWidth, height: previewHeight)
            }
            CursorView(appearance: viewModel.appearance, configuration: liveViewCursorConfiguration, showsPill: false,
                       isOnShownSurface: viewModel.surface == .liveViewPanel)
                .offset(x: viewModel.cursorPointInWindow.x * windowToPreviewScale,
                        y: viewModel.cursorPointInWindow.y * windowToPreviewScale)
        }
        .frame(width: previewWidth, height: previewHeight, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(PanelDragArea(tooltip: "Live view of \(viewModel.targetApplicationName). Dotto works here in the background."))
        .frame(maxWidth: .infinity)
    }

    private var collapsedProgressBar: some View {
        let itemProgress = CGFloat(min(max(viewModel.presentationState.progress ?? 0, 0), 1))
        return ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.12))
            Capsule().fill(stateColor).frame(width: (Self.collapsedWidth - 22) * itemProgress)
        }
        .frame(height: 2)
        .padding(.horizontal, 11)
        .padding(.bottom, 7)
        .allowsHitTesting(false)
    }

    // MARK: Docked pill

    /// The cursor's pill, docked: same color, type and buttons, with a small tail pointing at the panel.
    private var dockedPill: some View {
        let pillText = viewModel.appearance.pillText
        let decisionButtonRow = CursorDecisionButtonRow(decisionOptions: viewModel.pillDecisionOptions,
                                                             stateColor: stateColor, isOnHollowPill: false,
                                                             onDecision: decisionHandlerForDisplayedQuestion)
        return HStack(alignment: .center, spacing: 8) {
            CursorArrowShape()
                .fill(Color.white)
                .frame(width: 12, height: 12)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    Text(pillText).lineLimit(1)
                    Spacer(minLength: 0)
                    if needsUser { decisionButtonRow }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(pillText).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    if needsUser { decisionButtonRow }
                }
            }
        }
        .font(.system(size: 12.5, weight: .semibold))
        .foregroundColor(.white)
        .padding(.vertical, 7)
        .padding(.leading, 11)
        .padding(.trailing, 8)
        .frame(width: panelWidth - 20, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .fill(stateColor)
                .shadow(color: CursorPalette.pillShadowColor.opacity(0.3), radius: 11, x: 0, y: 8)
        )
        .overlay(alignment: dockedPillIsBelowPanel ? .topLeading : .bottomLeading) {
            DockedPillTail(pointsUp: dockedPillIsBelowPanel)
                .fill(stateColor)
                .frame(width: 12, height: 6)
                .offset(x: 14, y: dockedPillIsBelowPanel ? -6 : 6)
        }
        .padding(.leading, 10)
    }
}

private struct DockedPillTail: Shape {
    let pointsUp: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if pointsUp {
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        } else {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        }
        path.closeSubpath()
        return path
    }
}

/// A small white-on-dark header control (Stop, collapse) that brightens on hover.
private struct LiveViewHeaderButton<Label: View>: View {
    let tooltip: String
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        HoverAwarePlainButton(action: action) { isHovered in
            label()
                .foregroundColor(.white)
                .frame(height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(isHovered ? 0.2 : 0.1))
                )
        }
        .nativeTooltip(tooltip)
        .accessibilityLabel(tooltip)
    }
}
