import AppKit
import Combine
import SwiftUI

/// Asks the command field to take the keyboard focus. SwiftUI ignores a focus request made while its window isn't
/// key yet, and the field's onAppear can run before the panel becomes key, so the controller asks again once it is.
@MainActor
final class CommandFieldFocusRequest: ObservableObject {
    @Published private(set) var requestCount = 0

    func requestFocus() {
        requestCount += 1
    }
}

/// A command submitted from the pill at the pointer: the capsule the cursor's status pill takes the place of, the
/// pill's whole content (the capsule and the hint under it) in top-left global points, and the text, for the morph.
struct SubmittedCommandPill {
    let commandPillHandoff: CommandPillHandoff
    let commandPillContentFrame: CGRect
    let submittedCommandText: String
    /// False under Reduce Motion: the status pill simply appears in the capsule's place.
    let morphsIntoStatusPill: Bool
}

/// The Spotlight-style field for typing a task, in two forms sharing one panel: the command bar near the top of the
/// screen (the summon shortcut) and the command pill at the pointer (the circle gesture). The panel is
/// non-activating so the user's app stays frontmost, yet it can become key so the text field receives typing, which
/// is allowed only because the user summoned it.
@MainActor
final class CommandBarPanelController {
    private let taskSessionController: TaskSessionController
    private var commandBarPanel: KeyablePanel?
    private var commandBarPanelFrameApplier: DeferredPanelFrameApplier?
    private let commandContentSizeBox = PanelContentSizeBox()
    private let commandFieldFocusRequest = CommandFieldFocusRequest()
    private var commandBarPanelBecameKeyObserver: NSObjectProtocol?
    private var clickOutsideMonitor: Any?
    private let commandBarWidth: CGFloat = 560
    private let commandPillPlacementCalculator = PillPlacementCalculator()
    /// The pointer the shown pill hangs from, and where it went, so a pill that changes size stays beside the pointer
    /// and on screen; nil while the command bar (or nothing) is shown.
    private var commandPillPointerInTopLeftGlobalPoints: CGPoint?
    private var latestCommandPillPlacement: PillPlacement?
    /// Only if the pill's content hasn't reported its size: the capsule and the hint under it.
    private static let fallbackCommandPillSize = CGSize(width: CommandPillView.pillWidth, height: 64)
    /// Called after the panel is shown or hidden, so the circle gesture can stop or resume observing.
    var onVisibilityChanged: (() -> Void)?
    /// Called when the pill closes without a command (Esc or a click elsewhere).
    private var onCommandPillDismissed: (() -> Void)?
    private var commandPillReducesMotion = false
    private var commandPillEntrance: CommandPillEntrance?
    /// Click-through and never key: the submitted pill morphs into the cursor's status pill here, after the command
    /// panel has handed the keyboard back.
    private var commandPillMorphPanel: DottoPanel?
    private var commandPillMorphPanelFrameApplier: DeferredPanelFrameApplier?
    /// The morph under way; its finish runs once, from the animation's completion or the fallback timer.
    private var commandPillMorphIdentifier: UUID?
    private var onCommandPillMorphFinished: (() -> Void)?
    private static let commandPillMorphShadowMargin: CGFloat = 24

    init(taskSessionController: TaskSessionController) {
        self.taskSessionController = taskSessionController
    }

    var isVisible: Bool {
        commandBarPanel?.isVisible ?? false
    }

