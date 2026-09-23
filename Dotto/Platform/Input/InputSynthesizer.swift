import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Posts marked CGEvents to one process and performs Accessibility actions, checking the abort signal before every
/// input. The user's real cursor is never moved. The one exception to per-process posting is the focused keyboard
/// path at the end, which only NativeOpenPanelDriver uses (AGENTS.md invariant 3c).
final class InputSynthesizer {
    private static let unicodeTypingChunkLength = 16
    private static let unicodeTypingChunkDelayNanoseconds: UInt64 = 8_000_000
    // Raw CGEventField numbers without a public name: the target process and the window number.
    private static let targetProcessEventField = CGEventField(rawValue: 40)!
    private static let windowNumberEventField = CGEventField(rawValue: 51)!

    private let keyboardLayoutCharacterTable = KeyboardLayoutCharacterTable()
    private let syntheticEventSource: CGEventSource?
    private let windowServerBridge: PrivateWindowServerBridge

    init(windowServerBridge: PrivateWindowServerBridge) {
        self.windowServerBridge = windowServerBridge
        syntheticEventSource = CGEventSource(stateID: .privateState)
        // Without this, macOS briefly suppresses the user's real mouse/keyboard after each synthetic event.
        syntheticEventSource?.localEventsSuppressionInterval = 0
    }

    /// Named keys use fixed key codes; single characters (letters, digits, punctuation) are looked up in the
    /// current keyboard layout, including any shift/option the layout needs to produce that character.
    func resolveKeyStroke(forKeyName keyName: String) -> LayoutKeyStroke? {
        let normalizedKeyName = keyName.lowercased()
        if let namedKeyVirtualKeyCode = VirtualKeyCodeTables.namedKeyVirtualKeyCodesByKeyName[normalizedKeyName] {
            return LayoutKeyStroke(virtualKeyCode: CGKeyCode(namedKeyVirtualKeyCode), requiredModifiers: [])
        }
        guard normalizedKeyName.count == 1, let keyCharacter = normalizedKeyName.first else { return nil }
        if keyboardLayoutCharacterTable.hasLayoutData {
            return keyboardLayoutCharacterTable.keyStroke(producing: keyCharacter)
        }
        return VirtualKeyCodeTables.usANSIVirtualKeyCodesByCharacter[keyCharacter].map {
            LayoutKeyStroke(virtualKeyCode: CGKeyCode($0), requiredModifiers: [])
        }
    }

    /// The press_key name for a physical key, as teach mode records it: canonical names for named keys, else the
    /// character the key types on the current layout without modifiers.
    func keyName(forVirtualKeyCode virtualKeyCode: CGKeyCode) -> String? {
        let canonicalNamedKeys = VirtualKeyCodeTables.namedKeyVirtualKeyCodesByKeyName
            .filter { !VirtualKeyCodeTables.namedKeyAliases.contains($0.key) }
        if let namedKey = canonicalNamedKeys.first(where: { $0.value == Int(virtualKeyCode) }) { return namedKey.key }
        if let layoutCharacter = keyboardLayoutCharacterTable.unmodifiedCharacter(forVirtualKeyCode: virtualKeyCode) {
            return String(layoutCharacter)
        }
        return VirtualKeyCodeTables.usANSIVirtualKeyCodesByCharacter.first { $0.value == Int(virtualKeyCode) }.map { String($0.key) }
    }

    // MARK: - Keyboard

    func postKeyPress(virtualKeyCode: CGKeyCode, modifiers: [AgentKeyModifier], to targetProcessPin: TargetProcessPin,
                      route: KeyboardEventRoute, abortSignal: TaskAbortSignal) throws {
        for isKeyDown in [true, false] {
            let keyEvent = makeKeyEvent(virtualKeyCode: virtualKeyCode, isKeyDown: isKeyDown,
                                        modifierFlags: Self.modifierFlags(for: modifiers))
            try post(keyEvent, to: targetProcessPin, route: route, abortSignal: abortSignal, isReleaseOfPress: !isKeyDown)
        }
    }

    /// `verifyTypingTargetBeforeChunk` runs before every chunk and right after every Return, because focus can
    /// move mid-text (a Return submitting a form, the user clicking in the app) and typing must stop there.
    func typeUnicodeText(_ text: String, to targetProcessPin: TargetProcessPin, route: KeyboardEventRoute,
                         abortSignal: TaskAbortSignal, verifyTypingTargetBeforeChunk: () async throws -> Void) async throws {
        // Newlines are sent as real Return presses; many text views ignore "\n" delivered as a Unicode string.
        let textLines = text.components(separatedBy: "\n")
        for (lineIndex, lineText) in textLines.enumerated() {
            if lineIndex > 0 {
                try postKeyPress(virtualKeyCode: CGKeyCode(kVK_Return), modifiers: [], to: targetProcessPin, route: route,
                                 abortSignal: abortSignal)
                try await verifyTypingTargetBeforeChunk()
            }
            for chunkCodeUnits in Self.unicodeTypingChunks(of: lineText) {
                try await verifyTypingTargetBeforeChunk()
                for isKeyDown in [true, false] {
                    try post(makeUnicodeTextEvent(chunkCodeUnits, isKeyDown: isKeyDown), to: targetProcessPin, route: route,
                             abortSignal: abortSignal, isReleaseOfPress: !isKeyDown)
                }
                try await Task.sleep(nanoseconds: Self.unicodeTypingChunkDelayNanoseconds)
            }
        }
    }

