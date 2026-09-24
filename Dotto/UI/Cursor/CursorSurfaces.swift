import AppKit
import SwiftUI

/// A decision button was clicked: the option and the attention request its buttons were drawn for (nil when none).
typealias DecisionOptionHandler = (UserDecisionOptionIdentifier, _ attentionRequestIdentifier: String?) -> Void

/// Click-through, sized to the target window plus room for the pill and ordered just above it, so windows covering
/// the target also cover the cursor.
final class CursorOverlayWindow: DottoPanel {
    init() {
        super.init(contentRect: .zero, level: .normal)
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }
}

/// The places Dotto's cursor can appear, none of which ever takes focus:
/// - parked where the user summoned Dotto, while it plans, while the checklist waits for approval, and until the run
///   knows its window: a click-through panel above other windows, centered on that point;
/// - the overlay over the target window while it is visible;
/// - the live view, a floating, draggable panel that streams the covered target window with the cursor drawn at the
///   same window-relative point, and docks the decision pill to its edge when Dotto needs the user;
/// - the clickable panel the pill moves into, beside the parked or overlay cursor, when it carries buttons. It keeps
///   one size, enough for the largest pill, so the pill can resize inside it on a spring; only the pill takes clicks.
///
/// Every hosting view here is sized only by its panel (`sizedOnlyByItsPanel`); the pill and the live view report
/// their content size, and frames change outside SwiftUI's update (`DeferredPanelFrameApplier`).
@MainActor
final class CursorSurfaces {
    /// The overlay reaches past the target window so the pill and ring text beside a tip near an edge aren't clipped,
    /// on every side, because near an edge of the screen the pill flips to the left of or above the tip.
    private static let overlayOutsets = NSEdgeInsets(top: 120, left: 440, bottom: 120, right: 440)
    private static let pillPanelShadowPadding: CGFloat = 14
    /// Only if the pill hasn't reported its size yet, in the pill's own points.
    private static let fallbackPillSize = CGSize(width: 180, height: CursorPillView.estimatedSingleLineHeight)
    private static let screenEdgeInset: CGFloat = 16
    /// Around the tip, the room the largest ring and its text take (the reading ring's text runs up to 38 points out).
    private static let cursorRingClearance: CGFloat = 40
    /// Used for the keep-clear frame while the pill isn't in its own panel.
    private static let estimatedPillSize = CGSize(width: 180, height: 28)

    private let viewModel: CursorViewModel
    private let onDecisionOptionChosen: DecisionOptionHandler
    private let onToggleLiveViewCollapsed: () -> Void
    private let onToggleChecklist: () -> Void
    private lazy var overlayWindow = makeOverlayWindow()
    private lazy var parkedCursorWindow = makeParkedCursorWindow()
    private lazy var pillPanel = makePillPanel()
    private lazy var pillPanelFrameApplier = DeferredPanelFrameApplier(panel: pillPanel)
    /// Reports the pill's own size, before the cursor's scale and without the panel's shadow padding.
    private let pillContentSizeBox = PanelContentSizeBox()
    private var pillHostingView: PillPanelHostingView?
    private let pillPlacementCalculator = PillPlacementCalculator()
    /// Keeps the pill on the side it flipped to while it still fits there, so it doesn't jump as its text changes.
    private var latestPillPanelPlacement: PillPlacement?
    private lazy var liveViewPanel = makeLiveViewPanel()
    private lazy var liveViewPanelFrameApplier = DeferredPanelFrameApplier(panel: liveViewPanel)
    private let liveViewContentSizeBox = PanelContentSizeBox()
    private var liveViewHostingView: NSHostingView<AnyView>?
    private var shownSurface: CursorSurface = .hidden
    private var shownTargetWindow: TargetWindowReference?
    private var parkedTipInTopLeftGlobalPoints: CGPoint?
    /// The live view's corner point that stays put while its height changes: the default corner, or wherever the
    /// user dragged it this session (in AppKit global points).
    private var liveViewPanelUserAnchor: CGPoint?
    /// The last frame Dotto gave the live view; a move to any other frame is the user dragging it.
    private var liveViewPanelFrameSetByThisApp: CGRect?
    private var liveViewPanelMoveObserver: NSObjectProtocol?
    /// The command pill's capsule the parked pill took the place of, when the task was submitted from the pill at the
    /// pointer: while the cursor stays parked, its pill keeps the capsule's tip-facing edge and vertical center.
    private(set) var parkedPillCommandPillHandoff: CommandPillHandoff?
    /// While the command pill morphs into the status pill, the pill panel is placed but not shown; the morph ends by
    /// showing it (`finishCommandPillHandoff`), so the two never show at once.
    private var holdsPillPanelForCommandPillHandoff = false
    /// Set only while the pill panel is shown in the morph's place: it appears at once instead of fading in.
    private var pillPanelTakesOverFromMorph = false

