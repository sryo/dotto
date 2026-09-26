import AppKit
import SwiftUI
import Combine

/// The floating checklist, a popover that belongs to Dotto's cursor: it opens beside the cursor's pill (or beside the
/// live view while the target window is covered, or beside the summon point once the cursor is gone), with a small
/// tail aimed at it. Without any of those it sits inside the target window's top-right corner. It lets the user
/// review and edit the plan, tracks each item while it runs, and hosts the cards that wait for the user.
@MainActor
final class ChecklistPanelController {
    private static let checklistPanelWidth: CGFloat = 380
    /// Used only until the content has reported its height once.
    private static let fallbackContentHeight: CGFloat = 200

    private let sessionScope: TaskSessionScope
    private var checklistPanel: ChecklistKeyablePanel?
    private var checklistHostingView: NSHostingView<AnyView>?
    private var panelFrameApplier: DeferredPanelFrameApplier?
    private let contentSizeBox = PanelContentSizeBox()
    private let layoutModel = ChecklistPopoverLayoutModel()
    private let replyComposerModel = PlannerReplyComposerModel()
    private let placementCalculator = AttachedPanelPlacementCalculator()
    /// What the panel hangs from while it is open. A new anchor is taken each time it opens, so it opens next to
    /// wherever the cursor is then; while open it stays put and only its height follows the content.
    private var currentAnchor: AttachedPanelAnchor?
    private var currentPlacement: AttachedPanelPlacement?

    /// Called with true when the panel opens and false when it closes, so the cursor's pill can show which way its
    /// checklist chevron points.
    var onVisibilityChanged: ((Bool) -> Void)?

    init(sessionScope: TaskSessionScope) {
        self.sessionScope = sessionScope
    }

    var isVisible: Bool {
        checklistPanel?.isVisible ?? false
    }

    /// Opens the panel beside `explicitAnchor`, or beside whatever the task session says it belongs to now. A panel
    /// that is already open stays where it is unless an anchor is given.
    func showChecklistPanel(makeKey: Bool, anchor explicitAnchor: AttachedPanelAnchor? = nil) {
        let checklistPanel = self.checklistPanel ?? makeChecklistPanel()
        self.checklistPanel = checklistPanel
        let wasVisible = checklistPanel.isVisible

        if !wasVisible || explicitAnchor != nil {
            let anchor = explicitAnchor ?? sessionScope.checklistPanelAnchor()
            currentAnchor = anchor
            currentPlacement = nil
            // Set before measuring: the content lays itself out within the room this anchor leaves on screen.
            let maximumCardHeight = placementCalculator.maximumPanelHeight(
                anchor: anchor, visibleFrame: ScreenGeometry.visibleFrameInTopLeftGlobalPoints(
                    ofScreenContainingTopLeftGlobalPoint: Self.referencePoint(of: anchor)))
            if layoutModel.maximumCardHeight != maximumCardHeight { layoutModel.maximumCardHeight = maximumCardHeight }
            panelFrameApplier?.cancelPendingFrameUpdate()
            if !wasVisible { prepareEntrance(of: checklistPanel) }
            if let panelFrame = placedPanelFrame(forContentHeight: measuredContentHeight()) {
                panelFrameApplier?.applyFrameNow(panelFrame)
            }
        }
        if makeKey {
            checklistPanel.makeKeyAndOrderFront(nil)
        }
        checklistPanel.orderFrontRegardless()
        if !wasVisible {
            enter(checklistPanel)
            onVisibilityChanged?(true)
        }
    }

