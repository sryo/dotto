import AppKit

/// The base of every Dotto window. It is always borderless and non-activating, so showing it or clicking in it
/// never activates Dotto or takes the user's front window (invariant 3b); the style mask can't lose
/// `.nonactivatingPanel` later either. Transparent, on every Space, out of the Window menu, and never key or main
/// unless a subclass says so.
class DottoPanel: NSPanel {
    init(contentRect: NSRect, level: NSWindow.Level = .floating) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.level = level
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var styleMask: NSWindow.StyleMask {
        get { super.styleMask }
        set { super.styleMask = newValue.union(.nonactivatingPanel) }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A panel with text fields or key handling (command bar, checklist, menu bar panel). Being non-activating, it can
/// take the keyboard without activating Dotto.
class KeyablePanel: DottoPanel {
    override var canBecomeKey: Bool { true }
}

/// A panel whose buttons work on the first click without taking keyboard focus, so answering Dotto from the cursor
/// pill or the live view leaves the user's app exactly as it was.
final class NonActivatingClickablePanel: DottoPanel {
    override init(contentRect: NSRect, level: NSWindow.Level = .floating) {
        super.init(contentRect: contentRect, level: level)
        becomesKeyOnlyIfNeeded = true
    }
}