    init(viewModel: CursorViewModel, onDecisionOptionChosen: @escaping DecisionOptionHandler,
         onToggleLiveViewCollapsed: @escaping () -> Void, onToggleChecklist: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onDecisionOptionChosen = onDecisionOptionChosen
        self.onToggleLiveViewCollapsed = onToggleLiveViewCollapsed
        self.onToggleChecklist = onToggleChecklist
    }

    private var liveViewCorner: ScreenCorner { viewModel.liveViewCorner }
    private var cursorScale: CGFloat { CGFloat(viewModel.styleConfiguration.cursorScale) }

    func liveViewCornerDidChange() {
        liveViewPanelUserAnchor = nil
        layoutLiveViewPanel()
    }

    // MARK: - Switching

    /// Set before the parked cursor first shows; `holdsPillPanel` keeps the pill panel out until the morph finishes.
    func beginCommandPillHandoff(_ commandPillHandoff: CommandPillHandoff?, holdsPillPanel: Bool) {
        parkedPillCommandPillHandoff = commandPillHandoff
        holdsPillPanelForCommandPillHandoff = commandPillHandoff != nil && holdsPillPanel
        latestPillPanelPlacement = nil
    }

    /// The pill's own frame (without the panel's shadow padding) while the pill panel is held for the handoff, in
    /// top-left global points; nil when nothing is held or the pill isn't placed.
    var heldPillFrameForCommandPillHandoff: CGRect? {
        guard holdsPillPanelForCommandPillHandoff, viewModel.pillIsClickable else { return nil }
        return latestPillPanelPlacement?.pillFrame
    }

