import AppKit
import SwiftUI
import Combine

/// Click-through and never key: the ring sits under the real pointer, so it must let every click and move through
/// to the app beneath it.
final class SummonGestureRingPanel: DottoPanel {
    init() {
        super.init(contentRect: .zero, level: .statusBar)
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }
}

/// Draws the circle summon gesture's progress ring around the real pointer, and its fire pulse.
@MainActor
final class SummonGestureRingPanelController {
    /// Room for the ring at its 1.45× pulse and the glyph that pokes out of its box.
    private static let panelSideLength: CGFloat = 110

    private let viewModel = SummonGestureRingViewModel()
    private lazy var ringPanel = makeRingPanel()
    private var hideAfterFireTask: Task<Void, Never>?

    func showRing(atTopLeftGlobalPoint topLeftGlobalPoint: CGPoint, progress: Double, glyphVisible: Bool, taskColor: Color,
                  ringOpacity: Double = 1) {
        hideAfterFireTask?.cancel()
        hideAfterFireTask = nil
        viewModel.isFiring = false
        viewModel.taskColor = taskColor
        viewModel.progress = progress
        viewModel.glyphVisible = glyphVisible
        viewModel.ringOpacity = ringOpacity
        centerRingPanel(onTopLeftGlobalPoint: topLeftGlobalPoint)
        if !ringPanel.isVisible { ringPanel.orderFrontRegardless() }
    }

    func hideRing() {
        hideAfterFireTask?.cancel()
        hideAfterFireTask = nil
        viewModel.isFiring = false
        viewModel.progress = 0
        viewModel.glyphVisible = false
        if ringPanel.isVisible { ringPanel.orderOut(nil) }
    }

    /// Leaves a fire pulse to finish on its own, so the pill opening (which stops observation) doesn't cut it short.
    func hideRingUnlessFiring() {
        guard hideAfterFireTask == nil else { return }
        hideRing()
    }

    /// The full ring pulses out (grows and fades) where the gesture finished. With Reduce Motion there is no pulse:
    /// the ring simply goes away as the pill opens.
    func fireRing(atTopLeftGlobalPoint topLeftGlobalPoint: CGPoint, taskColor: Color, reducesMotion: Bool) {
        guard !reducesMotion else {
            hideRing()
            return
        }
        showRing(atTopLeftGlobalPoint: topLeftGlobalPoint, progress: 1, glyphVisible: false, taskColor: taskColor)
        withAnimation(.easeOut(duration: SummonGestureRingView.firePulseDuration)) {
            viewModel.isFiring = true
        }
        hideAfterFireTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((SummonGestureRingView.firePulseDuration + 0.03) * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.hideAfterFireTask = nil
            self.hideRing()
        }
    }

    private func centerRingPanel(onTopLeftGlobalPoint topLeftGlobalPoint: CGPoint) {
        let appKitCenter = ScreenGeometry.appKitFrame(fromTopLeftGlobalFrame: CGRect(origin: topLeftGlobalPoint, size: .zero)).origin
        let halfSide = Self.panelSideLength / 2
        ringPanel.setFrameOrigin(NSPoint(x: appKitCenter.x - halfSide, y: appKitCenter.y - halfSide))
    }

    private func makeRingPanel() -> SummonGestureRingPanel {
        let ringPanel = SummonGestureRingPanel()
        let hostingView = NSHostingView(rootView: SummonGestureRingView(viewModel: viewModel)
            .frame(width: Self.panelSideLength, height: Self.panelSideLength)).withClearBackground().sizedOnlyByItsPanel()
        ringPanel.contentView = hostingView
        ringPanel.setContentSize(NSSize(width: Self.panelSideLength, height: Self.panelSideLength))
        return ringPanel
    }
}
