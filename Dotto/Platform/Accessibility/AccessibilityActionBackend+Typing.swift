import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Text Dotto set as a field's AXValue, kept until Return commits it so the commit can be checked.
struct PendingAccessibilityValueCommit {
    var fieldElement: AXUIElement
    var fieldDescription: String
    var typedText: String
    var valueBeforeTyping: String?
    var replacedExistingText: Bool
}

extension AccessibilityActionBackend {
    private static let typingResultPollIntervalNanoseconds: UInt64 = 100_000_000
    private static let typingResultPollCount = 6
    private static let focusSettleNanoseconds: UInt64 = 150_000_000
    private static let commitSettleNanoseconds: UInt64 = 300_000_000
    private static let commitPollIntervalNanoseconds: UInt64 = 150_000_000
    private static let commitPollCount = 6
    /// Enough for a Finder list or a form; a web page larger than this is not searched to the end.
    private static let commitSearchMaximumNodeCount = 3000

    func typeText(_ text: String, intoElementWithIdentifier elementIdentifier: String?, replaceExistingText: Bool,
                  pressReturnAfter: Bool, context: ActionRunContext) async throws -> ActionOutcome {
        var targetElement: AXUIElement?
        var elementTraits: ElementInputTraits?
        let targetDescription: String
        if let elementIdentifier {
            let (accessibilityElement, node) = try resolveTargetApplicationElement(elementIdentifier, context: context)
            if node?.isSecureTextField == true || elementReader.isSecureTextField(accessibilityElement) {
                throw ActionBackendError.secureFieldTypingDenied
            }
            targetElement = accessibilityElement
            elementTraits = elementReader.elementInputTraits(of: accessibilityElement)
            targetDescription = describe(node, elementIdentifier: elementIdentifier)
        } else {
            targetElement = elementReader.applicationFocusedElement(of: context.targetApplication)
            targetDescription = "the focused element"
        }
        // In a single-line field a newline is a Return press through a keyboard tier, never part of an AX value. A
        // multi-line text area (a document, a note) holds newlines as text, and its value can be set in the background.
        let targetIsMultilineTextArea = targetElement.flatMap(AccessibilityElementReader.role(of:)) == (kAXTextAreaRole as String)
        let deliveryTiers = planTiers(for: .typeText, elementTraits: elementTraits, context: context)
            .filter { !(text.contains("\n") && !targetIsMultilineTextArea && $0 == .accessibilityValue) }
        guard !deliveryTiers.isEmpty else {
            throw ActionBackendError.inputNotDelivered("typing into \(targetDescription) only works with the app in front.",
                                                       foregroundAssistMayHelp: true)
        }
        try await flyCursor(toCenterOf: targetElement.flatMap(AccessibilityElementReader.frameInTopLeftGlobalPoints),
                            actionKind: .typing, context: context)
        if elementIdentifier != nil, let targetElement {
            // AXFocused works on a background app; keys then go to that element through the app's own focus.
            try await ensureReadyForInput(context)
            if !elementHasApplicationFocus(targetElement, context: context) {
                try? inputSynthesizer.focusAccessibilityElement(targetElement, abortSignal: context.abortSignal)
                // Web content moves its own focus a moment after AX reports it; keys sent sooner go to the old element.
                try await Task.sleep(nanoseconds: Self.focusSettleNanoseconds)
            }
        }
        let valueBeforeClearing = targetElement.flatMap { elementReader.untruncatedStringValue(of: $0) }
        if replaceExistingText {
            try await selectOrClearExistingText(in: targetElement, context: context)
        }
        // Read after clearing so an AXValue="" clear followed by ignored keystrokes still counts as "no change".
        let valueBeforeTyping = targetElement.flatMap { elementReader.untruncatedStringValue(of: $0) }

        let expectedValueAfterTyping = replaceExistingText ? text : (valueBeforeTyping ?? "") + text
        // Editors that draw their own text (Zed, terminals, canvas apps) show no value to Accessibility, so what the
        // keys did can only be seen in the window's pixels.
        let focusedElementHidesItsText = targetElement != nil && valueBeforeTyping == nil
        var windowThumbnailBeforeTyping: WindowImageThumbnail?
        if focusedElementHidesItsText, let taskWindowReference = context.taskWindow?.reference {
            windowThumbnailBeforeTyping = await windowCapturer.captureThumbnail(of: taskWindowReference)
        }
        var deliveredTier: InputDeliveryTier?
        var deliveredValueMismatchNote = ""
        for deliveryTier in deliveryTiers where deliveredTier == nil {
            try await ensureReadyForInput(context)
            switch deliveryTier {
            case .accessibilityValue:
                guard let targetElement else { continue }
                if try await setValueByAccessibility(text, on: targetElement, valueBeforeTyping: valueBeforeTyping,
                                                     replaceExistingText: replaceExistingText, context: context) {
                    deliveredTier = .accessibilityValue
                }
            case .processKeyboardEvents, .windowServerKeyboardEvents:
                guard let keyboardRoute = InputTierPlanner.keyboardRoute(for: deliveryTier) else { continue }
                if let targetElement, elementIdentifier != nil, !elementHasApplicationFocus(targetElement, context: context) {
                    continue
                }
                try await verifyKeyboardTargetIsSafe(context)
                try await inputSynthesizer.typeUnicodeText(text, to: makeTargetProcessPin(context), route: keyboardRoute,
                                                           abortSignal: context.abortSignal) {
                    try await self.verifyKeyboardTargetIsSafe(context)
                }
                // Typed newlines were real Return presses that may have submitted or cleared the field, so the text
                // counts as delivered and is never applied a second time.
                let deliveryIsUnverifiable = text.contains("\n") || text.isEmpty || targetElement == nil
                let valueChanged: Bool
                if deliveryIsUnverifiable {
                    valueChanged = true
                } else if focusedElementHidesItsText, let windowThumbnailBeforeTyping {
                    valueChanged = try await windowImageChanged(since: windowThumbnailBeforeTyping, context: context)
                } else {
                    valueChanged = try await valueChangedAfterTyping(targetElement, valueBeforeTyping: valueBeforeTyping, context: context)
                }
                if valueChanged { deliveredTier = deliveryTier }
            case .accessibilityAction, .processPointerEvents:
                continue
            }
            // A tier that left the field different from before may have delivered part of the text (an AX value the
            // app rewrote, keys it applied halfway). Typing again through the next tier would enter the text twice, so
            // any change at all counts as delivered, and the model is told what the field now holds.
            if deliveredTier == nil, let targetElement, !text.isEmpty {
                let valueAfterTier = elementReader.untruncatedStringValue(of: targetElement)
                if valueAfterTier != valueBeforeTyping {
                    deliveredTier = deliveryTier
                }
            }
        }
        if deliveredTier != nil, let targetElement, !text.contains("\n"), !text.isEmpty,
           let valueAfterTyping = elementReader.untruncatedStringValue(of: targetElement),
           valueAfterTyping != expectedValueAfterTyping, !(replaceExistingText == false && valueAfterTyping.contains(text)) {
            deliveredValueMismatchNote = ". Note: the field now reads “\(valueAfterTyping.prefix(80))”, which is not exactly "
                + "what was typed; read the UI to check before typing again, and don't retype the whole text"
        }
        // Clearing works in the background but keys may not land there, and text with Returns can't be verified as
        // it goes: a replace that leaves the field empty put back what was there instead of losing the user's text.
        if replaceExistingText, !text.isEmpty, let targetElement, let valueBeforeClearing, !valueBeforeClearing.isEmpty,
           elementReader.untruncatedStringValue(of: targetElement)?.isEmpty == true {
            try? inputSynthesizer.setAccessibilityValue(valueBeforeClearing, on: targetElement, abortSignal: context.abortSignal)
            throw ActionBackendError.inputNotDelivered(
                "the text didn't arrive in \(targetDescription), so its previous text was put back.",
                foregroundAssistMayHelp: !context.targetIsFrontmost)
        }
        guard let deliveredTier else {
            throw ActionBackendError.inputNotDelivered("the text didn't arrive in \(targetDescription).",
                                                       foregroundAssistMayHelp: !context.targetIsFrontmost)
        }

        var typingDescription = "typed “\(text.prefix(80))” into \(targetDescription)"
        if deliveredTier == .accessibilityValue { typingDescription += " (set its value directly)" }
        let accessibilityValueCommit = (deliveredTier == .accessibilityValue ? targetElement : nil).map { fieldElement in
            PendingAccessibilityValueCommit(fieldElement: fieldElement, fieldDescription: targetDescription, typedText: text,
                                            valueBeforeTyping: valueBeforeTyping, replacedExistingText: replaceExistingText)
        }
        if pressReturnAfter {
            let (returnDescription, returnWasPressed) = try await pressReturnAfterTyping(context)
            typingDescription += returnDescription
            if returnWasPressed, let accessibilityValueCommit {
                try await throwIfAccessibilityValueWasNotKept(accessibilityValueCommit, retryingThisActionMayHelp: true, context: context)
            }
        } else {
            pendingAccessibilityValueCommit = accessibilityValueCommit
        }
        typingDescription += deliveredValueMismatchNote
        return ActionOutcome(descriptionForModel: typingDescription, deliveryTier: deliveredTier)
    }