    func showCommandBar(prefilledCommandText: String) {
        finishCommandPillMorph()
        let commandBarPanel = self.commandBarPanel ?? makeCommandBarPanel()
        self.commandBarPanel = commandBarPanel

        // A fresh hosting view per presentation resets the text field and re-runs
        // onAppear, which is what moves keyboard focus into the field.
        let hostingView = NSHostingView(rootView: AnyView(CommandBarView(
            taskSessionController: taskSessionController,
            commandFieldFocusRequest: commandFieldFocusRequest,
            initialCommandText: prefilledCommandText,
            onDismiss: { [weak self] in self?.hideCommandBar() }
        ).drawsControlsAsActive().fixedSize().reportingPanelContentSize(to: commandContentSizeBox)))
            .withClearBackground().sizedOnlyByItsPanel()
        commandBarPanel.contentView = hostingView
        // The bar's rounded card casts the window server's shadow; the pill draws its own, in room around it.
        commandBarPanel.hasShadow = true
        commandPillEntrance = nil

        let commandBarHeight = hostingView.laidOutContentSize(reportedTo: commandContentSizeBox).height
        if let screenFrame = ScreenGeometry.screenUnderMouse?.frame, commandBarHeight > 0 {
            // AppKit y grows upward, so 70% of the height is the upper part of the screen.
            let commandBarCenterY = screenFrame.minY + screenFrame.height * 0.7
            commandBarPanelFrameApplier?.applyFrameNow(NSRect(
                x: screenFrame.midX - commandBarWidth / 2,
                y: commandBarCenterY - commandBarHeight / 2,
                width: commandBarWidth,
                height: commandBarHeight))
        }

        onCommandPillDismissed = nil
        commandPillPointerInTopLeftGlobalPoints = nil
        latestCommandPillPlacement = nil
        presentKey(commandBarPanel)
    }

    /// Opens the pill below and right of the pointer, flipped left of or above it near an edge of the pointer's
    /// screen so it stays inside that screen's visible frame. `onDismiss` runs when it closes without a command.
    func showCommandPill(atTopLeftGlobalPoint topLeftGlobalPoint: CGPoint, reducesMotion: Bool, onDismiss: @escaping () -> Void) {
        finishCommandPillMorph()
        commandPillReducesMotion = reducesMotion
        let commandBarPanel = self.commandBarPanel ?? makeCommandBarPanel()
        self.commandBarPanel = commandBarPanel

        let commandPillEntrance = CommandPillEntrance()
        self.commandPillEntrance = commandPillEntrance
        let hostingView = NSHostingView(rootView: AnyView(CommandPillView(
            taskSessionController: taskSessionController,
            commandFieldFocusRequest: commandFieldFocusRequest,
            entrance: commandPillEntrance,
            reducesMotion: reducesMotion,
            onDismiss: { [weak self] in self?.hideCommandBar() }
        ).drawsControlsAsActive().fixedSize().reportingPanelContentSize(to: commandContentSizeBox)))
            .withClearBackground().sizedOnlyByItsPanel()
        commandBarPanel.contentView = hostingView
        // The capsule draws the status pill's own shadow, which the morph carries on; a window shadow would vanish at
        // the handoff.
        commandBarPanel.hasShadow = false

        let reportedCommandPillPanelSize = hostingView.laidOutContentSize(reportedTo: commandContentSizeBox)
        commandPillPointerInTopLeftGlobalPoints = topLeftGlobalPoint
        latestCommandPillPlacement = nil
        commandBarPanelFrameApplier?.applyFrameNow(commandPillPanelFrame(forPanelSize: reportedCommandPillPanelSize,
                                                                         pointerPoint: topLeftGlobalPoint))
        if let latestCommandPillPlacement {
            // The pill grows from its corner nearest the pointer, whichever way it flipped.
            commandPillEntrance.growthAnchor = UnitPoint(x: latestCommandPillPlacement.horizontalSide == .rightOfTip ? 0 : 1,
                                                         y: latestCommandPillPlacement.verticalSide == .belowTip ? 0 : 1)
        }

        onCommandPillDismissed = onDismiss
        presentKey(commandBarPanel)
        // Started once the panel is on screen, so the first frame drawn is the pill's starting state.
        DispatchQueue.main.async { [weak commandPillEntrance] in
            MainActor.assumeIsolated { commandPillEntrance?.enter(reducesMotion: reducesMotion) }
        }
    }

