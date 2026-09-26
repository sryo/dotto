import AppKit

/// Reports the user's real mouse and keyboard input while a task executes or a demonstration is recorded.
/// A listen-only tap, because a listen-only tap can never hold up the system pointer while the main thread is
/// busy. Each running task and each recording holds a lease (`InputObservationLeases`); the one tap runs while any is
/// held, so one task ending never switches off takeover detection or the real-input count for another.
@MainActor final class UserInputObserver {
    var onUserInputObserved: ((ObservedUserInputEvent) -> Void)?
    nonisolated let realUserInputCounter = RealUserInputCounter()

    private var observationLeases = InputObservationLeases()
    /// What the tap that is running was created to see.
    private var runningTapIncludesPointerMoves = false
    private var observationEventTap: CFMachPort?
    private var observationRunLoopSource: CFRunLoopSource?
    private var thisAppPointerEventMonitor: Any?
    /// Where and when AppKit handed a mouse-down or scroll to one of Dotto's own windows, newest last.
    private var recentPointerEventsDeliveredToThisApp: [(topLeftGlobalLocation: CGPoint, timestampSeconds: TimeInterval)] = []
    private static let maximumRememberedPointerEventsDeliveredToThisApp = 8
    /// The tap and AppKit deliver the same event through two run loop sources, a few milliseconds to a busy main
    /// thread apart.
    private static let pointerEventMatchingWindowSeconds: TimeInterval = 1.0
    private static let pointerEventMatchingTolerancePoints: CGFloat = 0.5

    /// Pointer moves never pause a run, so they are only observed while a demonstration is being recorded.
    @discardableResult func startObserving(holderIdentifier: String, includingPointerMoves: Bool = false) -> Bool {
        observationLeases.take(holderIdentifier: holderIdentifier, includingPointerMoves: includingPointerMoves)
        return applyObservationRequirement()
    }

    func stopObserving(holderIdentifier: String) {
        observationLeases.end(holderIdentifier: holderIdentifier)
        applyObservationRequirement()
    }

    /// At quit.
    func stopObservingForEveryHolder() {
        observationLeases.endAll()
        applyObservationRequirement()
    }

    @discardableResult private func applyObservationRequirement() -> Bool {
        switch observationLeases.requirement {
        case .none:
            stopTap()
            return true
        case .clicksScrollsAndKeys:
            return runTap(includingPointerMoves: false)
        case .includingPointerMoves:
            return runTap(includingPointerMoves: true)
        }
    }

    /// A tap that sees more than it needs is replaced, and one that sees less is recreated with the wider mask.
    private func runTap(includingPointerMoves: Bool) -> Bool {
        if observationEventTap != nil {
            if runningTapIncludesPointerMoves == includingPointerMoves { return true }
            stopTap()
        }
        return startTap(includingPointerMoves: includingPointerMoves)
    }

    private func startTap(includingPointerMoves: Bool) -> Bool {
        let observationTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let userInputObserver = Unmanaged<UserInputObserver>.fromOpaque(userInfo).takeUnretainedValue()
            let observedEvent = UserInputObserver.makeObservedEvent(eventType: eventType, event: event)
            // The run loop source is on the main run loop, so this callback runs on the main thread.
            MainActor.assumeIsolated {
                userInputObserver.handleTapEvent(eventType: eventType, observedEvent: observedEvent)
            }
            return Unmanaged.passUnretained(event)
        }