    /// The text is already in place, so a Return that can't be delivered is reported instead of retrying the whole
    /// action in front, which would type the text twice.
    private func pressReturnAfterTyping(_ context: ActionRunContext) async throws -> (description: String, returnWasPressed: Bool) {
        guard let keyboardTier = planTiers(for: .pressKey(hasCommandModifier: false), elementTraits: nil, context: context).first,
              let keyboardRoute = InputTierPlanner.keyboardRoute(for: keyboardTier) else {
            return (". Return was not pressed: it only works with the app in front, so call press_key return next", false)
        }
        try await verifyKeyboardTargetIsSafe(context)
        try inputSynthesizer.postKeyPress(virtualKeyCode: CGKeyCode(kVK_Return), modifiers: [], to: makeTargetProcessPin(context),
                                          route: keyboardRoute, abortSignal: context.abortSignal)
        // Return often moves focus (next form field, a password prompt); tell the model before it types again.
        if let focusProblemAfterReturn = keyboardTargetProblem(context) {
            return (" and pressed return. Note: after Return, \(focusProblemAfterReturn.messageForModel)", true)
        }
        return (" and pressed return", true)
    }

    /// A value set through AX reads back at once, yet some fields commit only what real keys typed. After Return, the
    /// text must still be in the field or, once the field has closed, be shown somewhere in the window. When it isn't,
    /// the app's text goes in as real keys for the rest of the task, and the model is told the text was not kept.
    /// `retryingThisActionMayHelp` is false for a separate press_key Return: pressing it again would commit the old text.
    func throwIfAccessibilityValueWasNotKept(_ accessibilityValueCommit: PendingAccessibilityValueCommit,
                                             retryingThisActionMayHelp: Bool, context: ActionRunContext) async throws {
        try await Task.sleep(nanoseconds: Self.commitSettleNanoseconds)
        var commitVerdict = AccessibilityValueCommitVerdict.keptOrCannotTell
        for _ in 0...Self.commitPollCount {
            try throwIfRunEnded(context)
            commitVerdict = AccessibilityValueCommitCheck.verdict(for: observeCommit(of: accessibilityValueCommit, context: context))
            if commitVerdict == .keptOrCannotTell { return }
            try await Task.sleep(nanoseconds: Self.commitPollIntervalNanoseconds)
        }
        guard case .notKept(let retryWithRealKeysInFieldMayHelp) = commitVerdict else { return }
        accessibilityValueTypingIsUnreliable = true
        let applicationName = context.targetApplication.applicationName
        if retryWithRealKeysInFieldMayHelp && retryingThisActionMayHelp && !context.targetIsFrontmost {
            throw ActionBackendError.inputNotDelivered(
                "\(applicationName) showed the text Dotto set directly in \(accessibilityValueCommit.fieldDescription), but went back "
                    + "to the old text when Return committed it. This field only takes real typing, which needs the app in front.",
                foregroundAssistMayHelp: true)
        }
        throw ActionBackendError.inputNotDelivered(
            "\(applicationName) showed the text Dotto set directly in \(accessibilityValueCommit.fieldDescription), but didn't keep "
                + "it when Return committed it: the new text isn't shown anywhere now. Open the field again (for a file name: "
                + "select the item, then press Return) and type the text again. From now on Dotto types into "
                + "\(applicationName) with real keys, which may need the app in front.",
            foregroundAssistMayHelp: false)
    }

