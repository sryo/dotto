import Foundation

enum StepExpectationKind: String, Codable, Sendable, CaseIterable {
    case textAppears = "text_appears"
    case textDisappears = "text_disappears"
    case fieldValueEquals = "field_value_equals"
    case windowTitleContains = "window_title_contains"
    case documentContains = "document_contains"
    case none
}

struct StepExpectation: Codable, Equatable, Sendable {
    var kind: StepExpectationKind
    /// Literal at run time; inside a Routine it may hold {{parameter}} placeholders.
    var text: String

    static let defaultTimeoutSeconds: Double = 3

    func renderingParameters(_ parameters: [ChecklistItemParameter]) throws -> StepExpectation {
        StepExpectation(kind: kind, text: try RoutineTemplating.render(text, parameters: parameters))
    }
}

enum StepExpectationVerdict: Equatable, Sendable {
    case satisfied
    case unsatisfied(reasonForModel: String)
}

enum StepExpectationChecker {
    private static let editableTextRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]
    private static let maximumQuotedTextLength = 100

    // Reasons quote only the expected text: observed titles and documents are untrusted UI text, and the model
    // receives a fresh outline alongside the reason anyway.
    /// `preActionSnapshot` (focused-window scope) makes text_appears strict: text that was already on screen only
    /// counts once something about where it appears has changed.
    static func evaluate(_ expectation: StepExpectation, in snapshotAfterAction: AccessibilityTreeSnapshot,
                         preActionSnapshot: AccessibilityTreeSnapshot? = nil) -> StepExpectationVerdict {
        let expectedText = expectation.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard expectation.kind != .none, !expectedText.isEmpty else { return .satisfied }
        let quotedText = "“\(expectedText.count > maximumQuotedTextLength ? String(expectedText.prefix(maximumQuotedTextLength)) + "…" : expectedText)”"

        switch expectation.kind {
        case .textAppears:
            guard snapshotAfterAction.containsText(expectedText) else {
                return .unsatisfied(reasonForModel: "Expected \(quotedText) to appear in the focused window, but it is not in the outline.")
            }
            if let preActionSnapshot, preActionSnapshot.containsText(expectedText),
               preActionSnapshot.textMatchSignature(expectedText) == snapshotAfterAction.textMatchSignature(expectedText) {
                return .unsatisfied(reasonForModel: "\(quotedText) was already in the focused window before the action and nothing about it changed, so it doesn't show the action worked.")
            }
            return .satisfied
        case .textDisappears:
            return !snapshotAfterAction.containsText(expectedText) ? .satisfied
                : .unsatisfied(reasonForModel: "Expected \(quotedText) to disappear from the focused window, but it is still in the outline.")
        case .fieldValueEquals:
            return anyEditableField(in: snapshotAfterAction.rootNodes, holdsExactly: expectedText) ? .satisfied
                : .unsatisfied(reasonForModel: "Expected a text field to hold exactly \(quotedText), but no field does.")
        case .windowTitleContains:
            let windowTitle = snapshotAfterAction.windowTitle ?? ""
            return windowTitle.range(of: expectedText, options: .caseInsensitive) != nil ? .satisfied
                : .unsatisfied(reasonForModel: "Expected the window title to contain \(quotedText), but it doesn't.")
        case .documentContains:
            // Finder and TextEdit report file:// URLs, so the path may be percent-encoded.
            let windowDocument = snapshotAfterAction.focusedWindowDocument ?? ""
            let documentForms = [windowDocument, windowDocument.removingPercentEncoding ?? windowDocument]
            return documentForms.contains { $0.range(of: expectedText, options: .caseInsensitive) != nil } ? .satisfied
                : .unsatisfied(reasonForModel: "Expected the window's document path or URL to contain \(quotedText), but it doesn't.")
        case .none:
            return .satisfied
        }
    }

    private static func anyEditableField(in nodes: [AccessibilityElementNode], holdsExactly expectedValue: String) -> Bool {
        nodes.contains { node in
            let holdsValue = editableTextRoles.contains(node.role) && !node.isSecureTextField
                && node.value?.trimmingCharacters(in: .whitespacesAndNewlines) == expectedValue
            return holdsValue || anyEditableField(in: node.children, holdsExactly: expectedValue)
        }
    }
}
