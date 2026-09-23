import AppKit
import SwiftUI

extension NSHostingView {
    /// Dotto sizes every panel itself. By default a hosting view also pushes its content's minimum, ideal and
    /// maximum size onto the window as constraints; when the content changes size (a pill's text, a checklist row)
    /// while Dotto moves or resizes the same window, AppKit's Update Constraints pass never settles and throws. With
    /// no sizing options the hosting view never drives the window; the content reports its size through
    /// `reportingPanelContentSize(to:)` instead.
    @discardableResult
    func sizedOnlyByItsPanel() -> Self {
        sizingOptions = []
        return self
    }

    /// Lays the content out now, which also flushes pending model changes into it, and returns the size it reported.
    /// Only for Dotto's own code paths (showing a panel, answering a state change), never from inside a layout pass or
    /// a SwiftUI geometry callback.
    func laidOutContentSize(reportedTo contentSizeBox: PanelContentSizeBox) -> CGSize {
        layoutSubtreeIfNeeded()
        return contentSizeBox.latestContentSize
    }
}

/// The latest size a panel's SwiftUI content reported for itself. The content must be `fixedSize` (in the directions
/// that follow the content), so what it reports is its ideal size whatever size the window happens to be.
@MainActor
final class PanelContentSizeBox {
    private(set) var latestContentSize: CGSize = .zero
    /// Runs inside SwiftUI's update, so it may only record or schedule work (`DeferredPanelFrameApplier`), never
    /// resize a window.
    var onContentSizeChange: ((CGSize) -> Void)?

    func record(_ contentSize: CGSize) {
        guard !contentSize.isNearlyEqual(to: latestContentSize) else { return }
        latestContentSize = contentSize
        onContentSizeChange?(contentSize)
    }
}

extension View {
    func reportingPanelContentSize(to contentSizeBox: PanelContentSizeBox) -> some View {
        onGeometryChange(for: CGSize.self) { geometryProxy in geometryProxy.size } action: { contentSize in
            contentSizeBox.record(contentSize)
        }
    }
}

/// Applies a panel's frame on a later turn of the main run loop, outside the layout or SwiftUI update that noticed the
/// change. Requests made before it runs are coalesced (the latest frame wins, computed when it applies), frames within
/// half a point of the current one are skipped, and a frame whose size is unchanged only moves the panel.
@MainActor
final class DeferredPanelFrameApplier {
    nonisolated static let frameChangeTolerance: CGFloat = 0.5

    private weak var panel: NSWindow?
    private var pendingFrameProvider: (() -> CGRect?)?
    private var isApplyScheduled = false
    private var isApplyingFrame = false

    init(panel: NSWindow) {
        self.panel = panel
    }

    /// `frameProvider` runs when the frame is applied, so it sees the latest content size and anchor; nil skips.
    func scheduleFrameUpdate(_ frameProvider: @escaping () -> CGRect?) {
        pendingFrameProvider = frameProvider
        guard !isApplyScheduled else { return }
        isApplyScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.applyPendingFrame() }
        }
    }

    func cancelPendingFrameUpdate() {
        pendingFrameProvider = nil
    }

    /// For Dotto's own code paths only (showing a panel, following the cursor), never from inside a layout pass.
    func applyFrameNow(_ frame: CGRect) {
        guard let panel, !isApplyingFrame, frame.width > 0, frame.height > 0 else { return }
        isApplyingFrame = true
        defer { isApplyingFrame = false }
        let currentFrame = panel.frame
        guard !frame.isNearlyEqual(to: currentFrame) else { return }
        if frame.size.isNearlyEqual(to: currentFrame.size) {
            panel.setFrameOrigin(frame.origin)
        } else {
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
        }
    }

    private func applyPendingFrame() {
        isApplyScheduled = false
        guard let frameProvider = pendingFrameProvider else { return }
        pendingFrameProvider = nil
        guard let frame = frameProvider() else { return }
        applyFrameNow(frame)
    }
}

extension CGSize {
    func isNearlyEqual(to otherSize: CGSize) -> Bool {
        abs(width - otherSize.width) <= DeferredPanelFrameApplier.frameChangeTolerance
            && abs(height - otherSize.height) <= DeferredPanelFrameApplier.frameChangeTolerance
    }
}

extension CGRect {
    func isNearlyEqual(to otherRect: CGRect) -> Bool {
        size.isNearlyEqual(to: otherRect.size)
            && abs(minX - otherRect.minX) <= DeferredPanelFrameApplier.frameChangeTolerance
            && abs(minY - otherRect.minY) <= DeferredPanelFrameApplier.frameChangeTolerance
    }
}