    private func observeCommit(of accessibilityValueCommit: PendingAccessibilityValueCommit,
                               context: ActionRunContext) -> AccessibilityValueCommitObservation {
        let fieldValueAfterReturn = elementReader.untruncatedStringValue(of: accessibilityValueCommit.fieldElement)
        // Only needed once the field has closed, and the walk is the costly part.
        let typedTextIsShownInWindow = fieldValueAfterReturn == nil
            && windowShowsText(accessibilityValueCommit.typedText, context: context)
        return AccessibilityValueCommitObservation(
            typedText: accessibilityValueCommit.typedText, valueBeforeTyping: accessibilityValueCommit.valueBeforeTyping,
            replacedExistingText: accessibilityValueCommit.replacedExistingText, fieldValueAfterReturn: fieldValueAfterReturn,
            fieldStillHasKeyboardFocus: elementHasApplicationFocus(accessibilityValueCommit.fieldElement, context: context),
            typedTextIsShownInWindow: typedTextIsShownInWindow)
    }

    private func windowShowsText(_ typedText: String, context: ActionRunContext) -> Bool {
        guard let windowElement = elementReader.focusedWindowElement(of: context.targetApplication) else { return false }
        let elementShowingTypedText = AccessibilityElementReader.firstElementInSubtree(
            of: windowElement, maximumVisitedNodeCount: Self.commitSearchMaximumNodeCount) { candidateElement in
            AccessibilityElementReader.displayedTexts(of: candidateElement).contains { displayedText in
                AccessibilityValueCommitCheck.elementText(displayedText, showsTypedText: typedText)
            }
        }
        return elementShowingTypedText != nil
    }

