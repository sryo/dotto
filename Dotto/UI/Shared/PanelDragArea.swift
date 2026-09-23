import AppKit
import SwiftUI

/// Dragging here moves the panel. Laid over the non-interactive parts of a panel (a header, a preview image),
/// because SwiftUI content would otherwise swallow the mouse-down before the window could start a drag.
struct PanelDragArea: NSViewRepresentable {
    var tooltip: String?

    func makeNSView(context: Context) -> NSView {
        let panelDragAreaView = PanelDragAreaNSView()
        panelDragAreaView.toolTip = tooltip
        return panelDragAreaView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.toolTip = tooltip
    }
}

private final class PanelDragAreaNSView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}