        var observedEventTypes: [CGEventType] = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown]
        if includingPointerMoves {
            observedEventTypes += [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        }
        let observedEventMask = observedEventTypes.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let createdEventTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                                      eventsOfInterest: observedEventMask, callback: observationTapCallback,
                                                      userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        guard let createdRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, createdEventTap, 0) else {
            CFMachPortInvalidate(createdEventTap)
            return false
        }
        observationEventTap = createdEventTap
        observationRunLoopSource = createdRunLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), createdRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: createdEventTap, enable: true)
        runningTapIncludesPointerMoves = includingPointerMoves
        realUserInputCounter.setObserving(true)
        startRecordingPointerEventsDeliveredToThisApp()
        return true
    }

    /// Whether the window server delivered this mouse-down or scroll to one of Dotto's own windows. That routing
    /// already skips transparent margins, and unlike a hit test made when the tap's copy is handled, it doesn't
    /// depend on how the panel looks by then: after a click on Resume the pill has already lost its button.
    func pointerEventWasDeliveredToThisApp(_ observedEvent: ObservedUserInputEvent) -> Bool {
        switch observedEvent.kind {
        case .mouseDown, .scrollWheel: break
        case .mouseMoved, .keyDown: return false
        }
        return recentPointerEventsDeliveredToThisApp.contains { deliveredPointerEvent in
            abs(deliveredPointerEvent.timestampSeconds - observedEvent.timestampSeconds) <= Self.pointerEventMatchingWindowSeconds
                && abs(deliveredPointerEvent.topLeftGlobalLocation.x - observedEvent.topLeftGlobalLocation.x) <= Self.pointerEventMatchingTolerancePoints
                && abs(deliveredPointerEvent.topLeftGlobalLocation.y - observedEvent.topLeftGlobalLocation.y) <= Self.pointerEventMatchingTolerancePoints
        }
    }

    private func startRecordingPointerEventsDeliveredToThisApp() {
        guard thisAppPointerEventMonitor == nil else { return }
        thisAppPointerEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] deliveredEvent in
            // Local monitors run on the main thread, inside AppKit's event dispatch.
            MainActor.assumeIsolated {
                self?.recordPointerEventDeliveredToThisApp(deliveredEvent)
            }
            return deliveredEvent
        }
    }

    private func recordPointerEventDeliveredToThisApp(_ deliveredEvent: NSEvent) {
        guard let topLeftGlobalLocation = deliveredEvent.cgEvent?.location else { return }
        recentPointerEventsDeliveredToThisApp.append((topLeftGlobalLocation, Self.currentMonotonicTimestampSeconds()))
        if recentPointerEventsDeliveredToThisApp.count > Self.maximumRememberedPointerEventsDeliveredToThisApp {
            recentPointerEventsDeliveredToThisApp.removeFirst()
        }
    }

    private func stopTap() {
        realUserInputCounter.setObserving(false)
        if let thisAppPointerEventMonitor {
            NSEvent.removeMonitor(thisAppPointerEventMonitor)
            self.thisAppPointerEventMonitor = nil
        }
        recentPointerEventsDeliveredToThisApp.removeAll()
        if let observationRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), observationRunLoopSource, .commonModes)
            self.observationRunLoopSource = nil
        }
        if let observationEventTap {
            CGEvent.tapEnable(tap: observationEventTap, enable: false)
            CFMachPortInvalidate(observationEventTap)
            self.observationEventTap = nil
        }
    }

    private func handleTapEvent(eventType: CGEventType, observedEvent: ObservedUserInputEvent?) {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            // Input may have gone unseen while the tap was off, so it counts as the user's.
            realUserInputCounter.recordRealUserInput()
            if let observationEventTap { CGEvent.tapEnable(tap: observationEventTap, enable: true) }
            return
        }
        guard let observedEvent else { return }
        if !observedEvent.isSynthesizedByThisApp, observedEvent.kind != .mouseMoved {
            realUserInputCounter.recordRealUserInput()
        }
        onUserInputObserved?(observedEvent)
    }

    /// Seconds on the same monotonic clock as ObservedUserInputEvent.timestampSeconds, for grace windows the
    /// controller opens itself (for example after a click on Dotto's own panel).
    nonisolated static func currentMonotonicTimestampSeconds() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
    }

    /// Typed characters are deliberately not captured: nothing downstream needs them, and they could be a password.
    nonisolated private static func makeObservedEvent(eventType: CGEventType, event: CGEvent) -> ObservedUserInputEvent? {
        let observedKind: ObservedUserInputEvent.Kind
        var observedWindowOwnerProcessIdentifier: Int32?
        switch eventType {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            observedKind = .mouseMoved
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            observedKind = .mouseDown(isRightButton: eventType == .rightMouseDown,
                                      clickCount: Int(event.getIntegerValueField(.mouseEventClickState)))
            observedWindowOwnerProcessIdentifier = windowOwnerProcessIdentifier(of: event)
        case .scrollWheel:
            observedKind = .scrollWheel
            observedWindowOwnerProcessIdentifier = windowOwnerProcessIdentifier(of: event)
        case .keyDown:
            let modifierFlagPairs: [(CGEventFlags, AgentKeyModifier)] = [(.maskCommand, .command), (.maskAlternate, .option),
                                                                          (.maskControl, .control), (.maskShift, .shift)]
            let pressedModifiers = modifierFlagPairs.filter { event.flags.contains($0.0) }.map(\.1)
            observedKind = .keyDown(virtualKeyCode: event.getIntegerValueField(.keyboardEventKeycode),
                                    modifiers: pressedModifiers, characters: nil)
        default:
            return nil
        }
        // CGEvent.timestamp is documented as nanoseconds but is mach_absolute_time ticks on Apple Silicon (1 tick =
        // 41.67 ns), which would stretch every grace window 24x. Stamping at callback time on CLOCK_UPTIME_RAW gives
        // real seconds; the listen-only tap delivers within milliseconds, far below the 0.4 s and 0.5 s windows.
        let callbackTimestampSeconds = currentMonotonicTimestampSeconds()
        // The user-data marker alone can be copied by any process that posts events; the window server fills in the
        // source pid, so both must match for input to count as Dotto's own.
        let isMarkedAsSynthetic = event.getIntegerValueField(.eventSourceUserData) == SyntheticInputMarker.eventSourceUserDataValue
        let wasPostedByThisProcess = event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid())
        return ObservedUserInputEvent(
            kind: observedKind, topLeftGlobalLocation: event.location,
            timestampSeconds: callbackTimestampSeconds,
            isSynthesizedByThisApp: isMarkedAsSynthetic && wasPostedByThisProcess,
            frontmostProcessIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            windowOwnerProcessIdentifier: observedWindowOwnerProcessIdentifier)
    }

    /// The window server stamps real mouse events with the window that will handle them, which skips click-through
    /// overlays (window managers, screen tools); its owner decides whether the user touched the target app. The plain
    /// window under the pointer, then the front-to-back hit test, cover events without that stamp.
    nonisolated private static func windowOwnerProcessIdentifier(of event: CGEvent) -> Int32? {
        for windowField in [CGEventField.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, .mouseEventWindowUnderMousePointer] {
            let stampedWindowIdentifier = CGWindowID(truncatingIfNeeded: event.getIntegerValueField(windowField))
            if stampedWindowIdentifier != 0,
               let stampedWindowInfo = WindowListEntryClassification.windowListEntry(ofWindowWithIdentifier: stampedWindowIdentifier),
               let windowOwnerProcessIdentifier = WindowListEntryClassification.ownerProcessIdentifier(of: stampedWindowInfo) {
                return windowOwnerProcessIdentifier
            }
        }
        return WindowListEntryClassification.topmostWindowOwnerProcessIdentifier(atTopLeftGlobalPoint: event.location)
    }
}