    /// The morph's last frame is drawn exactly as the pill is, so the pill shows in its place with its animations
    /// off for that first update, and the swap can't be seen.
    func finishCommandPillHandoff(targetWindow: TargetWindowReference?) {
        guard holdsPillPanelForCommandPillHandoff else { return }
        holdsPillPanelForCommandPillHandoff = false
        viewModel.pillAnimationsAreSuppressed = true
        pillHostingView?.layoutSubtreeIfNeeded()
        pillPanelTakesOverFromMorph = true
        refreshPillPanel(targetWindow: targetWindow)
        pillPanelTakesOverFromMorph = false
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.viewModel.pillAnimationsAreSuppressed = false }
        }
    }

    func show(_ surface: CursorSurface, targetWindow: TargetWindowReference?, parkedTipInTopLeftGlobalPoints: CGPoint?,
              reducesMotion: Bool) {
        let surfaceChanged = surface != shownSurface
        if surface != .parkedAtSummonOrigin {
            // Away from the summon point the pill hangs from the tip the usual way, and nothing is held back.
            parkedPillCommandPillHandoff = nil
            holdsPillPanelForCommandPillHandoff = false
        }
        shownSurface = surface
        shownTargetWindow = targetWindow
        self.parkedTipInTopLeftGlobalPoints = parkedTipInTopLeftGlobalPoints
        switch surface {
        case .parkedAtSummonOrigin:
            guard let parkedTipInTopLeftGlobalPoints else { return }
            positionParkedCursorWindow(atTopLeftGlobalPoint: parkedTipInTopLeftGlobalPoints)
            // Summoned from the command pill, the cursor arrives together with the pill's morph, over the same time.
            fadeIn(parkedCursorWindow, reducesMotion: reducesMotion,
                   durationSeconds: holdsPillPanelForCommandPillHandoff
                       ? CommandPillMorphTimeline.standard.incomingContentFadeEndSeconds
                       : DesignSystem.Motion.windowFadeInDurationSeconds)
            if surfaceChanged {
                fadeOut(overlayWindow, reducesMotion: reducesMotion)
                fadeOut(liveViewPanel, reducesMotion: reducesMotion)
            }
        case .overlayOnTargetWindow:
            guard let targetWindow else { return }
            positionOverlayWindow(over: targetWindow)
            fadeIn(overlayWindow, reducesMotion: reducesMotion)
            overlayWindow.order(.above, relativeTo: Int(targetWindow.windowIdentifier))
            if surfaceChanged {
                fadeOut(liveViewPanel, reducesMotion: reducesMotion)
                fadeOut(parkedCursorWindow, reducesMotion: reducesMotion)
            }
        case .liveViewPanel:
            if surfaceChanged {
                fadeOut(overlayWindow, reducesMotion: reducesMotion)
                fadeOut(parkedCursorWindow, reducesMotion: reducesMotion)
                layoutLiveViewPanel()
            }
            fadeIn(liveViewPanel, reducesMotion: reducesMotion)
            liveViewPanel.orderFrontRegardless()
        case .hidden:
            fadeOut(overlayWindow, reducesMotion: true)
            fadeOut(parkedCursorWindow, reducesMotion: true)
            fadeOut(liveViewPanel, reducesMotion: true)
        }
        refreshPillPanel(targetWindow: targetWindow)
    }

    /// A pill with buttons (Stop while planning or running, answers while Dotto waits for the user) can't be drawn by
    /// the overlay, which can't take clicks without blocking the target app, so it is drawn by its own clickable
    /// panel at the same spot. While the cursor flies only the panel's origin changes.
    func refreshPillPanel(targetWindow: TargetWindowReference?) {
        guard viewModel.pillIsClickable, let tipInAppKitPoints = cursorTipInAppKitPoints(targetWindow: targetWindow) else {
            pillPanelFrameApplier.cancelPendingFrameUpdate()
            latestPillPanelPlacement = nil
            if pillPanel.isVisible { pillPanel.orderOut(nil) }
            return
        }
        pillPanelFrameApplier.applyFrameNow(pillPanelFrame(forTipInAppKitPoints: tipInAppKitPoints,
                                                           pillSize: measuredPillSize()))
        // Parked, the cursor floats above the user's windows, and so does its pill; over the target window both sit
        // just above that window.
        let pillPanelLevel: NSWindow.Level = shownSurface == .parkedAtSummonOrigin ? .floating : .normal
        if pillPanel.level != pillPanelLevel { pillPanel.level = pillPanelLevel }
        guard !holdsPillPanelForCommandPillHandoff else { return }
        if !pillPanel.isVisible {
            if pillPanelTakesOverFromMorph {
                pillPanel.alphaValue = 1
                pillPanel.orderFrontRegardless()
            } else {
                fadeIn(pillPanel, reducesMotion: viewModel.styleConfiguration.reducesMotion(
                    systemReduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion))
            }
        }
        let windowBelowPill = shownSurface == .parkedAtSummonOrigin ? parkedCursorWindow : overlayWindow
        pillPanel.order(.above, relativeTo: windowBelowPill.windowNumber)
    }

    /// What the checklist popover hangs from: the cursor's tip, keeping its ring and pill uncovered, or the live view.
    func anchorForAttachedPanels(targetWindow: TargetWindowReference?) -> AttachedPanelAnchor? {
        switch shownSurface {
        case .parkedAtSummonOrigin, .overlayOnTargetWindow:
            guard let tipInAppKitPoints = cursorTipInAppKitPoints(targetWindow: targetWindow) else { return nil }
            let tipPoint = ScreenGeometry.topLeftGlobalPoint(fromAppKitPoint: tipInAppKitPoints)
            let ringClearance = Self.cursorRingClearance * cursorScale
            var keepClearFrame = CGRect(x: tipPoint.x - ringClearance, y: tipPoint.y - ringClearance,
                                        width: ringClearance * 2, height: ringClearance * 2)
            if pillPanel.isVisible, let placedPillFrame = latestPillPanelPlacement?.pillFrame {
                keepClearFrame = keepClearFrame.union(placedPillFrame)
            } else {
                let pillOffsetFromTip = viewModel.appearance.activity.pillOffsetFromTip
                keepClearFrame = keepClearFrame.union(CGRect(
                    x: tipPoint.x + pillOffsetFromTip.width * cursorScale, y: tipPoint.y + pillOffsetFromTip.height * cursorScale,
                    width: Self.estimatedPillSize.width * cursorScale, height: Self.estimatedPillSize.height * cursorScale))
            }
            return .besideCursor(anchorPoint: tipPoint, keepClearFrame: keepClearFrame)
        case .liveViewPanel:
            guard liveViewPanel.isVisible else { return nil }
            let liveViewCardFrame = liveViewPanel.frame.insetBy(dx: LiveViewPanelView.shadowPadding, dy: LiveViewPanelView.shadowPadding)
            return .besidePanel(panelFrame: ScreenGeometry.topLeftGlobalFrame(fromAppKitFrame: liveViewCardFrame))
        case .hidden:
            return nil
        }
    }

    private func cursorTipInAppKitPoints(targetWindow: TargetWindowReference?) -> CGPoint? {
        switch shownSurface {
        case .parkedAtSummonOrigin:
            return parkedTipInTopLeftGlobalPoints.map(ScreenGeometry.appKitPoint(fromTopLeftGlobalPoint:))
        case .overlayOnTargetWindow:
            guard let targetWindow else { return nil }
            let windowFrameInAppKitPoints = ScreenGeometry.appKitFrame(fromTopLeftGlobalFrame: targetWindow.frameInTopLeftGlobalPoints)
            return CGPoint(x: windowFrameInAppKitPoints.minX + viewModel.cursorPointInWindow.x,
                           y: windowFrameInAppKitPoints.maxY - viewModel.cursorPointInWindow.y)
        case .liveViewPanel, .hidden:
            return nil
        }
    }

    // MARK: - Overlay

    private func makeOverlayWindow() -> CursorOverlayWindow {
        let overlayWindow = CursorOverlayWindow()
        overlayWindow.contentView = NSHostingView(rootView: CursorOverlayContentView(
            viewModel: viewModel,
            targetWindowOriginInOverlay: CGPoint(x: Self.overlayOutsets.left, y: Self.overlayOutsets.top),
            drawsCursorAtTargetWindowOrigin: false,
            drawnSurface: .overlayOnTargetWindow
        )).withClearBackground().sizedOnlyByItsPanel()
        return overlayWindow
    }

    private func positionOverlayWindow(over targetWindow: TargetWindowReference) {
        let windowFrameInAppKitPoints = ScreenGeometry.appKitFrame(fromTopLeftGlobalFrame: targetWindow.frameInTopLeftGlobalPoints)
        let overlayFrame = NSRect(
            x: windowFrameInAppKitPoints.minX - Self.overlayOutsets.left,
            y: windowFrameInAppKitPoints.minY - Self.overlayOutsets.bottom,
            width: windowFrameInAppKitPoints.width + Self.overlayOutsets.left + Self.overlayOutsets.right,
            height: windowFrameInAppKitPoints.height + Self.overlayOutsets.top + Self.overlayOutsets.bottom)
        if !overlayWindow.frame.isNearlyEqual(to: overlayFrame) {
            overlayWindow.setFrame(overlayFrame, display: true)
        }
        publishPillPlacementReferences(targetWindowOriginInTopLeftGlobalPoints: targetWindow.frameInTopLeftGlobalPoints.origin)
    }

    // MARK: - Parked cursor

    /// The same click-through overlay content, laid out around a single point instead of a window, floating above
    /// the user's windows because the user just summoned Dotto there.
    private func makeParkedCursorWindow() -> CursorOverlayWindow {
        let parkedCursorWindow = CursorOverlayWindow()
        parkedCursorWindow.level = .floating
        parkedCursorWindow.contentView = NSHostingView(rootView: CursorOverlayContentView(
            viewModel: viewModel,
            targetWindowOriginInOverlay: CGPoint(x: Self.overlayOutsets.left, y: Self.overlayOutsets.top),
            drawsCursorAtTargetWindowOrigin: true,
            drawnSurface: .parkedAtSummonOrigin
        )).withClearBackground().sizedOnlyByItsPanel()
        return parkedCursorWindow
    }

    private func positionParkedCursorWindow(atTopLeftGlobalPoint tipPoint: CGPoint) {
        let tipInAppKitPoints = ScreenGeometry.appKitPoint(fromTopLeftGlobalPoint: tipPoint)
        let parkedFrame = NSRect(
            x: tipInAppKitPoints.x - Self.overlayOutsets.left,
            y: tipInAppKitPoints.y - Self.overlayOutsets.bottom,
            width: Self.overlayOutsets.left + Self.overlayOutsets.right,
            height: Self.overlayOutsets.top + Self.overlayOutsets.bottom)
        if !parkedCursorWindow.frame.isNearlyEqual(to: parkedFrame) {
            parkedCursorWindow.setFrame(parkedFrame, display: true)
        }
        publishPillPlacementReferences(parkedTipInTopLeftGlobalPoints: tipPoint)
    }

    /// What the click-through pill drawn in the overlay and the parked window needs to stay on screen. Assigned only
    /// when changed, so a cursor that keeps still doesn't redraw its views.
    private func publishPillPlacementReferences(targetWindowOriginInTopLeftGlobalPoints: CGPoint? = nil,
                                                parkedTipInTopLeftGlobalPoints: CGPoint? = nil) {
        let screenVisibleFrames = ScreenGeometry.visibleFramesInTopLeftGlobalPoints
        if viewModel.screenVisibleFramesInTopLeftGlobalPoints != screenVisibleFrames {
            viewModel.screenVisibleFramesInTopLeftGlobalPoints = screenVisibleFrames
        }
        if let targetWindowOriginInTopLeftGlobalPoints,
           viewModel.targetWindowOriginInTopLeftGlobalPoints != targetWindowOriginInTopLeftGlobalPoints {
            viewModel.targetWindowOriginInTopLeftGlobalPoints = targetWindowOriginInTopLeftGlobalPoints
        }
        if let parkedTipInTopLeftGlobalPoints, viewModel.parkedTipInTopLeftGlobalPoints != parkedTipInTopLeftGlobalPoints {
            viewModel.parkedTipInTopLeftGlobalPoints = parkedTipInTopLeftGlobalPoints
        }
    }

    // MARK: - Pill panel

    private func makePillPanel() -> NonActivatingClickablePanel {
        let pillPanel = NonActivatingClickablePanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 44), level: .normal)
        // It takes over from the command pill's morph in one frame; a system fade would show both at once.
        pillPanel.animationBehavior = .none
        let hostingView = PillPanelHostingView(rootView: AnyView(PillPanelContentView(
            viewModel: viewModel, onDecisionOptionChosen: onDecisionOptionChosen, onToggleChecklist: onToggleChecklist,
            pillContentSizeBox: pillContentSizeBox, shadowPadding: pillPanelLayout.shadowPadding
        ))).withClearBackground().sizedOnlyByItsPanel()
        // The panel is larger than the pill: the window server already passes clicks on its transparent pixels to the
        // window behind, and the rest (the shadow's faint pixels) reaches no view, so only the pill takes clicks.
        hostingView.clickableFrameInPanel = { [weak self] in self?.pillFrameInPanel() }
        pillPanel.contentView = hostingView
        pillHostingView = hostingView
        // The pill's text or buttons changed its size: it resizes inside the fixed panel on its own spring, and the
        // panel only moves if the pill's corner did (a flip, or a pill centered on the command pill's capsule), on a
        // later turn of the run loop, never from inside SwiftUI's update.
        pillContentSizeBox.onContentSizeChange = { [weak self] _ in
            guard let self else { return }
            self.pillPanelFrameApplier.scheduleFrameUpdate { [weak self] in
                guard let self, self.viewModel.pillIsClickable,
                      let tipInAppKitPoints = self.cursorTipInAppKitPoints(targetWindow: self.shownTargetWindow) else { return nil }
                return self.pillPanelFrame(forTipInAppKitPoints: tipInAppKitPoints, pillSize: self.measuredPillSize())
            }
        }
        return pillPanel
    }

    /// The pill's largest size on screen, and room for its shadow (which the cursor's scale enlarges too).
    private var pillPanelLayout: PillPanelLayout {
        PillPanelLayout(maximumPillSize: CGSize(width: CursorPillView.maximumPillSizeInPanel.width * cursorScale,
                                                height: CursorPillView.maximumPillSizeInPanel.height * cursorScale),
                        shadowPadding: Self.pillPanelShadowPadding * max(1, cursorScale))
    }

    /// As drawn on screen, after the cursor's scale.
    private func measuredPillSize() -> CGSize {
        let reportedSize = pillHostingView?.laidOutContentSize(reportedTo: pillContentSizeBox) ?? .zero
        let pillSize = reportedSize.width > 0 && reportedSize.height > 0 ? reportedSize : Self.fallbackPillSize
        return CGSize(width: pillSize.width * cursorScale, height: pillSize.height * cursorScale)
    }

    /// Where the pill is drawn in its panel, in the panel's top-left points; nil while it isn't placed.
    private func pillFrameInPanel() -> CGRect? {
        guard let latestPillPanelPlacement else { return nil }
        return pillPanelLayout.pillFrameInPanel(pillSize: latestPillPanelPlacement.pillFrame.size,
                                                horizontalSide: latestPillPanelPlacement.horizontalSide,
                                                verticalSide: latestPillPanelPlacement.verticalSide,
                                                panelSize: pillPanel.frame.size)
    }

    /// Beside the tip, flipped left of or above it near an edge of the tip's screen, recomputed on every cursor move
    /// and every change of the pill's size. The panel's frame follows the pill's tip-facing corner only.
    private func pillPanelFrame(forTipInAppKitPoints tipInAppKitPoints: CGPoint, pillSize visiblePillSize: CGSize) -> CGRect {
        let tipPoint = ScreenGeometry.topLeftGlobalPoint(fromAppKitPoint: tipInAppKitPoints)
        let pillOffsetFromTip = viewModel.appearance.activity.pillOffsetFromTip
        var preferredOffsetFromTip = CGSize(width: pillOffsetFromTip.width * cursorScale, height: pillOffsetFromTip.height * cursorScale)
        var previousPlacement = latestPillPanelPlacement
        if shownSurface == .parkedAtSummonOrigin, let parkedPillCommandPillHandoff {
            preferredOffsetFromTip = parkedPillCommandPillHandoff.preferredOffsetFromTip(forStatusPillSize: visiblePillSize, tipPoint: tipPoint)
            previousPlacement = previousPlacement ?? parkedPillCommandPillHandoff.sidesPlacement
        }
        let pillPlacement = pillPlacementCalculator.placement(
            forPillSize: visiblePillSize, tipPoint: tipPoint, preferredOffsetFromTip: preferredOffsetFromTip,
            visibleFrame: ScreenGeometry.visibleFrameInTopLeftGlobalPoints(nearestToTopLeftGlobalPoint: tipPoint),
            previousPlacement: previousPlacement)
        latestPillPanelPlacement = pillPlacement
        publishPillCornerInPanel(horizontalSide: pillPlacement.horizontalSide, verticalSide: pillPlacement.verticalSide)
        return ScreenGeometry.appKitFrame(fromTopLeftGlobalFrame: pillPanelLayout.panelFrame(for: pillPlacement))
    }

    /// A flip moves the pill to another corner of its panel in the same frame the panel moves, with no animation, so
    /// the pill stays put on screen.
    private func publishPillCornerInPanel(horizontalSide: PillHorizontalSide, verticalSide: PillVerticalSide) {
        guard viewModel.pillPanelHorizontalSide != horizontalSide || viewModel.pillPanelVerticalSide != verticalSide else { return }
        var cornerChangeTransaction = Transaction()
        cornerChangeTransaction.disablesAnimations = true
        withTransaction(cornerChangeTransaction) {
            viewModel.pillPanelHorizontalSide = horizontalSide
            viewModel.pillPanelVerticalSide = verticalSide
        }
        pillHostingView?.layoutSubtreeIfNeeded()
    }

    // MARK: - Live view

    private func makeLiveViewPanel() -> NonActivatingClickablePanel {
        let liveViewPanel = NonActivatingClickablePanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 240))
        liveViewPanel.isMovableByWindowBackground = true
        let hostingView = FirstMouseHostingView(rootView: AnyView(LiveViewPanelView(
            viewModel: viewModel,
            onToggleCollapsed: onToggleLiveViewCollapsed,
            onToggleChecklist: onToggleChecklist,
            onDecisionOptionChosen: onDecisionOptionChosen,
            contentSizeBox: liveViewContentSizeBox
        ))).withClearBackground().sizedOnlyByItsPanel()
        liveViewPanel.contentView = hostingView
        liveViewHostingView = hostingView
        // Collapsing, expanding and the docked decision pill change the content's size inside SwiftUI's update; the
        // panel follows on a later turn of the run loop.
        liveViewContentSizeBox.onContentSizeChange = { [weak self] _ in
            guard let self else { return }
            self.liveViewPanelFrameApplier.scheduleFrameUpdate { [weak self] in
                self?.liveViewPanelFrame(forPanelSize: self?.liveViewContentSizeBox.latestContentSize ?? .zero)
            }
        }
        liveViewPanelMoveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: liveViewPanel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rememberUserMovedLiveViewPanel() }
        }
        return liveViewPanel
    }

    /// Keeps the panel's corner (the chosen screen corner, or where the user dragged it) fixed while its height
    /// follows the content.
    private func layoutLiveViewPanel() {
        let panelSize = liveViewHostingView?.laidOutContentSize(reportedTo: liveViewContentSizeBox) ?? .zero
        guard let panelFrame = liveViewPanelFrame(forPanelSize: panelSize) else { return }
        liveViewPanelFrameApplier.cancelPendingFrameUpdate()
        liveViewPanelFrameApplier.applyFrameNow(panelFrame)
    }

    private func liveViewPanelFrame(forPanelSize panelSize: CGSize) -> CGRect? {
        guard panelSize.width > 0, panelSize.height > 0 else { return nil }
        let anchorPoint = liveViewPanelUserAnchor ?? defaultLiveViewAnchorPoint()
        let anchoredPanelFrame = liveViewCorner.frame(ofSize: panelSize, keepingCornerAt: anchorPoint)
        // Dragged near an edge, the panel would grow off screen when the decision pill docks to it; its card is moved
        // back inside the visible frame of the anchor's screen, and returns to the anchor once the pill is gone.
        let shadowPadding = LiveViewPanelView.shadowPadding
        let cardFrame = ScreenGeometry.topLeftGlobalFrame(fromAppKitFrame: anchoredPanelFrame.insetBy(dx: shadowPadding, dy: shadowPadding))
        let visibleFrame = ScreenGeometry.visibleFrameInTopLeftGlobalPoints(
            nearestToTopLeftGlobalPoint: ScreenGeometry.topLeftGlobalPoint(fromAppKitPoint: anchorPoint))
        let cardFrameOnScreen = pillPlacementCalculator.frameKeptInside(visibleFrame: visibleFrame, frame: cardFrame)
        let panelFrame = ScreenGeometry.appKitFrame(fromTopLeftGlobalFrame: cardFrameOnScreen)
            .insetBy(dx: -shadowPadding, dy: -shadowPadding)
        liveViewPanelFrameSetByThisApp = panelFrame
        return panelFrame
    }

    private func defaultLiveViewAnchorPoint() -> CGPoint {
        // The panel's content carries its own shadow padding, so the card itself lands 16 points from the edges.
        let inset = Self.screenEdgeInset - LiveViewPanelView.shadowPadding
        let insetVisibleFrame = ScreenGeometry.visibleFrame(of: ScreenGeometry.screenUnderMouse).insetBy(dx: inset, dy: inset)
        return liveViewCorner.point(of: insetVisibleFrame)
    }

    private func rememberUserMovedLiveViewPanel() {
        guard liveViewPanel.isVisible else { return }
        if let liveViewPanelFrameSetByThisApp, liveViewPanel.frame.isNearlyEqual(to: liveViewPanelFrameSetByThisApp) { return }
        liveViewPanelUserAnchor = liveViewCorner.point(of: liveViewPanel.frame)
    }

    // MARK: - Fading

    private func fadeIn(_ window: NSWindow, reducesMotion: Bool,
                        durationSeconds: Double = DesignSystem.Motion.windowFadeInDurationSeconds) {
        guard !window.isVisible || window.alphaValue < 1 else { return }
        if !window.isVisible {
            window.alphaValue = reducesMotion ? 1 : 0
            window.orderFrontRegardless()
        }
        guard !reducesMotion else {
            window.alphaValue = 1
            return
        }
        NSAnimationContext.runAnimationGroup { animationContext in
            animationContext.duration = durationSeconds
            animationContext.timingFunction = DesignSystem.Motion.windowFadeTimingFunction
            window.animator().alphaValue = 1
        }
    }

    private func fadeOut(_ window: NSWindow, reducesMotion: Bool) {
        guard window.isVisible else { return }
        guard !reducesMotion else {
            window.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ animationContext in
            animationContext.duration = DesignSystem.Motion.disappearDurationSeconds
            animationContext.timingFunction = DesignSystem.Motion.windowFadeTimingFunction
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self, weak window] in
            MainActor.assumeIsolated {
                guard let self, let window else { return }
                // A surface that was brought back during the fade stays up.
                let windowIsWanted = (window === self.overlayWindow && self.shownSurface == .overlayOnTargetWindow)
                    || (window === self.parkedCursorWindow && self.shownSurface == .parkedAtSummonOrigin)
                    || (window === self.liveViewPanel && self.shownSurface == .liveViewPanel)
                if !windowIsWanted { window.orderOut(nil) }
            }
        })
    }
}