    /// Replaces or appends through AX and reads the value back; false when the app ignored it. Web content reports
    /// the new value a moment later, so the read-back is polled.
    private func setValueByAccessibility(_ text: String, on targetElement: AXUIElement, valueBeforeTyping: String?,
                                         replaceExistingText: Bool, context: ActionRunContext) async throws -> Bool {
        let expectedValue = replaceExistingText ? text : (valueBeforeTyping ?? "") + text
        if replaceExistingText || valueBeforeTyping == nil {
            guard (try? inputSynthesizer.setAccessibilityValue(expectedValue, on: targetElement, abortSignal: context.abortSignal)) != nil else {
                return false
            }
        } else if let valueBeforeTyping {
            let endOfTextLength = valueBeforeTyping.utf16.count
            var insertionRange = CFRange(location: endOfTextLength, length: 0)
            let insertionRangeValue = AXValueCreate(.cfRange, &insertionRange)
            let insertedAtEnd = insertionRangeValue.map {
                AXUIElementSetAttributeValue(targetElement, kAXSelectedTextRangeAttribute as CFString, $0) == .success
            } == true && (try? inputSynthesizer.setSelectedText(text, on: targetElement, abortSignal: context.abortSignal)) != nil
            if !insertedAtEnd {
                guard (try? inputSynthesizer.setAccessibilityValue(expectedValue, on: targetElement,
                                                                   abortSignal: context.abortSignal)) != nil else { return false }
            }
        }
        return try await pollTypingResult(context) { self.elementReader.untruncatedStringValue(of: targetElement) == expectedValue }
    }

    /// Apps can apply keystrokes late, so the value is polled for a while before the next tier is tried; falling back
    /// too early would type the text twice.
    private func valueChangedAfterTyping(_ targetElement: AXUIElement?, valueBeforeTyping: String?,
                                         context: ActionRunContext) async throws -> Bool {
        guard let targetElement else { return true }
        return try await pollTypingResult(context) { self.elementReader.untruncatedStringValue(of: targetElement) != valueBeforeTyping }
    }

    private func windowImageChanged(since windowThumbnailBefore: WindowImageThumbnail, context: ActionRunContext) async throws -> Bool {
        guard let taskWindowReference = context.taskWindow?.reference else { return false }
        for _ in 0...Self.typingResultPollCount {
            try await Task.sleep(nanoseconds: Self.typingResultPollIntervalNanoseconds)
            try throwIfRunEnded(context)
            if let windowThumbnailAfter = await windowCapturer.captureThumbnail(of: taskWindowReference),
               windowThumbnailAfter.showsChange(comparedWith: windowThumbnailBefore) {
                return true
            }
        }
        return false
    }