    private var reducesMotion: Bool {
        sessionScope.taskStyleConfiguration.reducesMotion(
            systemReduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    /// The popover grows out of what it hangs from: it starts slightly smaller, at the point its tail aims from, and
    /// transparent, and is shown in that state.
    private func prepareEntrance(of checklistPanel: ChecklistKeyablePanel) {
        var startingStateTransaction = Transaction()
        startingStateTransaction.disablesAnimations = true
        withTransaction(startingStateTransaction) {
            layoutModel.hasEntered = false
        }
        checklistPanel.alphaValue = 0
    }

    /// Grows to full size on the appear spring while its window (and the window's shadow) fades in; under Reduce
    /// Motion it only fades in, briefly.
    private func enter(_ checklistPanel: ChecklistKeyablePanel) {
        if let currentPlacement {
            layoutModel.growthAnchor = Self.growthAnchor(of: currentPlacement)
        }
        let reducesMotion = self.reducesMotion
        // Started on the next turn, once the starting state is on screen.
        DispatchQueue.main.async { [weak self, weak checklistPanel] in
            MainActor.assumeIsolated {
                guard let self, let checklistPanel, checklistPanel.isVisible else { return }
                withAnimation(DesignSystem.Motion.appearOrFade(reducesMotion: reducesMotion)) {
                    self.layoutModel.hasEntered = true
                }
                NSAnimationContext.runAnimationGroup({ animationContext in
                    animationContext.duration = reducesMotion
                        ? DesignSystem.Motion.reducedMotionFadeDurationSeconds
                        : DesignSystem.Motion.windowFadeInDurationSeconds
                    animationContext.timingFunction = DesignSystem.Motion.windowFadeTimingFunction
                    checklistPanel.animator().alphaValue = 1
                }, completionHandler: { [weak checklistPanel] in
                    MainActor.assumeIsolated { checklistPanel?.invalidateShadow() }
                })
            }
        }
    }

    /// The tail's tip when there is a tail (it points at the cursor's pill); otherwise the corner the panel opened from.
    private static func growthAnchor(of placement: AttachedPanelPlacement) -> UnitPoint {
        let panelWidth = max(placement.panelFrame.width, 1)
        if let tail = placement.tail {
            return UnitPoint(x: min(max(tail.centerOffsetFromLeftEdge / panelWidth, 0), 1), y: tail.edge == .top ? 0 : 1)
        }
        return UnitPoint(x: placement.horizontalDirection == .rightward ? 0 : 1,
                         y: placement.verticalDirection == .below ? 0 : 1)
    }

    /// Opens the thread with its reply field focused. The popover takes the keyboard only here, for a question
    /// about the command the user just summoned Dotto with (or when they reopen it to answer).
    func showPlannerReplyField(anchor explicitAnchor: AttachedPanelAnchor? = nil) {
        showChecklistPanel(makeKey: true, anchor: explicitAnchor)
        replyComposerModel.requestFocus()
        // SwiftUI ignores a focus request made before its window is key, so it is asked again on the next turn.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let checklistPanel = self.checklistPanel, checklistPanel.isVisible,
                      self.sessionScope.isWaitingForPlannerReply else { return }
                if !checklistPanel.isKeyWindow { checklistPanel.makeKey() }
                self.replyComposerModel.requestFocus()
            }
        }
    }

