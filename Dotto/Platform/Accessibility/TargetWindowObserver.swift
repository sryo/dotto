import AppKit
import ApplicationServices

/// Reports the user moving, resizing, minimizing or closing the target app's windows, which may pause the run.
/// The run is pinned to the window that was in front when it started. Every event says whether it concerns that
/// window and carries its current frame, so `UserTakeoverDetector` can ignore other windows (Get Info windows,
/// inspectors, sheets Dotto's own steps open and close), notifications that changed nothing, and Dotto's own actions.
@MainActor final class TargetWindowObserver {
    private static let applicationNotificationNames = [kAXWindowMovedNotification, kAXWindowResizedNotification,
                                                       kAXWindowMiniaturizedNotification]

    var onTargetWindowEvent: ((ObservedTargetWindowEvent) -> Void)?

    private let windowServerBridge: PrivateWindowServerBridge
    private var windowObserver: AXObserver?
    private var observedApplicationElement: AXUIElement?
    private var pinnedTargetWindow: AXUIElement?
    private var usesRemoteAwareNotifications = false

    init(windowServerBridge: PrivateWindowServerBridge) {
        self.windowServerBridge = windowServerBridge
    }

    var pinnedTargetWindowFrameInTopLeftGlobalPoints: CGRect? {
        pinnedTargetWindow.flatMap(AccessibilityElementReader.frameInTopLeftGlobalPoints)
    }

    func startObserving(_ targetApplication: TargetApplicationReference) {
        stopObserving()
        let observerCallback: AXObserverCallback = { _, notifiedElement, notificationName, context in
            guard let context else { return }
            let targetWindowObserver = Unmanaged<TargetWindowObserver>.fromOpaque(context).takeUnretainedValue()
            // The observer's run loop source is on the main run loop, so this callback runs on the main thread.
            MainActor.assumeIsolated {
                targetWindowObserver.handleNotification(notificationName as String, notifiedElement: notifiedElement)
            }
        }
        var createdObserver: AXObserver?
        guard AXObserverCreate(targetApplication.processIdentifier, observerCallback, &createdObserver) == .success,
              let createdObserver else { return }
        let applicationKind = TargetApplicationAccessibilityModes.applicationKind(of: targetApplication)
        usesRemoteAwareNotifications = (applicationKind == .chromiumBrowser || applicationKind == .electron)
            && windowServerBridge.capabilities.canKeepRemoteAccessibilityTreeAlive
        let applicationElement = AccessibilityElementReader.makeApplicationElement(for: targetApplication.processIdentifier)
        windowObserver = createdObserver
        observedApplicationElement = applicationElement
        for notificationName in Self.applicationNotificationNames {
            addNotification(notificationName, on: applicationElement)
        }
        pinFrontWindow()
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(createdObserver), .defaultMode)
    }

    func stopObserving() {
        if let windowObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(windowObserver), .defaultMode)
        }
        windowObserver = nil
        observedApplicationElement = nil
        pinnedTargetWindow = nil
    }

    /// Pins the app's front window (focused, then main, then the first) in place of the current pin, and returns its
    /// frame for the detector's new baseline.
    @discardableResult func pinFrontWindow() -> CGRect? {
        guard let windowObserver, let observedApplicationElement else { return nil }
        if let pinnedTargetWindow {
            AXObserverRemoveNotification(windowObserver, pinnedTargetWindow, kAXUIElementDestroyedNotification as CFString)
        }
        pinnedTargetWindow = AccessibilityElementReader.focusedWindowElement(ofApplicationElement: observedApplicationElement)
        // Destruction can only be observed on the window itself.
        if let pinnedTargetWindow { addNotification(kAXUIElementDestroyedNotification, on: pinnedTargetWindow) }
        print("Dotto takeover watch: pinned \(describePinnedTargetWindow())")
        return pinnedTargetWindowFrameInTopLeftGlobalPoints
    }

    private func handleNotification(_ notificationName: String, notifiedElement: AXUIElement) {
        let eventKind: ObservedTargetWindowEventKind
        switch notificationName {
        case kAXWindowMovedNotification, kAXWindowResizedNotification:
            eventKind = .movedOrResized
        case kAXWindowMiniaturizedNotification, kAXUIElementDestroyedNotification:
            eventKind = .closedOrMinimized
        default:
            return
        }
        // The app had no window when the run started; the first one it reports on becomes the pin.
        if pinnedTargetWindow == nil { pinFrontWindow() }
        // A destroyed element can no longer be compared by its attributes, but CFEqual still matches the reference
        // the notification was registered on, which is only ever the pinned window.
        let isOnPinnedTargetWindow = pinnedTargetWindow.map { CFEqual($0, notifiedElement) } ?? false
        let pinnedTargetWindowFrame = (isOnPinnedTargetWindow && eventKind == .movedOrResized)
            ? pinnedTargetWindowFrameInTopLeftGlobalPoints : nil
        onTargetWindowEvent?(ObservedTargetWindowEvent(kind: eventKind,
                                                       timestampSeconds: UserInputObserver.currentMonotonicTimestampSeconds(),
                                                       isOnPinnedTargetWindow: isOnPinnedTargetWindow,
                                                       pinnedTargetWindowFrameInTopLeftGlobalPoints: pinnedTargetWindowFrame))
    }

    /// The frame only, never the title (it can name the user's document), for the console: which window later
    /// takeover decisions are about.
    private func describePinnedTargetWindow() -> String {
        guard pinnedTargetWindow != nil else { return "no window" }
        return pinnedTargetWindowFrameInTopLeftGlobalPoints.map { "the window at \($0)" } ?? "a window with an unknown frame"
    }

    private func addNotification(_ notificationName: String, on observedElement: AXUIElement) {
        guard let windowObserver else { return }
        let observerContext = Unmanaged.passUnretained(self).toOpaque()
        if usesRemoteAwareNotifications,
           windowServerBridge.addRemoteAwareNotification(notificationName, to: windowObserver, element: observedElement,
                                                         context: observerContext) == .success {
            return
        }
        AXObserverAddNotification(windowObserver, observedElement, notificationName as CFString, observerContext)
    }
}
