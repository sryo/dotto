import AppKit
import SwiftUI

/// Uses AppKit's `NSView.toolTip` to show a tooltip on hover.
/// SwiftUI's `.help()` conflicts with `.onHover` tracking areas, so
/// this bridges directly to AppKit's tooltip system which works independently.
private struct NativeTooltipView: NSViewRepresentable {
    let tooltip: String

    func makeNSView(context: Context) -> NSView {
        let view = ClickThroughTooltipNSView()
        view.toolTip = tooltip
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.toolTip = tooltip
    }
}

/// The tooltip overlay sits on top of the control it describes. AppKit shows tooltips from the view's tooltip rect
/// whatever hit testing says, so the overlay passes every click through to the control underneath instead of
/// swallowing it.
private final class ClickThroughTooltipNSView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

extension View {
    /// Attaches a native macOS tooltip that works even alongside `.onHover`.
    func nativeTooltip(_ text: String?) -> some View {
        if let text = text, !text.isEmpty {
            return AnyView(self.overlay(NativeTooltipView(tooltip: text)))
        } else {
            return AnyView(self)
        }
    }
}