    func resignKeyWithoutHiding() {
        guard let checklistPanel, checklistPanel.isKeyWindow else { return }
        // A non-activating panel that is key keeps receiving keystrokes. Re-activating whichever app is in front
        // now (the user may be in Mail while Dotto works in Arc) hands the keyboard back; never the target app.
        if let frontmostApplication = NSWorkspace.shared.frontmostApplication,
           frontmostApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            frontmostApplication.activate()
        }
        checklistPanel.orderFrontRegardless()
    }

    /// Folds the checklist back into the cursor's pill, giving the keyboard back first if the panel had it.
    func collapseIntoCursor() {
        resignKeyWithoutHiding()
        hideChecklistPanel()
    }

    func hideChecklistPanel() {
        let wasVisible = isVisible
        panelFrameApplier?.cancelPendingFrameUpdate()
        checklistPanel?.orderOut(nil)
        checklistPanel?.alphaValue = 1
        currentAnchor = nil
        currentPlacement = nil
        if wasVisible { onVisibilityChanged?(false) }
    }

    private func makeChecklistPanel() -> ChecklistKeyablePanel {
        let checklistPanel = ChecklistKeyablePanel(contentRect: NSRect(x: 0, y: 0, width: Self.checklistPanelWidth,
                                                                       height: Self.fallbackContentHeight))
        checklistPanel.hasShadow = true
        // Buttons work without taking keyboard focus from the target app; only the label text fields make the panel key.
        checklistPanel.becomesKeyOnlyIfNeeded = true
        checklistPanel.onEscapeKeyPressed = { [weak self] in
            guard let sessionScope = self?.sessionScope else { return false }
            if sessionScope.sessionState.isBusy {
                sessionScope.stopTask()
                return true
            }
            // Esc on the planner's question closes the thread and ends the task, like Close.
            if case .plannerNeedsInput = sessionScope.sessionState {
                sessionScope.dismissFinishedTask()
                return true
            }
            return false
        }
        checklistPanel.onReturnKeyPressed = { [weak self] isShiftPressed, focusedTextView in
            guard let self, self.sessionScope.isWaitingForPlannerReply,
                  let currentQuestion = self.currentPlannerQuestion, currentQuestion.allowsFreeText else { return false }
            if isShiftPressed {
                focusedTextView?.insertNewlineIgnoringFieldEditor(nil)
            } else {
                self.submitReplyDraft()
            }
            return true
        }
        let hostingView = NSHostingView(rootView: AnyView(ChecklistPopoverView(
            sessionScope: sessionScope,
            layoutModel: layoutModel,
            replyComposerModel: replyComposerModel,
            onSubmitReplyDraft: { [weak self] in self?.submitReplyDraft() },
            onContentHeightChange: { [contentSizeBox] contentHeight in
                contentSizeBox.record(CGSize(width: Self.checklistPanelWidth, height: contentHeight))
            }
        ).drawsControlsAsActive())).withClearBackground().sizedOnlyByItsPanel()
        checklistPanel.contentView = hostingView
        checklistHostingView = hostingView
        let panelFrameApplier = DeferredPanelFrameApplier(panel: checklistPanel)
        self.panelFrameApplier = panelFrameApplier
        // Reported from inside SwiftUI's update: the new frame is applied on a later turn of the run loop.
        contentSizeBox.onContentSizeChange = { [weak self] _ in
            guard let self, self.isVisible else { return }
            self.panelFrameApplier?.scheduleFrameUpdate { [weak self] in
                guard let self, self.isVisible else { return nil }
                return self.placedPanelFrame(forContentHeight: self.contentSizeBox.latestContentSize.height)
            }
        }
        return checklistPanel
    }

    private var currentPlannerQuestion: PlannerQuestion? {
        if case .plannerNeedsInput(_, let plannerQuestion) = sessionScope.sessionState { return plannerQuestion }
        return nil
    }

    /// Return in the reply field and the Send button: the typed reply goes to the planner and the field empties.
    private func submitReplyDraft() {
        let draftText = replyComposerModel.draftText
        guard !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        replyComposerModel.draftText = ""
        sessionScope.sendPlannerReply(draftText)
    }

    private func measuredContentHeight() -> CGFloat {
        let reportedContentHeight = checklistHostingView?.laidOutContentSize(reportedTo: contentSizeBox).height ?? 0
        return reportedContentHeight > 0 ? reportedContentHeight : Self.fallbackContentHeight
    }

    /// Places the card beside the current anchor, keeping the edge it opened from while its height changes, and
    /// returns the window frame (card plus tail) in AppKit coordinates.
    private func placedPanelFrame(forContentHeight contentHeight: CGFloat) -> CGRect? {
        guard let currentAnchor, contentHeight > 0 else { return nil }
        let panelSize = CGSize(width: Self.checklistPanelWidth, height: contentHeight)
        let visibleFrame = ScreenGeometry.visibleFrameInTopLeftGlobalPoints(
            ofScreenContainingTopLeftGlobalPoint: Self.referencePoint(of: currentAnchor))
        let placement = placementCalculator.placement(forPanelSize: panelSize, anchor: currentAnchor, visibleFrame: visibleFrame,
                                                      previousPlacement: currentPlacement)
        currentPlacement = placement
        if layoutModel.tail != placement.tail { layoutModel.tail = placement.tail }

        var windowFrameInTopLeftGlobalPoints = placement.panelFrame
        switch placement.tail?.edge {
        case .top:
            windowFrameInTopLeftGlobalPoints.origin.y -= AttachedPanelPlacementCalculator.tailLength
            windowFrameInTopLeftGlobalPoints.size.height += AttachedPanelPlacementCalculator.tailLength
        case .bottom:
            windowFrameInTopLeftGlobalPoints.size.height += AttachedPanelPlacementCalculator.tailLength
        case nil:
            break
        }
        return ScreenGeometry.appKitFrame(fromTopLeftGlobalFrame: windowFrameInTopLeftGlobalPoints)
    }

    /// The point whose screen the panel should stay on.
    private static func referencePoint(of anchor: AttachedPanelAnchor) -> CGPoint {
        switch anchor {
        case .besideCursor(let anchorPoint, _): return anchorPoint
        case .besidePanel(let panelFrame): return CGPoint(x: panelFrame.midX, y: panelFrame.midY)
        case .insideTopRightCorner(let containerFrame): return CGPoint(x: containerFrame.maxX - 1, y: containerFrame.minY + 1)
        }
    }
}