    // MARK: - Pointer (foreground assist only)

    /// Only called inside the foreground assist, while the target app is frontmost: the events go to the target
    /// process with its window and the window-relative point stamped on them, so the user's real cursor never moves.
    /// Aborts are checked before every move, down and wheel event, never between a down and its up (invariant 10).
    /// `verifyBeforeEachPressOrMove` runs before every event except a release, which always follows its press.
    func postPointerEvents(_ pointerEventSteps: [ProcessPointerEventStep], to targetProcessPin: TargetProcessPin,
                           windowFrameInTopLeftGlobalPoints: CGRect, abortSignal: TaskAbortSignal,
                           verifyBeforeEachPressOrMove: () async throws -> Void = {}) async throws {
        guard windowServerBridge.canSetEventWindowLocation else {
            throw ActionBackendError.foregroundAssistFailed("this Mac doesn't let Dotto click at a point in another app")
        }
        for pointerEventStep in pointerEventSteps {
            let stepIsRelease = pointerEventStep.kind == .leftMouseUp || pointerEventStep.kind == .rightMouseUp
            if !stepIsRelease { try await verifyBeforeEachPressOrMove() }
            let pointerEvent = makePointerEvent(for: pointerEventStep)
            stampWindowFields(on: pointerEvent, targetProcessPin: targetProcessPin)
            if let pointerEvent {
                let windowRelativePoint = CGPoint(x: pointerEventStep.locationInTopLeftGlobalPoints.x - windowFrameInTopLeftGlobalPoints.minX,
                                                  y: pointerEventStep.locationInTopLeftGlobalPoints.y - windowFrameInTopLeftGlobalPoints.minY)
                windowServerBridge.setWindowLocation(windowRelativePoint, on: pointerEvent)
            }
            try post(pointerEvent, to: targetProcessPin, route: .processEvents, abortSignal: abortSignal,
                     isReleaseOfPress: stepIsRelease)
            if pointerEventStep.delayAfterMilliseconds > 0 {
                // A plain sleep: a cancelled sleep between a down and its up must not skip the up.
                usleep(UInt32(pointerEventStep.delayAfterMilliseconds * 1000))
            }
        }
    }

