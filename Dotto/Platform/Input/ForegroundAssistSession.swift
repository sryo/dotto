import AppKit
import ApplicationServices

/// The only time Dotto takes focus: after the user approved "Bring <App> forward for a moment?" (or an upload), the
/// target comes to the front, `body` runs, and the user's previous app, its window and the real cursor are put back.
/// Uses only public AX and AppKit calls, so it works with no private symbols at all.
@MainActor enum ForegroundAssistSession {
    static let maximumAssistSeconds: TimeInterval = 10
    static let maximumUploadAssistSeconds: TimeInterval = 20
    private static let frontmostWaitSeconds: TimeInterval = 1.5
    private static let frontmostPollNanoseconds: UInt64 = 50_000_000
    private static let windowFocusWaitSeconds: TimeInterval = 0.5
    private static let activationSettleNanoseconds: UInt64 = 200_000_000

    /// Assists never overlap: the second one would save the first one's target as "where the user was".
    private(set) static var isRunning = false

    private struct SavedUserPosition {
        var frontmostApplication: NSRunningApplication?
        var frontmostApplicationFocusedWindow: AXUIElement?
        var cursorLocationInTopLeftGlobalPoints: CGPoint?
        /// Real (HID) mouse movement is counted by the system, so the restore can tell the user's own movement apart.
        var realMouseMoveEventCount: UInt32
    }

    static func run<AssistResult: Sendable>(targetApplication: TargetApplicationReference, targetWindow: AXUIElement?,
                                            timeLimitSeconds: TimeInterval, abortSignal: TaskAbortSignal,
                                            automatedActivityRelay: AutomatedTargetActivityRelay,
                                            body: @escaping () async throws -> AssistResult) async throws -> AssistResult {
        try abortSignal.throwIfAborted()
        guard !isRunning else { throw ActionBackendError.foregroundAssistFailed("another bring-forward step is still running") }
        isRunning = true
        // Reported around the restore too: bringing the user's app back re-orders and re-lays out the target's windows.
        automatedActivityRelay.report(.foregroundAssistStarted, targetProcessIdentifier: nil)
        defer {
            isRunning = false
            automatedActivityRelay.report(.foregroundAssistFinished, targetProcessIdentifier: nil)
        }

        let savedUserPosition = saveUserPosition(excludingTarget: targetApplication)
        let assistStartUptime = ProcessInfo.processInfo.systemUptime
        print("Dotto foreground assist: bringing \(targetApplication.applicationName) forward "
              + "(user was in \(savedUserPosition.frontmostApplication?.localizedName ?? "no app"))")
        do {
            try await bringForward(targetApplication, targetWindow: targetWindow)
            let assistResult = try await runWithTimeLimit(timeLimitSeconds, applicationName: targetApplication.applicationName, body: body)
            await restore(savedUserPosition, targetApplication: targetApplication, assistStartUptime: assistStartUptime)
            return assistResult
        } catch {
            await restore(savedUserPosition, targetApplication: targetApplication, assistStartUptime: assistStartUptime)
            throw error
        }
    }

    private static func saveUserPosition(excludingTarget targetApplication: TargetApplicationReference) -> SavedUserPosition {
        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        var frontmostApplicationFocusedWindow: AXUIElement?
        if let frontmostApplication, frontmostApplication.processIdentifier != targetApplication.processIdentifier {
            let frontmostApplicationElement = AccessibilityElementReader.makeApplicationElement(for: frontmostApplication.processIdentifier)
            frontmostApplicationFocusedWindow = AccessibilityElementReader.elementAttribute(kAXFocusedWindowAttribute,
                                                                                            of: frontmostApplicationElement)
        }
        return SavedUserPosition(frontmostApplication: frontmostApplication,
                                 frontmostApplicationFocusedWindow: frontmostApplicationFocusedWindow,
                                 cursorLocationInTopLeftGlobalPoints: CGEvent(source: nil)?.location,
                                 realMouseMoveEventCount: realMouseMoveEventCount())
    }

    private static func bringForward(_ targetApplication: TargetApplicationReference, targetWindow: AXUIElement?) async throws {
        let targetProcessIdentifier = targetApplication.processIdentifier
        guard await bringToFront(targetProcessIdentifier, window: targetWindow) else {
            throw ActionBackendError.foregroundAssistFailed("\(targetApplication.applicationName) didn't come to the front")
        }
        // Frontmost comes before the app has made its window key; input sent in between reaches no window at all.
        if let targetWindow { await waitUntilFocused(targetWindow, of: targetProcessIdentifier) }
        try? await Task.sleep(nanoseconds: activationSettleNanoseconds)
    }