// MARK: - Pill panel content

/// The clickable pill in its fixed panel, drawn in the corner that faces the cursor's tip so that corner stays put
/// while the pill resizes.
private struct PillPanelContentView: View {
    @ObservedObject var viewModel: CursorViewModel
    let onDecisionOptionChosen: DecisionOptionHandler
    let onToggleChecklist: () -> Void
    let pillContentSizeBox: PanelContentSizeBox
    let shadowPadding: CGFloat

    var body: some View {
        let pillAlignment = Alignment(
            horizontal: viewModel.pillPanelHorizontalSide == .rightOfTip ? .leading : .trailing,
            vertical: viewModel.pillPanelVerticalSide == .belowTip ? .top : .bottom)
        let pillScaleAnchor = UnitPoint(x: viewModel.pillPanelHorizontalSide == .rightOfTip ? 0 : 1,
                                        y: viewModel.pillPanelVerticalSide == .belowTip ? 0 : 1)
        DecisionPill(viewModel: viewModel, onDecisionOptionChosen: onDecisionOptionChosen, onToggleChecklist: onToggleChecklist,
                     scaleAnchor: pillScaleAnchor)
            .fixedSize()
            .reportingPanelContentSize(to: pillContentSizeBox)
            .padding(shadowPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: pillAlignment)
            .transaction { pillTransaction in
                if viewModel.pillAnimationsAreSuppressed {
                    pillTransaction.disablesAnimations = true
                    pillTransaction.animation = nil
                }
            }
    }
}