    private func pollTypingResult(_ context: ActionRunContext, until typingResultIsSeen: () -> Bool) async throws -> Bool {
        for _ in 0...Self.typingResultPollCount {
            if typingResultIsSeen() { return true }
            try await Task.sleep(nanoseconds: Self.typingResultPollIntervalNanoseconds)
            try throwIfRunEnded(context)
        }
        return false
    }

    /// Prefers selecting the whole value (typing then replaces it) or setting AXValue to "" over ⌘A, which some apps
    /// rebind. ⌘A itself goes through the app's Select All menu item, which works in the background.
    private func selectOrClearExistingText(in targetElement: AXUIElement?, context: ActionRunContext) async throws {
        try await ensureReadyForInput(context)
        if let targetElement, let existingValue = elementReader.untruncatedStringValue(of: targetElement) {
            if existingValue.isEmpty { return }
            if try inputSynthesizer.selectEntireText(of: targetElement, textLengthInUTF16CodeUnits: existingValue.utf16.count,
                                                     abortSignal: context.abortSignal) {
                return
            }
            if elementReader.isValueSettable(on: targetElement) {
                try inputSynthesizer.setAccessibilityValue("", on: targetElement, abortSignal: context.abortSignal)
                return
            }
        }
        // ⌘A through the app's Select All menu item, else through the keyboard tiers; typing only follows a visible
        // selection, so the text never lands next to what it should have replaced.
        let focusedElementBeforeSelectAll = elementReader.applicationFocusedElement(of: context.targetApplication)
        let (_, selectAllChangeNote) = try await pressKeyReportingChange("a", modifiers: [.command],
                                                                         changeFingerprintElement: focusedElementBeforeSelectAll,
                                                                         context: context)
        if !selectAllChangeNote.isEmpty {
            throw ActionBackendError.inputNotDelivered("the existing text couldn't be selected for replacement.",
                                                       foregroundAssistMayHelp: false)
        }
    }

    private func elementHasApplicationFocus(_ accessibilityElement: AXUIElement, context: ActionRunContext) -> Bool {
        guard let focusedElement = elementReader.applicationFocusedElement(of: context.targetApplication) else { return false }
        return CFEqual(focusedElement, accessibilityElement)
    }

    private func verifyKeyboardTargetIsSafe(_ context: ActionRunContext) async throws {
        try await ensureReadyForInput(context)
        if let keyboardProblem = keyboardTargetProblem(context) { throw keyboardProblem }
    }

    /// Keystrokes go to the target app's own focused element, so that element is what must be safe: it must exist
    /// and must not be a password field, and the target app must not hold Secure Keyboard Entry.
    func keyboardTargetProblem(_ context: ActionRunContext) -> ActionBackendError? {
        if Self.secureKeyboardEntryBlocksTyping(into: context.targetApplication.processIdentifier) {
            return .elementNotActionable("Secure keyboard entry is on (a password prompt has it enabled), so Dotto won't type.")
        }
        guard let focusedElement = elementReader.applicationFocusedElement(of: context.targetApplication) else {
            return .elementNotActionable(
                "Dotto couldn't confirm which element in \(context.targetApplication.applicationName) has keyboard focus, "
                    + "so it didn't type. Click or focus the field first.")
        }
        if elementReader.isSecureTextField(focusedElement) { return .secureFieldTypingDenied }
        return nil
    }

    /// The session names the process that turned Secure Keyboard Entry on; another app holding it doesn't affect
    /// per-process input to the target. When the session doesn't say who holds it, Dotto refuses while it is on, and
    /// with no session to ask at all it refuses outright (fail closed).
    static func secureKeyboardEntryBlocksTyping(into targetProcessIdentifier: pid_t) -> Bool {
        let secureEventInputHolder = ForegroundAssistReadinessProbe.currentSecureEventInputHolder()
        guard let secureEventInputIsEnabled = secureEventInputHolder.isEnabled else { return true }
        if let holderProcessIdentifier = secureEventInputHolder.processIdentifier {
            return holderProcessIdentifier == targetProcessIdentifier
        }
        return secureEventInputIsEnabled
    }
}
