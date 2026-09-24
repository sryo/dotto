import AppKit
import ApplicationServices

/// replace_text: edits part of a field's text through Accessibility alone, so it works while the app stays in the
/// background. It never clicks, never posts keys and never activates anything, so the assist can't help it either.
extension AccessibilityActionBackend {
    private static let replacementResultPollIntervalNanoseconds: UInt64 = 100_000_000
    private static let replacementResultPollCount = 6

    func replaceText(_ findText: String, with replacementText: String, occurrence: TextReplacementOccurrence,
                     insertionPosition: TextInsertionPosition, inElementWithIdentifier elementIdentifier: String,
                     context: ActionRunContext) async throws -> ActionOutcome {
        let (fieldElement, fieldNode) = try resolveTargetApplicationElement(elementIdentifier, context: context)
        if fieldNode?.isSecureTextField == true || elementReader.isSecureTextField(fieldElement) {
            throw ActionBackendError.secureFieldTypingDenied
        }
        let fieldDescription = describe(fieldNode, elementIdentifier: elementIdentifier)
        guard let valueBeforeEdits = elementReader.untruncatedStringValue(of: fieldElement) else {
            throw ActionBackendError.elementNotActionable(
                "\(fieldDescription) shows no text to Accessibility, so its text can't be edited in place. Use type_text instead.")
        }
        let elementTraits = elementReader.elementInputTraits(of: fieldElement)
        if elementTraits.isSingleLineTextInput && replacementText.contains(where: \.isNewline) {
            throw ActionBackendError.elementNotActionable("\(fieldDescription) holds a single line, so a line break can't go into it.")
        }
        guard let replacementPlan = TextReplacementPlanner.plan(currentValue: valueBeforeEdits, findText: findText,
                                                                replacementText: replacementText, occurrence: occurrence,
                                                                insertionPosition: insertionPosition) else {
            throw ActionBackendError.textToReplaceNotFound(
                "\(fieldDescription) reads “\(TextReplacementPlanner.fieldTextExcerpt(valueBeforeEdits))”")
        }
        let replacementRoutes = TextReplacementPlanner.routes(
            selectedTextIsSettable: selectedTextIsSettable(on: fieldElement), elementTraits: elementTraits,
            accessibilityValueTypingIsUnreliable: accessibilityValueTypingIsUnreliable)
        guard !replacementRoutes.isEmpty else {
            throw ActionBackendError.inputNotDelivered(
                "\(fieldDescription) doesn't let Dotto edit its text in place. Type the whole edited text with type_text and "
                    + "replace_existing_text true instead.",
                foregroundAssistMayHelp: false)
        }
        try await flyCursor(toCenterOf: AccessibilityElementReader.frameInTopLeftGlobalPoints(of: fieldElement),
                            actionKind: .typing, context: context)

        let expectedValueAfterEdits = replacementPlan.expectedValueAfterEdits
        var deliveredRoute: TextReplacementRoute?
        for replacementRoute in replacementRoutes where deliveredRoute == nil {
            try await ensureReadyForInput(context)
            let routeAppliedEveryEdit: Bool
            switch replacementRoute {
            case .selectedText:
                routeAppliedEveryEdit = try await applyEditsThroughSelectedText(replacementPlan.editsLastToFirst, on: fieldElement,
                                                                                context: context)
            case .wholeValue:
                // The whole value is computed from the text before any edit, so it also corrects a selected-text route
                // that stopped partway instead of applying its edits a second time.
                routeAppliedEveryEdit = (try? inputSynthesizer.setAccessibilityValue(
                    expectedValueAfterEdits, on: fieldElement, abortSignal: context.abortSignal)) != nil
            }
            try throwIfRunEnded(context)
            guard routeAppliedEveryEdit else { continue }
            let expectedValueIsShown = try await pollReplacementResult(context) {
                self.elementReader.untruncatedStringValue(of: fieldElement) == expectedValueAfterEdits
            }
            if expectedValueIsShown { deliveredRoute = replacementRoute }
        }

        let valueAfterEdits = elementReader.untruncatedStringValue(of: fieldElement)
        if deliveredRoute == nil && valueAfterEdits == valueBeforeEdits {
            throw ActionBackendError.inputNotDelivered(
                "\(fieldDescription) kept its text: the app didn't take the edit. Type the whole edited text with type_text "
                    + "and replace_existing_text true instead.",
                foregroundAssistMayHelp: false)
        }
        // Return may commit the field next; a press_key Return then checks the app kept the edited text.
        pendingAccessibilityValueCommit = PendingAccessibilityValueCommit(
            fieldElement: fieldElement, fieldDescription: fieldDescription, typedText: expectedValueAfterEdits,
            valueBeforeTyping: valueBeforeEdits, replacedExistingText: true)

        let editCount = replacementPlan.editsLastToFirst.count
        var editDescription: String
        if findText.isEmpty {
            editDescription = "added “\(replacementText.prefix(80))” at the \(insertionPosition == .start ? "start" : "end") of \(fieldDescription)"
        } else {
            editDescription = "replaced \(editCount == 1 ? "1 occurrence" : "\(editCount) occurrences") of “\(findText.prefix(80))” "
                + "with “\(replacementText.prefix(80))” in \(fieldDescription)"
        }
        if deliveredRoute == nil {
            editDescription += ". Note: the field now reads “\((valueAfterEdits ?? "").prefix(120))”, which is not exactly the "
                + "expected result; read the UI to check before editing again"
        }
        return ActionOutcome(descriptionForModel: editDescription, deliveryTier: .accessibilityValue)
    }

    /// Both must be settable: the range places the selection without a caret, and the selected text replaces it.
    private func selectedTextIsSettable(on fieldElement: AXUIElement) -> Bool {
        [kAXSelectedTextRangeAttribute, kAXSelectedTextAttribute].allSatisfy { attributeName in
            var isSettable = DarwinBoolean(false)
            return AXUIElementIsAttributeSettable(fieldElement, attributeName as CFString, &isSettable) == .success && isSettable.boolValue
        }
    }

    /// False as soon as the app refuses a range or a replacement; the edits before it stay applied.
    private func applyEditsThroughSelectedText(_ editsLastToFirst: [TextReplacementEdit], on fieldElement: AXUIElement,
                                               context: ActionRunContext) async throws -> Bool {
        for edit in editsLastToFirst {
            try await ensureReadyForInput(context)
            var editRange = CFRange(location: edit.utf16Location, length: edit.utf16Length)
            guard let editRangeValue = AXValueCreate(.cfRange, &editRange),
                  AXUIElementSetAttributeValue(fieldElement, kAXSelectedTextRangeAttribute as CFString, editRangeValue) == .success,
                  (try? inputSynthesizer.setSelectedText(edit.replacementText, on: fieldElement, abortSignal: context.abortSignal)) != nil
            else { return false }
        }
        return true
    }

    /// Web content reports a new value a moment later, so the read-back is polled.
    private func pollReplacementResult(_ context: ActionRunContext, until replacementResultIsSeen: () -> Bool) async throws -> Bool {
        for _ in 0...Self.replacementResultPollCount {
            if replacementResultIsSeen() { return true }
            try await Task.sleep(nanoseconds: Self.replacementResultPollIntervalNanoseconds)
            try throwIfRunEnded(context)
        }
        return false
    }
}
