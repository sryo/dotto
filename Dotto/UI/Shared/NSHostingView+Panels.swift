import AppKit
import SwiftUI

extension NSHostingView {
    /// Clears the layer behind the SwiftUI content, so only a panel's own rounded card shows.
    @discardableResult
    func withClearBackground() -> Self {
        wantsLayer = true
        layer?.backgroundColor = .clear
        return self
    }
}

/// Without this, the first click on an inactive app's window only "focuses" it and the button never fires.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

extension View {
    /// Dotto never activates itself (it must not take focus from the user's app), so SwiftUI would draw every
    /// switch, field and checkbox in its panels with the gray "inactive window" look. The user opened these panels
    /// and is using them, so their controls should look live.
    func drawsControlsAsActive() -> some View {
        environment(\.controlActiveState, .key)
    }
}