/// Set by the controller whenever it places the panel: where the tail sits, and how tall the card may grow before
/// its list or thread scrolls (the room beside the anchor on this screen).
@MainActor
final class ChecklistPopoverLayoutModel: ObservableObject {
    @Published var tail: AttachedPanelTail?
    @Published var maximumCardHeight: CGFloat = 560
    /// False only while the popover is about to grow in from `growthAnchor`.
    @Published var hasEntered = true
    @Published var growthAnchor: UnitPoint = .topLeading
}

/// The planning thread's reply field: its text, kept here so Return (caught by the panel) can send it, and requests
/// for it to take the keyboard focus.
@MainActor
final class PlannerReplyComposerModel: ObservableObject {
    @Published var draftText = ""
    @Published private(set) var focusRequestCount = 0

    func requestFocus() {
        focusRequestCount += 1
    }
}

/// The checklist card with its tail on the edge that faces the cursor.
private struct ChecklistPopoverView: View {
    @ObservedObject var sessionScope: TaskSessionScope
    @ObservedObject var layoutModel: ChecklistPopoverLayoutModel
    let replyComposerModel: PlannerReplyComposerModel
    let onSubmitReplyDraft: () -> Void
    let onContentHeightChange: (CGFloat) -> Void

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    private var reducesMotion: Bool {
        sessionScope.taskStyleConfiguration.reducesMotion(systemReduceMotion: systemReduceMotion)
    }

    var body: some View {
        let tailLength = AttachedPanelPlacementCalculator.tailLength
        let tail = layoutModel.tail
        return ChecklistPanelView(sessionScope: sessionScope, replyComposerModel: replyComposerModel,
                                  maximumCardHeight: layoutModel.maximumCardHeight, onSubmitReplyDraft: onSubmitReplyDraft,
                                  onContentHeightChange: onContentHeightChange)
            .padding(.top, tail?.edge == .top ? tailLength : 0)
            .padding(.bottom, tail?.edge == .bottom ? tailLength : 0)
            .overlay(alignment: tail?.edge == .bottom ? .bottomLeading : .topLeading) {
                if let tail {
                    AttachedPanelTailView(pointsUp: tail.edge == .top)
                        .offset(x: tail.centerOffsetFromLeftEdge - AttachedPanelPlacementCalculator.tailWidth / 2)
                }
            }
            .scaleEffect(layoutModel.hasEntered || reducesMotion ? 1 : DesignSystem.Motion.panelAppearScale,
                         anchor: layoutModel.growthAnchor)
    }
}

/// Esc stops Dotto only while this panel is key. Dotto never watches the keyboard globally, so this is the one
/// place Esc means "stop". The key is caught before the responder chain because a focused label field's editor
/// would otherwise swallow it.
///
/// Return is caught here too, for the planning thread's reply field: a vertical text field's editor would otherwise
/// decide on its own whether Return ends editing or adds a line. Return sends; Shift-Return adds a line.
final class ChecklistKeyablePanel: KeyablePanel {
    /// Returns true when the key was used; otherwise it goes on to the focused view as usual.
    var onEscapeKeyPressed: (() -> Bool)?
    /// Called with whether Shift is down and the focused field editor; returns true when the key was used.
    var onReturnKeyPressed: ((Bool, NSTextView?) -> Bool)?

    private static let escapeVirtualKeyCode: UInt16 = 53
    private static let returnVirtualKeyCode: UInt16 = 36
    private static let keypadEnterVirtualKeyCode: UInt16 = 76

    override func sendEvent(_ event: NSEvent) {
        guard event.type == .keyDown else {
            super.sendEvent(event)
            return
        }
        let focusedTextView = firstResponder as? NSTextView
        // While an input method is composing, Esc and Return belong to it (they cancel or commit the composition).
        let isComposingText = focusedTextView?.hasMarkedText() == true
        if !isComposingText, event.keyCode == Self.escapeVirtualKeyCode,
           event.modifierFlags.isDisjoint(with: [.command, .option, .control, .shift]),
           onEscapeKeyPressed?() == true {
            return
        }
        if !isComposingText, focusedTextView != nil,
           event.keyCode == Self.returnVirtualKeyCode || event.keyCode == Self.keypadEnterVirtualKeyCode,
           event.modifierFlags.isDisjoint(with: [.command, .option, .control]),
           onReturnKeyPressed?(event.modifierFlags.contains(.shift), focusedTextView) == true {
            return
        }
        super.sendEvent(event)
    }
}
