import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    static let dismissMenuBarPanel = Notification.Name("dottoDismissPanel")
    static let showMenuBarPanel = Notification.Name("dottoShowPanel")
}

/// The menu bar icon and the panel that drops down below it. The panel is non-activating, so opening it doesn't take
/// focus from the user's app, and it closes when the user clicks anywhere else, like a popover.
@MainActor
final class MenuBarPanelController: NSObject {
    private var statusItem: NSStatusItem?
    private var panel: KeyablePanel?
    private var panelHostingView: NSHostingView<AnyView>?
    private var panelFrameApplier: DeferredPanelFrameApplier?
    private let panelContentSizeBox = PanelContentSizeBox()
    private var clickOutsideMonitor: Any?
    private var dismissPanelObserver: NSObjectProtocol?
    private var showPanelObserver: NSObjectProtocol?
    private var menuBarIconPulseSubscription: AnyCancellable?
    private var menuBarIconPulseTimer: Timer?
    private var menuBarIconPulseStartDate = Date()

    private let taskSessionController: TaskSessionController
    private let panelWidth: CGFloat = 320
    private let gapBelowMenuBar: CGFloat = 4

    init(taskSessionController: TaskSessionController) {
        self.taskSessionController = taskSessionController
        super.init()
        createStatusItem()
        menuBarIconPulseSubscription = taskSessionController.$isMenuBarIconPulsing
            .removeDuplicates()
            .sink { [weak self] isMenuBarIconPulsing in
                self?.setMenuBarIconPulsing(isMenuBarIconPulsing)
            }

        dismissPanelObserver = NotificationCenter.default.addObserver(
            forName: .dismissMenuBarPanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.hidePanel()
        }

        showPanelObserver = NotificationCenter.default.addObserver(
            forName: .showMenuBarPanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.showPanel()
        }
    }

    deinit {
        if let clickOutsideMonitor {
            NSEvent.removeMonitor(clickOutsideMonitor)
        }
        if let dismissPanelObserver {
            NotificationCenter.default.removeObserver(dismissPanelObserver)
        }
        if let showPanelObserver {
            NotificationCenter.default.removeObserver(showPanelObserver)
        }
    }

