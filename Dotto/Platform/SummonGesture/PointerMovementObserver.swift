import AppKit

/// One pointer move, as the circle recognizer needs it: where the pointer was (top-left global points, y down), when
/// (the event's own timestamp: seconds since boot on the uptime clock, so delivery delays don't distort the speed),
/// and whether any mouse button is held (drags, selections and drawing never count).
struct ObservedPointerMovement: Equatable, Sendable {
    var topLeftGlobalLocation: CGPoint
    var timestampSeconds: TimeInterval
    var anyMouseButtonHeld: Bool
}

/// The one global input observation Dotto makes while no task is running, for the circle summon gesture: pointer
/// moves, plus the fact that a mouse button went down or up. No keyboard events, no click positions and no drags are
/// observed, and nothing is kept here: every move goes straight to the recognizer's rolling buffer. The owner starts
/// it only while the gesture is eligible (`SummonGestureEligibility`) and stops it otherwise.
///
/// NSEvent monitors rather than an event tap: mouse-move monitors need no Accessibility permission and can't hold up
/// the system pointer. The global monitor sees moves over other apps' windows, the local one moves over Dotto's own.
@MainActor final class PointerMovementObserver {
    var onPointerMoved: ((ObservedPointerMovement) -> Void)?
    /// A button went down: whatever was being drawn is a click or a drag now, not a circle.
    var onMouseButtonPressed: (() -> Void)?

    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?

    private static let observedEventMask: NSEvent.EventTypeMask = [
        .mouseMoved,
        .leftMouseDown, .leftMouseUp,
        .rightMouseDown, .rightMouseUp,
        .otherMouseDown, .otherMouseUp,
    ]

    var isObserving: Bool { globalEventMonitor != nil }

    /// Idempotent.
    func startObserving() {
        guard globalEventMonitor == nil else { return }
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: Self.observedEventMask) { [weak self] observedEvent in
            // Global monitors are called on the main thread.
            MainActor.assumeIsolated { self?.handleObservedEvent(observedEvent) }
        }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.observedEventMask) { [weak self] observedEvent in
            MainActor.assumeIsolated { self?.handleObservedEvent(observedEvent) }
            return observedEvent
        }
    }

    /// Idempotent.
    func stopObserving() {
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
    }

    private func handleObservedEvent(_ observedEvent: NSEvent) {
        switch observedEvent.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            onMouseButtonPressed?()
        case .mouseMoved:
            // No display height known at all means no display to draw on; the sample is dropped rather than misplaced.
            guard let topLeftGlobalLocation = Self.topLeftGlobalLocation(of: observedEvent) else { return }
            onPointerMoved?(ObservedPointerMovement(
                topLeftGlobalLocation: topLeftGlobalLocation,
                timestampSeconds: observedEvent.timestamp,
                anyMouseButtonHeld: NSEvent.pressedMouseButtons != 0))
        default:
            // A button coming up needs no callback: the next move reads the held buttons afresh.
            break
        }
    }

    /// Where the event happened rather than where the pointer is by the time it is handled. A local event's location
    /// is relative to its window and a global one's is already in screen points; either is then flipped from
    /// AppKit's bottom-left origin to the top-left space the recognizer works in.
    private static func topLeftGlobalLocation(of observedEvent: NSEvent) -> CGPoint? {
        let appKitGlobalLocation = observedEvent.window?.convertPoint(toScreen: observedEvent.locationInWindow)
            ?? observedEvent.locationInWindow
        guard let primaryDisplayHeightInPoints = PrimaryDisplayHeightReader.primaryDisplayHeightInPoints else { return nil }
        return CGPoint(x: appKitGlobalLocation.x, y: primaryDisplayHeightInPoints - appKitGlobalLocation.y)
    }
}