    /// Per-process pointer events carry no hit test, so the window they belong to is written into them.
    private func stampWindowFields(on pointerEvent: CGEvent?, targetProcessPin: TargetProcessPin) {
        guard let pointerEvent, let windowIdentifier = targetProcessPin.windowIdentifier else { return }
        pointerEvent.setIntegerValueField(Self.windowNumberEventField, value: Int64(windowIdentifier))
        pointerEvent.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(windowIdentifier))
        pointerEvent.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(windowIdentifier))
    }

    // MARK: - Accessibility

    func performAccessibilityAction(_ actionName: String, on accessibilityElement: AXUIElement, abortSignal: TaskAbortSignal) throws {
        try abortSignal.throwIfAborted()
        let actionResult = AXUIElementPerformAction(accessibilityElement, actionName as CFString)
        guard actionResult == .success else {
            throw ActionBackendError.accessibilityCallFailed("\(actionName) failed (AXError \(actionResult.rawValue)).")
        }
    }

    /// Like performAccessibilityAction, but tells a refusal apart from an app that didn't answer. An app that runs a
    /// modal loop (a dialog or sheet opened by the press itself) answers only after the loop ends, so the call times
    /// out even though the press acted; trying another tier then would press twice.
    func attemptAccessibilityAction(_ actionName: String, on accessibilityElement: AXUIElement,
                                    abortSignal: TaskAbortSignal) throws -> AccessibilityActionAttemptResult {
        try abortSignal.throwIfAborted()
        let actionResult = AXUIElementPerformAction(accessibilityElement, actionName as CFString)
        switch actionResult {
        case .success:
            return .performed
        case .cannotComplete, .failure:
            return .mayHaveActed(actionResult)
        default:
            return .refused(actionResult)
        }
    }

    func setAccessibilityValue(_ newValue: String, on accessibilityElement: AXUIElement, abortSignal: TaskAbortSignal) throws {
        try abortSignal.throwIfAborted()
        let setResult = AXUIElementSetAttributeValue(accessibilityElement, kAXValueAttribute as CFString, newValue as CFString)
        guard setResult == .success else {
            throw ActionBackendError.accessibilityCallFailed("Setting the value failed (AXError \(setResult.rawValue)).")
        }
    }

    /// Selecting the whole value lets the typed text replace it without sending cmd+A, which some apps bind to
    /// something else. Returns false when the element has no settable selection range.
    func selectEntireText(of accessibilityElement: AXUIElement, textLengthInUTF16CodeUnits: Int,
                          abortSignal: TaskAbortSignal) throws -> Bool {
        try abortSignal.throwIfAborted()
        var entireTextRange = CFRange(location: 0, length: textLengthInUTF16CodeUnits)
        guard let entireTextRangeValue = AXValueCreate(.cfRange, &entireTextRange) else { return false }
        let selectResult = AXUIElementSetAttributeValue(accessibilityElement, kAXSelectedTextRangeAttribute as CFString,
                                                        entireTextRangeValue)
        return selectResult == .success
    }

    func focusAccessibilityElement(_ accessibilityElement: AXUIElement, abortSignal: TaskAbortSignal) throws {
        try abortSignal.throwIfAborted()
        let focusResult = AXUIElementSetAttributeValue(accessibilityElement, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        guard focusResult == .success else {
            throw ActionBackendError.accessibilityCallFailed("Focusing the element failed (AXError \(focusResult.rawValue)).")
        }
    }

    /// Inserts at the element's current selection, which setting AXSelectedTextRange positioned beforehand. Works on
    /// a background app without keyboard focus.
    func setSelectedText(_ insertedText: String, on accessibilityElement: AXUIElement, abortSignal: TaskAbortSignal) throws {
        try abortSignal.throwIfAborted()
        let insertResult = AXUIElementSetAttributeValue(accessibilityElement, kAXSelectedTextAttribute as CFString,
                                                        insertedText as CFString)
        guard insertResult == .success else {
            throw ActionBackendError.accessibilityCallFailed("Inserting the text failed (AXError \(insertResult.rawValue)).")
        }
    }

    // MARK: - Focused keyboard (the upload assist only)

    /// Real keyboard events at the session tap: they go to whichever window is key, not to a pinned process. Only
    /// posted inside a user-approved upload assist, right after FocusedKeyboardInputGuard found the target's open
    /// panel key and the user idle.
    func postFocusedKeyPress(virtualKeyCode: CGKeyCode, modifiers: [AgentKeyModifier], abortSignal: TaskAbortSignal) throws {
        for isKeyDown in [true, false] {
            let keyEvent = makeKeyEvent(virtualKeyCode: virtualKeyCode, isKeyDown: isKeyDown,
                                        modifierFlags: Self.modifierFlags(for: modifiers))
            try postFocused(keyEvent, abortSignal: abortSignal, isReleaseOfPress: !isKeyDown)
        }
    }

    /// Unicode chunks at the session tap; `verifyFocusedTargetBeforeChunk` re-runs the guard before every chunk.
    func typeFocusedUnicodeText(_ text: String, abortSignal: TaskAbortSignal,
                                verifyFocusedTargetBeforeChunk: () async throws -> Void) async throws {
        for chunkCodeUnits in Self.unicodeTypingChunks(of: text) {
            try await verifyFocusedTargetBeforeChunk()
            for isKeyDown in [true, false] {
                try postFocused(makeUnicodeTextEvent(chunkCodeUnits, isKeyDown: isKeyDown), abortSignal: abortSignal,
                                isReleaseOfPress: !isKeyDown)
            }
            try await Task.sleep(nanoseconds: Self.unicodeTypingChunkDelayNanoseconds)
        }
    }

    // MARK: - Posting

    /// Aborts are checked before each down event but never between a down and its up, so a Stop mid-press can't
    /// leave a mouse button or key stuck down in the target app.
    private func post(_ syntheticEvent: CGEvent?, to targetProcessPin: TargetProcessPin, route: KeyboardEventRoute,
                      abortSignal: TaskAbortSignal, isReleaseOfPress: Bool) throws {
        if !isReleaseOfPress { try abortSignal.throwIfAborted() }
        let markedEvent = try Self.markedAsSynthetic(syntheticEvent)
        markedEvent.setIntegerValueField(Self.targetProcessEventField, value: Int64(targetProcessPin.processIdentifier))
        switch route {
        case .processEvents:
            markedEvent.postToPid(targetProcessPin.processIdentifier)
        case .windowServerAuthenticated:
            guard windowServerBridge.postEvent(markedEvent, toProcess: targetProcessPin.processIdentifier,
                                               attachingAuthenticationMessage: true) else {
                throw ActionBackendError.inputNotDelivered("the authenticated keyboard path isn't available",
                                                           foregroundAssistMayHelp: true)
            }
        }
    }

    /// The focused path stays apart from `post`: it has no pin and posts at the session tap. The abort rule is the same.
    private func postFocused(_ syntheticEvent: CGEvent?, abortSignal: TaskAbortSignal, isReleaseOfPress: Bool) throws {
        if !isReleaseOfPress { try abortSignal.throwIfAborted() }
        try Self.markedAsSynthetic(syntheticEvent).post(tap: .cgSessionEventTap)
    }

    // MARK: - Event builders

    /// Marked like every other synthetic event, so UserInputObserver never mistakes Dotto's input for the user's.
    private static func markedAsSynthetic(_ syntheticEvent: CGEvent?) throws -> CGEvent {
        guard let syntheticEvent else {
            throw ActionBackendError.accessibilityCallFailed("Could not create an input event.")
        }
        syntheticEvent.setIntegerValueField(.eventSourceUserData, value: SyntheticInputMarker.eventSourceUserDataValue)
        return syntheticEvent
    }

    private static func modifierFlags(for modifiers: [AgentKeyModifier]) -> CGEventFlags {
        var modifierFlags = CGEventFlags()
        for modifier in modifiers {
            switch modifier {
            case .command: modifierFlags.insert(.maskCommand)
            case .option: modifierFlags.insert(.maskAlternate)
            case .control: modifierFlags.insert(.maskControl)
            case .shift: modifierFlags.insert(.maskShift)
            }
        }
        return modifierFlags
    }

    /// Chunks of UTF-16 code units, never splitting a surrogate pair across two events (the emoji would arrive as two
    /// garbage characters).
    private static func unicodeTypingChunks(of text: String) -> [[UniChar]] {
        let utf16CodeUnits = Array(text.utf16)
        var chunks: [[UniChar]] = []
        var chunkStartIndex = 0
        while chunkStartIndex < utf16CodeUnits.count {
            var chunkEndIndex = min(chunkStartIndex + unicodeTypingChunkLength, utf16CodeUnits.count)
            if chunkEndIndex < utf16CodeUnits.count, UTF16.isLeadSurrogate(utf16CodeUnits[chunkEndIndex - 1]) {
                chunkEndIndex -= 1
            }
            chunks.append(Array(utf16CodeUnits[chunkStartIndex..<chunkEndIndex]))
            chunkStartIndex = chunkEndIndex
        }
        return chunks
    }

    /// The flags are set even when empty, so a modifier the user is holding in another app never leaks into this key.
    private func makeKeyEvent(virtualKeyCode: CGKeyCode, isKeyDown: Bool, modifierFlags: CGEventFlags) -> CGEvent? {
        let keyEvent = CGEvent(keyboardEventSource: syntheticEventSource, virtualKey: virtualKeyCode, keyDown: isKeyDown)
        keyEvent?.flags = modifierFlags
        return keyEvent
    }

    private func makeUnicodeTextEvent(_ chunkCodeUnits: [UniChar], isKeyDown: Bool) -> CGEvent? {
        let keyEvent = makeKeyEvent(virtualKeyCode: 0, isKeyDown: isKeyDown, modifierFlags: [])
        chunkCodeUnits.withUnsafeBufferPointer { chunkBuffer in
            keyEvent?.keyboardSetUnicodeString(stringLength: chunkBuffer.count, unicodeString: chunkBuffer.baseAddress)
        }
        return keyEvent
    }

    private func makePointerEvent(for pointerEventStep: ProcessPointerEventStep) -> CGEvent? {
        let pointerEvent: CGEvent?
        switch pointerEventStep.kind {
        case .scrollWheel(let verticalLines, let horizontalLines):
            pointerEvent = CGEvent(scrollWheelEvent2Source: syntheticEventSource, units: .line, wheelCount: 2,
                                   wheel1: verticalLines, wheel2: horizontalLines, wheel3: 0)
            pointerEvent?.location = pointerEventStep.locationInTopLeftGlobalPoints
        case .mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp:
            let (mouseEventType, mouseButton): (CGEventType, CGMouseButton) = switch pointerEventStep.kind {
            case .leftMouseDown: (.leftMouseDown, .left)
            case .leftMouseUp: (.leftMouseUp, .left)
            case .rightMouseDown: (.rightMouseDown, .right)
            case .rightMouseUp: (.rightMouseUp, .right)
            default: (.mouseMoved, .left)
            }
            pointerEvent = CGEvent(mouseEventSource: syntheticEventSource, mouseType: mouseEventType,
                                   mouseCursorPosition: pointerEventStep.locationInTopLeftGlobalPoints, mouseButton: mouseButton)
            pointerEvent?.setIntegerValueField(.mouseEventClickState, value: pointerEventStep.clickState)
        }
        pointerEvent?.flags = []
        return pointerEvent
    }
}