    /// Accessibility first (frontmost, then raise the window and make it main), and plain activation only when the
    /// app didn't come forward that way. Returns whether the process is frontmost afterwards.
    private static func bringToFront(_ processIdentifier: pid_t, window: AXUIElement?) async -> Bool {
        if !isFrontmost(processIdentifier) {
            let applicationElement = AccessibilityElementReader.makeApplicationElement(for: processIdentifier)
            _ = AXUIElementSetAttributeValue(applicationElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        }
        if let window {
            _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
        if await waitUntilFrontmost(processIdentifier) { return true }
        NSRunningApplication(processIdentifier: processIdentifier)?.activate()
        return await waitUntilFrontmost(processIdentifier)
    }

    /// Always runs, also after an error or abort. The user's app is only brought back when the target is still in
    /// front: if the user switched apps during the assist, that choice wins.
    private static func restore(_ savedUserPosition: SavedUserPosition, targetApplication: TargetApplicationReference,
                                assistStartUptime: TimeInterval) async {
        var restoredPreviousApplication = false
        if let previousApplication = savedUserPosition.frontmostApplication,
           previousApplication.processIdentifier != targetApplication.processIdentifier,
           isFrontmost(targetApplication.processIdentifier) {
            restoredPreviousApplication = await bringToFront(previousApplication.processIdentifier,
                                                             window: savedUserPosition.frontmostApplicationFocusedWindow)
        }

        let assistDurationSeconds = ProcessInfo.processInfo.systemUptime - assistStartUptime
        var cursorNote = "cursor unchanged"
        if let savedCursorLocation = savedUserPosition.cursorLocationInTopLeftGlobalPoints,
           let currentCursorLocation = CGEvent(source: nil)?.location, currentCursorLocation != savedCursorLocation {
            // The assist posts no HID pointer events, so a moved cursor with no real mouse movement is a side effect
            // to undo. When the user moved the mouse themselves, their position wins.
            if realMouseMoveEventCount() == savedUserPosition.realMouseMoveEventCount {
                CGWarpMouseCursorPosition(savedCursorLocation)
                cursorNote = "cursor put back"
            } else {
                cursorNote = "the user moved the mouse, so the cursor stays where they left it"
            }
        }
        print("Dotto foreground assist: finished after \(String(format: "%.1f", assistDurationSeconds)) s; "
              + "previous app restored: \(restoredPreviousApplication); \(cursorNote)")
    }

    private static func runWithTimeLimit<AssistResult: Sendable>(_ timeLimitSeconds: TimeInterval, applicationName: String,
                                                                 body: @escaping () async throws -> AssistResult) async throws -> AssistResult {
        try await withThrowingTaskGroup(of: AssistResult?.self) { assistTaskGroup in
            assistTaskGroup.addTask { try await body() }
            assistTaskGroup.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeLimitSeconds * 1_000_000_000))
                return nil
            }
            defer { assistTaskGroup.cancelAll() }
            guard let firstFinishedResult = try await assistTaskGroup.next(), let assistResult = firstFinishedResult else {
                throw ActionBackendError.foregroundAssistFailed(
                    "the step in \(applicationName) took longer than \(Int(timeLimitSeconds)) s")
            }
            return assistResult
        }
    }

    private static func realMouseMoveEventCount() -> UInt32 {
        [CGEventType.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged].reduce(UInt32(0)) { eventCount, eventType in
            eventCount &+ CGEventSource.counterForEventType(.hidSystemState, eventType: eventType)
        }
    }

    private static func waitUntilFrontmost(_ processIdentifier: pid_t) async -> Bool {
        let deadlineUptime = ProcessInfo.processInfo.systemUptime + frontmostWaitSeconds
        while ProcessInfo.processInfo.systemUptime < deadlineUptime {
            if isFrontmost(processIdentifier) { return true }
            try? await Task.sleep(nanoseconds: frontmostPollNanoseconds)
        }
        return isFrontmost(processIdentifier)
    }

    private static func waitUntilFocused(_ targetWindow: AXUIElement, of processIdentifier: pid_t) async {
        let applicationElement = AccessibilityElementReader.makeApplicationElement(for: processIdentifier)
        let deadlineUptime = ProcessInfo.processInfo.systemUptime + windowFocusWaitSeconds
        while ProcessInfo.processInfo.systemUptime < deadlineUptime {
            if let focusedWindow = AccessibilityElementReader.elementAttribute(kAXFocusedWindowAttribute, of: applicationElement),
               CFEqual(focusedWindow, targetWindow) {
                return
            }
            try? await Task.sleep(nanoseconds: frontmostPollNanoseconds)
        }
    }

    private static func isFrontmost(_ processIdentifier: pid_t) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier
    }
}