    /// The pill's content (capsule and hint) is placed beside the pointer; the panel reaches past it on every side by
    /// the pill's shadow padding. In AppKit global points.
    private func commandPillPanelFrame(forPanelSize commandPillPanelSize: CGSize, pointerPoint: CGPoint) -> CGRect {
        let shadowPadding = CommandPillView.shadowPadding
        let reportedContentSize = CGSize(width: commandPillPanelSize.width - shadowPadding * 2,
                                         height: commandPillPanelSize.height - shadowPadding * 2)
        let commandPillContentSize = reportedContentSize.width > 0 && reportedContentSize.height > 0
            ? reportedContentSize : Self.fallbackCommandPillSize
        let commandPillPlacement = commandPillPlacementCalculator.placement(
            forPillSize: commandPillContentSize, tipPoint: pointerPoint,
            preferredOffsetFromTip: commandPillOffsetFromPointer(),
            visibleFrame: ScreenGeometry.visibleFrameInTopLeftGlobalPoints(nearestToTopLeftGlobalPoint: pointerPoint),
            previousPlacement: latestCommandPillPlacement)
        latestCommandPillPlacement = commandPillPlacement
        return ScreenGeometry.appKitFrame(fromTopLeftGlobalFrame: commandPillPlacement.pillFrame.insetBy(dx: -shadowPadding, dy: -shadowPadding))
    }

    /// The capsule opens where the cursor's status pill will hang from the pointer once the command is submitted, so
    /// the capsule can turn into that pill without moving, clear of the cursor's reading ring.
    private func commandPillOffsetFromPointer() -> CGSize {
        let cursorScale = CGFloat(taskSessionController.cursorStyleConfiguration.cursorScale)
        let statusPillOffsetFromTip = CursorActivity.reading.pillOffsetFromTip
        return CommandPillHandoff.commandPillOffsetFromPointer(
            statusPillOffsetFromTip: CGSize(width: statusPillOffsetFromTip.width * cursorScale,
                                            height: statusPillOffsetFromTip.height * cursorScale),
            statusPillHeight: CursorPillView.estimatedSingleLineHeight * cursorScale,
            capsuleHeight: CommandPillView.capsuleHeight)
    }

    /// The panel is non-activating, so making it key gives the text field the keyboard without activating Dotto or
    /// taking the user's front window.
    private func presentKey(_ commandBarPanel: KeyablePanel) {
        commandBarPanel.makeKeyAndOrderFront(nil)
        commandBarPanel.orderFrontRegardless()
        commandBarPanel.invalidateShadow()
        requestCommandFieldFocusOnNextTurn()
        installClickOutsideMonitor()
        onVisibilityChanged?()
    }