    // MARK: - Status item

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let statusItemButton = statusItem?.button else { return }
        statusItemButton.image = MenuBarGlyph.makeTemplateImage()
        statusItemButton.action = #selector(statusItemClicked)
        statusItemButton.target = self
    }

    /// Dotto's cursor arrow as the menu bar icon: a template image normally, the task color while a decision waits
    /// for the user.
    private func makeMenuBarIcon(arrowScale: CGFloat, arrowColor: NSColor?) -> NSImage {
        let iconSideLength: CGFloat = 18
        let arrowSideLength: CGFloat = 12 * arrowScale
        let arrowRect = CGRect(x: (iconSideLength - arrowSideLength) / 2, y: (iconSideLength - arrowSideLength) / 2,
                               width: arrowSideLength, height: arrowSideLength)
        // Flipped, so the image's y grows downward like the SwiftUI shape's.
        let menuBarIcon = NSImage(size: NSSize(width: iconSideLength, height: iconSideLength), flipped: true) { _ in
            guard let graphicsContext = NSGraphicsContext.current?.cgContext else { return false }
            let arrowPath = CursorArrowShape().path(in: arrowRect).cgPath
            let arrowCGColor = (arrowColor ?? .black).cgColor
            graphicsContext.setFillColor(arrowCGColor)
            graphicsContext.setStrokeColor(arrowCGColor)
            graphicsContext.setLineJoin(.round)
            graphicsContext.setLineWidth(1.6 * arrowScale)
            graphicsContext.addPath(arrowPath)
            graphicsContext.drawPath(using: .fillStroke)
            return true
        }
        menuBarIcon.isTemplate = arrowColor == nil
        return menuBarIcon
    }

    /// Pulses the arrow between 1× and 1.45× every 1.1 s while a decision is pending; with Reduce Motion it just
    /// turns the task color and stays still.
    private func setMenuBarIconPulsing(_ isMenuBarIconPulsing: Bool) {
        menuBarIconPulseTimer?.invalidate()
        menuBarIconPulseTimer = nil
        guard let statusItemButton = statusItem?.button else { return }
        guard isMenuBarIconPulsing else {
            statusItemButton.image = MenuBarGlyph.makeTemplateImage()
            return
        }
        let cursorStyleConfiguration = taskSessionController.cursorStyleConfiguration
        let taskColor = NSColor(cursorStyleConfiguration.taskAccentColor)
        guard !cursorStyleConfiguration.reducesMotion(systemReduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) else {
            statusItemButton.image = makeMenuBarIcon(arrowScale: 1.2, arrowColor: taskColor)
            return
        }
        menuBarIconPulseStartDate = Date()
        menuBarIconPulseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let statusItemButton = self.statusItem?.button else { return }
                let pulsePeriodSeconds = 1.1
                let pulsePhase = Date().timeIntervalSince(self.menuBarIconPulseStartDate)
                    .truncatingRemainder(dividingBy: pulsePeriodSeconds) / pulsePeriodSeconds
                // Ease-in-out up to the peak at mid-period and back down, like the lab's `mbpulse` keyframes.
                let pulseAmount = (1 - cos(2 * .pi * pulsePhase)) / 2
                statusItemButton.image = self.makeMenuBarIcon(arrowScale: 1 + 0.45 * CGFloat(pulseAmount), arrowColor: taskColor)
            }
        }
    }

    /// Opens the panel on launch so the user sees the permissions UI right away.
    func showPanelOnLaunch() {
        // Gives the status item time to appear, since the panel is positioned below it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.showPanel()
        }
    }

    @objc private func statusItemClicked() {
        if let panel, panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    // MARK: - Panel

    private func showPanel() {
        // "2 min ago" and whether the last task can still be undone are read fresh each time the panel opens.
        taskSessionController.refreshMostRecentUndoableJournal()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        positionPanelBelowStatusItem()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        installClickOutsideMonitor()
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        removeClickOutsideMonitor()
    }

    private func makePanel() -> KeyablePanel {
        let menuBarPanel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 380))
        let hostingView = NSHostingView(rootView: AnyView(MenuBarPanelView(
            taskSessionController: taskSessionController,
            onContentHeightChange: { [panelContentSizeBox, panelWidth] contentHeight in
                panelContentSizeBox.record(CGSize(width: panelWidth, height: contentHeight))
            }
        ).drawsControlsAsActive())).withClearBackground().sizedOnlyByItsPanel()
        menuBarPanel.contentView = hostingView
        panelHostingView = hostingView
        panelFrameApplier = DeferredPanelFrameApplier(panel: menuBarPanel)
        // Reported from inside SwiftUI's update: the panel follows on a later turn of the run loop.
        panelContentSizeBox.onContentSizeChange = { [weak self] _ in
            self?.panelFrameApplier?.scheduleFrameUpdate { [weak self] in
                self?.visiblePanelFrameKeepingTopAnchored()
            }
        }
        return menuBarPanel
    }

    /// Centered under the menu bar icon, as tall as its content.
    private func positionPanelBelowStatusItem() {
        guard let panelHostingView, let statusItemFrame = statusItem?.button?.window?.frame else { return }
        let panelHeight = panelHostingView.laidOutContentSize(reportedTo: panelContentSizeBox).height
        guard panelHeight > 0 else { return }
        panelFrameApplier?.cancelPendingFrameUpdate()
        panelFrameApplier?.applyFrameNow(NSRect(x: statusItemFrame.midX - panelWidth / 2,
                                                y: statusItemFrame.minY - gapBelowMenuBar - panelHeight,
                                                width: panelWidth, height: panelHeight))
    }

    private func visiblePanelFrameKeepingTopAnchored() -> CGRect? {
        let contentHeight = panelContentSizeBox.latestContentSize.height
        guard let panel, panel.isVisible, contentHeight > 0 else { return nil }
        return ScreenCorner.topLeft.frame(ofSize: CGSize(width: panel.frame.width, height: contentHeight),
                                          keepingCornerAt: ScreenCorner.topLeft.point(of: panel.frame))
    }

    // MARK: - Click-outside dismissal

    /// Global monitors only see clicks delivered to other apps, so every click this sees is outside the panel and
    /// the status item (a click on the icon toggles the panel through `statusItemClicked` instead).
    private func installClickOutsideMonitor() {
        removeClickOutsideMonitor()
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            // The delay lets a system permission dialog opened from a Grant button come up first, so the check
            // below can keep the panel open while permissions are being set up.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard let self, let panel = self.panel, panel.isVisible else { return }
                if !self.taskSessionController.permissionStatus.allRequiredPermissionsGranted && !NSApp.isActive {
                    return
                }
                self.hidePanel()
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
