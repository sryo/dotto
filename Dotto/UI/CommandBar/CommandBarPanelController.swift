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
    /// The pill opens just below and right of the pointer, like the lab's.
    private static let commandPillOffsetFromPointer: CGFloat = 14
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

    init(taskSessionController: TaskSessionController) {
        self.taskSessionController = taskSessionController
    }

    var isVisible: Bool {
        commandBarPanel?.isVisible ?? false
    }

    func showCommandBar(prefilledCommandText: String) {
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
        let commandBarPanel = self.commandBarPanel ?? makeCommandBarPanel()
        self.commandBarPanel = commandBarPanel

        let hostingView = NSHostingView(rootView: AnyView(CommandPillView(
            taskSessionController: taskSessionController,
            commandFieldFocusRequest: commandFieldFocusRequest,
            reducesMotion: reducesMotion,
            onDismiss: { [weak self] in self?.hideCommandBar() }
        ).drawsControlsAsActive().fixedSize().reportingPanelContentSize(to: commandContentSizeBox)))
            .withClearBackground().sizedOnlyByItsPanel()
        commandBarPanel.contentView = hostingView

        let reportedCommandPillSize = hostingView.laidOutContentSize(reportedTo: commandContentSizeBox)
        let commandPillSize = reportedCommandPillSize.width > 0 && reportedCommandPillSize.height > 0
            ? reportedCommandPillSize : Self.fallbackCommandPillSize
        commandPillPointerInTopLeftGlobalPoints = topLeftGlobalPoint
        latestCommandPillPlacement = nil
        commandBarPanelFrameApplier?.applyFrameNow(commandPillFrame(forPillSize: commandPillSize, pointerPoint: topLeftGlobalPoint))

        onCommandPillDismissed = onDismiss
        presentKey(commandBarPanel)
    }

    /// In AppKit global points.
    private func commandPillFrame(forPillSize commandPillSize: CGSize, pointerPoint: CGPoint) -> CGRect {
        let commandPillPlacement = commandPillPlacementCalculator.placement(
            forPillSize: commandPillSize, tipPoint: pointerPoint,
            preferredOffsetFromTip: CGSize(width: Self.commandPillOffsetFromPointer, height: Self.commandPillOffsetFromPointer),
            visibleFrame: ScreenGeometry.visibleFrameInTopLeftGlobalPoints(nearestToTopLeftGlobalPoint: pointerPoint),
            previousPlacement: latestCommandPillPlacement)
        latestCommandPillPlacement = commandPillPlacement
        return ScreenGeometry.appKitFrame(fromTopLeftGlobalFrame: commandPillPlacement.pillFrame)
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
    /// not also run.
    func hideCommandBarAfterSubmitting() {
        onCommandPillDismissed = nil
        hideCommandBar()
    }

    private func makeCommandBarPanel() -> KeyablePanel {
        let commandBarPanel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: commandBarWidth, height: 80))
        // The window server derives this shadow from the rounded card's alpha; a SwiftUI
        // shadow would be clipped at the panel's edges.
        commandBarPanel.hasShadow = true
        let commandBarPanelFrameApplier = DeferredPanelFrameApplier(panel: commandBarPanel)
        self.commandBarPanelFrameApplier = commandBarPanelFrameApplier
        // Content that changes size while shown (an attachment chip) keeps the bar's top-left corner in place, and
        // the pill beside its pointer and on screen, applied outside SwiftUI's update.
        commandContentSizeBox.onContentSizeChange = { [weak self] _ in
            self?.commandBarPanelFrameApplier?.scheduleFrameUpdate { [weak self] in
                guard let self, let commandBarPanel = self.commandBarPanel, commandBarPanel.isVisible else { return nil }
                let contentSize = self.commandContentSizeBox.latestContentSize
                if let commandPillPointerInTopLeftGlobalPoints = self.commandPillPointerInTopLeftGlobalPoints {
                    return self.commandPillFrame(forPillSize: contentSize, pointerPoint: commandPillPointerInTopLeftGlobalPoints)
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