    /// The caret has to be in the field as soon as the panel shows, with no click; the field's own onAppear request
    /// can come too early, so the focus is asked for again once the panel is key.
    private func requestCommandFieldFocusOnNextTurn() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let commandBarPanel = self.commandBarPanel, commandBarPanel.isVisible else { return }
                if !commandBarPanel.isKeyWindow { commandBarPanel.makeKey() }
                self.commandFieldFocusRequest.requestFocus()
            }
        }
    }

    /// The panel is non-activating, so it can take the keyboard back without activating Dotto.
    func makeCommandBarKeyIfVisible() {
        guard let commandBarPanel, commandBarPanel.isVisible else { return }
        commandBarPanel.makeKey()
    }

    func hideCommandBar() {
        let wasVisible = isVisible
        commandBarPanel?.orderOut(nil)
        commandPillPointerInTopLeftGlobalPoints = nil
        latestCommandPillPlacement = nil
        removeClickOutsideMonitor()
        let commandPillDismissHandler = onCommandPillDismissed
        onCommandPillDismissed = nil
        if wasVisible {
            commandPillDismissHandler?()
            onVisibilityChanged?()
        }
    }

    /// Submitting hides the panel too, but hands the keyboard back its own way, so the pill's dismiss handler must
    /// not also run. Submitted from the pill at the pointer, returns what the cursor's status pill needs to take the
    /// capsule's place. Screen updates wait for the next flush, so the pill's morph (or, under Reduce Motion, the
    /// status pill) appears in the same frame the panel goes.
    @discardableResult
    func hideCommandBarAfterSubmitting(submittedCommandText: String) -> SubmittedCommandPill? {
        var submittedCommandPill: SubmittedCommandPill?
        if let commandBarPanel, commandBarPanel.isVisible, commandPillPointerInTopLeftGlobalPoints != nil,
           let latestCommandPillPlacement {
            let commandPillContentFrame = latestCommandPillPlacement.pillFrame
            let capsuleFrame = CGRect(x: commandPillContentFrame.minX, y: commandPillContentFrame.minY,
                                      width: CommandPillView.pillWidth, height: CommandPillView.capsuleHeight)
            submittedCommandPill = SubmittedCommandPill(
                commandPillHandoff: CommandPillHandoff(capsuleFrame: capsuleFrame,
                                                       horizontalSide: latestCommandPillPlacement.horizontalSide,
                                                       verticalSide: latestCommandPillPlacement.verticalSide),
                commandPillContentFrame: commandPillContentFrame,
                submittedCommandText: submittedCommandText,
                morphsIntoStatusPill: !commandPillReducesMotion)
            commandBarPanel.disableScreenUpdatesUntilFlush()
        }
        onCommandPillDismissed = nil
        hideCommandBar()
        return submittedCommandPill
    }

    /// Morphs the submitted pill into the status pill at `statusPillFrame` (top-left global points), then calls
    /// `onMorphFinished`, which shows the real status pill, and takes the morph away in the same turn.
    func morphSubmittedCommandPill(_ submittedCommandPill: SubmittedCommandPill, intoStatusPillAt statusPillFrame: CGRect,
                                   cursorViewModel: CursorViewModel, onMorphFinished: @escaping () -> Void) {
        finishCommandPillMorph()
        let commandPillMorphPanel = self.commandPillMorphPanel ?? makeCommandPillMorphPanel()
        self.commandPillMorphPanel = commandPillMorphPanel
        let commandPillHandoff = submittedCommandPill.commandPillHandoff
        let cursorScale = CGFloat(cursorViewModel.styleConfiguration.cursorScale)
        // Room for the status pill at its largest too, in case its text grows while the morph runs.
        let largestStatusPillFrame = commandPillHandoff.statusPillFrame(
            forStatusPillSize: CGSize(width: CursorPillView.maximumPillSizeInPanel.width * cursorScale,
                                      height: CursorPillView.maximumPillSizeInPanel.height * cursorScale),
            heldStatusPillFrame: statusPillFrame)
        let morphCanvasFrame = CommandPillHandoff.morphCanvasFrame(
            commandPillContentFrame: submittedCommandPill.commandPillContentFrame,
            statusPillFrame: statusPillFrame.union(largestStatusPillFrame),
            shadowMargin: Self.commandPillMorphShadowMargin * max(1, cursorScale))
        let canvasOriginOffset = CGPoint(x: -morphCanvasFrame.minX, y: -morphCanvasFrame.minY)
        let commandPillMorphIdentifier = UUID()
        self.commandPillMorphIdentifier = commandPillMorphIdentifier
        onCommandPillMorphFinished = onMorphFinished

        let hostingView = NSHostingView(rootView: CommandPillMorphView(
            canvasSize: morphCanvasFrame.size,
            capsuleFrameInCanvas: commandPillHandoff.capsuleFrame.offsetBy(dx: canvasOriginOffset.x, dy: canvasOriginOffset.y),
            commandPillHandoffInCanvas: CommandPillHandoff(
                capsuleFrame: commandPillHandoff.capsuleFrame.offsetBy(dx: canvasOriginOffset.x, dy: canvasOriginOffset.y),
                horizontalSide: commandPillHandoff.horizontalSide, verticalSide: commandPillHandoff.verticalSide),
            heldStatusPillFrameInCanvas: statusPillFrame.offsetBy(dx: canvasOriginOffset.x, dy: canvasOriginOffset.y),
            submittedCommandText: submittedCommandPill.submittedCommandText,
            taskColor: taskSessionController.cursorStyleConfiguration.taskAccentColor,
            cursorViewModel: cursorViewModel,
            onMorphFinished: { [weak self] in self?.finishCommandPillMorph(identifiedBy: commandPillMorphIdentifier) }
        )).withClearBackground().sizedOnlyByItsPanel()
        commandPillMorphPanel.contentView = hostingView
        commandPillMorphPanelFrameApplier?.applyFrameNow(ScreenGeometry.appKitFrame(fromTopLeftGlobalFrame: morphCanvasFrame))
        hostingView.layoutSubtreeIfNeeded()
        commandPillMorphPanel.orderFrontRegardless()

        // In case the animation's completion never comes (its view torn down early), the status pill still shows.
        let handoffSeconds = CommandPillMorphView.timeline.handoffSeconds(
            capsuleMorphSettlingSeconds: DesignSystem.Motion.morphSpring.settlingDuration)
        DispatchQueue.main.asyncAfter(deadline: .now() + handoffSeconds + 0.3) { [weak self] in
            MainActor.assumeIsolated { self?.finishCommandPillMorph(identifiedBy: commandPillMorphIdentifier) }
        }
    }

    /// Ends the morph under way, if any: the status pill shows and the morph goes, in one frame. Called with no
    /// identifier to cut any morph short.
    private func finishCommandPillMorph(identifiedBy finishingMorphIdentifier: UUID? = nil) {
        guard let commandPillMorphIdentifier else { return }
        if let finishingMorphIdentifier, finishingMorphIdentifier != commandPillMorphIdentifier { return }
        self.commandPillMorphIdentifier = nil
        let onCommandPillMorphFinished = self.onCommandPillMorphFinished
        self.onCommandPillMorphFinished = nil
        commandPillMorphPanel?.disableScreenUpdatesUntilFlush()
        onCommandPillMorphFinished?()
        commandPillMorphPanel?.orderOut(nil)
        // The completion runs inside the morph view's own update, so its hosting view goes on a later turn.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.commandPillMorphIdentifier == nil else { return }
                self.commandPillMorphPanel?.contentView = nil
            }
        }
    }

    private func makeCommandPillMorphPanel() -> DottoPanel {
        let commandPillMorphPanel = DottoPanel(contentRect: NSRect(x: 0, y: 0, width: CommandPillView.pillWidth, height: 80))
        commandPillMorphPanel.ignoresMouseEvents = true
        commandPillMorphPanel.animationBehavior = .none
        commandPillMorphPanelFrameApplier = DeferredPanelFrameApplier(panel: commandPillMorphPanel)
        return commandPillMorphPanel
    }

    private func makeCommandBarPanel() -> KeyablePanel {
        let commandBarPanel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: commandBarWidth, height: 80))
        // The window server derives this shadow from the rounded card's alpha; a SwiftUI
        // shadow would be clipped at the panel's edges.
        commandBarPanel.hasShadow = true
        // Submitting hands it over to the morph or the status pill in one frame; a system fade would show both.
        commandBarPanel.animationBehavior = .none
        let commandBarPanelFrameApplier = DeferredPanelFrameApplier(panel: commandBarPanel)
        self.commandBarPanelFrameApplier = commandBarPanelFrameApplier
        // Content that changes size while shown (an attachment chip) keeps the bar's top-left corner in place, and
        // the pill beside its pointer and on screen, applied outside SwiftUI's update.
        commandContentSizeBox.onContentSizeChange = { [weak self] _ in
            self?.commandBarPanelFrameApplier?.scheduleFrameUpdate { [weak self] in
                guard let self, let commandBarPanel = self.commandBarPanel, commandBarPanel.isVisible else { return nil }
                let contentSize = self.commandContentSizeBox.latestContentSize
                if let commandPillPointerInTopLeftGlobalPoints = self.commandPillPointerInTopLeftGlobalPoints {
                    return self.commandPillPanelFrame(forPanelSize: contentSize, pointerPoint: commandPillPointerInTopLeftGlobalPoints)
                }
                return ScreenCorner.topLeft.frame(ofSize: contentSize, keepingCornerAt: ScreenCorner.topLeft.point(of: commandBarPanel.frame))
            }
        }
        commandBarPanelBecameKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: commandBarPanel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.requestCommandFieldFocusOnNextTurn() }
        }
        return commandBarPanel
    }

    private func installClickOutsideMonitor() {
        removeClickOutsideMonitor()
        // Global monitors only see clicks in other apps, which is exactly "outside".
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.hideCommandBar()
            }
        }
    }

    private func removeClickOutsideMonitor() {
        if let clickOutsideMonitor {
            NSEvent.removeMonitor(clickOutsideMonitor)
            self.clickOutsideMonitor = nil
        }
    }
}