/// Takes the first click like `FirstMouseHostingView`, and only where the pill is: the rest of the panel reaches no
/// view.
final class PillPanelHostingView: NSHostingView<AnyView> {
    /// In the panel's top-left points (y grows downward).
    var clickableFrameInPanel: (() -> CGRect?)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ pointInSuperview: NSPoint) -> NSView? {
        guard let clickableFrame = clickableFrameInPanel?() else { return nil }
        let pointInThisView = convert(pointInSuperview, from: superview)
        let pointFromTopLeft = CGPoint(x: pointInThisView.x, y: isFlipped ? pointInThisView.y : bounds.height - pointInThisView.y)
        guard clickableFrame.contains(pointFromTopLeft) else { return nil }
        return super.hitTest(pointInSuperview)
    }
}

// MARK: - Overlay content

private struct CursorOverlayContentView: View {
    @ObservedObject var viewModel: CursorViewModel
    let targetWindowOriginInOverlay: CGPoint
    /// The parked cursor always sits at the point it is parked on, whatever the window-relative point is.
    let drawsCursorAtTargetWindowOrigin: Bool
    /// Which surface this window is; its cursor animates only while that surface is the one shown.
    let drawnSurface: CursorSurface

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    var body: some View {
        let styleConfiguration = viewModel.styleConfiguration
        let showsReplayTrail = viewModel.appearance.activity == .replaying
            && !styleConfiguration.reducesMotion(systemReduceMotion: systemReduceMotion)
        let cursorScale = CGFloat(styleConfiguration.cursorScale)
        ZStack(alignment: .topLeading) {
            Color.clear
            if showsReplayTrail {
                ForEach(Array(viewModel.replayTrailPointsInWindow.enumerated()), id: \.offset) { trailIndex, trailPoint in
                    CursorGhostArrow(color: styleConfiguration.taskAccentColor, opacity: 0.3 - Double(trailIndex) * 0.09)
                        .scaleEffect(cursorScale, anchor: .topLeading)
                        .offset(x: targetWindowOriginInOverlay.x + trailPoint.x, y: targetWindowOriginInOverlay.y + trailPoint.y)
                }
            }
            let cursorPointInOverlayWindow = drawsCursorAtTargetWindowOrigin ? .zero : viewModel.cursorPointInWindow
            CursorView(appearance: overlayPillAppearance, configuration: styleConfiguration,
                            showsPill: !viewModel.pillIsClickable,
                            pillRoomAroundTip: pillRoomAroundTip(cursorPointInOverlayWindow: cursorPointInOverlayWindow,
                                                                 cursorScale: cursorScale),
                            isOnShownSurface: viewModel.surface == drawnSurface)
                .offset(x: targetWindowOriginInOverlay.x + cursorPointInOverlayWindow.x,
                        y: targetWindowOriginInOverlay.y + cursorPointInOverlayWindow.y)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
    }

    /// The visible frame of the tip's screen in the cursor view's own points (the tip at the origin, before its scale).
    private func pillRoomAroundTip(cursorPointInOverlayWindow: CGPoint, cursorScale: CGFloat) -> CGRect? {
        let tipInTopLeftGlobalPoints = drawsCursorAtTargetWindowOrigin
            ? viewModel.parkedTipInTopLeftGlobalPoints
            : CGPoint(x: viewModel.targetWindowOriginInTopLeftGlobalPoints.x + cursorPointInOverlayWindow.x,
                      y: viewModel.targetWindowOriginInTopLeftGlobalPoints.y + cursorPointInOverlayWindow.y)
        guard cursorScale > 0, let visibleFrame = PillPlacementCalculator.visibleFrame(
            nearestTo: tipInTopLeftGlobalPoints, amongVisibleFrames: viewModel.screenVisibleFramesInTopLeftGlobalPoints) else { return nil }
        return CGRect(x: (visibleFrame.minX - tipInTopLeftGlobalPoints.x) / cursorScale,
                      y: (visibleFrame.minY - tipInTopLeftGlobalPoints.y) / cursorScale,
                      width: visibleFrame.width / cursorScale, height: visibleFrame.height / cursorScale)
    }

    /// The overlay's pill never draws buttons: nothing in the overlay can be clicked.
    private var overlayPillAppearance: CursorAppearance {
        var overlayPillAppearance = viewModel.appearance
        overlayPillAppearance.offersStop = false
        overlayPillAppearance.offersPause = false
        overlayPillAppearance.offersChecklistToggle = false
        return overlayPillAppearance
    }
}
