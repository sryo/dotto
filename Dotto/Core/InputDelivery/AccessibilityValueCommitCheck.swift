import Foundation

/// What Dotto reads after Return follows text it set directly as a field's AXValue. Some fields show a set value but
/// commit only what real keystrokes put in their editor: Finder's inline name editor closes on Return and keeps the old
/// name. Reading the value back before Return can't tell those fields apart, so the result is judged after it.
struct AccessibilityValueCommitObservation: Equatable, Sendable {
    var typedText: String
    /// The field's value right before the text was set; nil when it couldn't be read.
    var valueBeforeTyping: String?
    var replacedExistingText: Bool
    /// nil when the field is gone (an inline editor closes on commit) or no longer answers.
    var fieldValueAfterReturn: String?
    var fieldStillHasKeyboardFocus: Bool
    /// Whether any element of the window shows the typed text (see `elementText(_:showsTypedText:)`).
    var typedTextIsShownInWindow: Bool
}

enum AccessibilityValueCommitVerdict: Equatable, Sendable {
    /// The text is visible where it should be, or nothing positively shows it was dropped.
    case keptOrCannotTell
    /// The app went back to the replaced text. A retry with real keys can help only while the field is still open.
    case notKept(retryWithRealKeysInFieldMayHelp: Bool)
}

enum AccessibilityValueCommitCheck {
    /// Only replacing existing text can be judged: when a field that started empty is cleared by Return (a chat box
    /// that sent its message), a dropped value and a delivered one look the same, and reporting it as dropped could
    /// make the model send it twice.
    static func verdict(for observation: AccessibilityValueCommitObservation) -> AccessibilityValueCommitVerdict {
        guard observation.replacedExistingText, let replacedValue = observation.valueBeforeTyping,
              !replacedValue.isEmpty, replacedValue != observation.typedText, !observation.typedText.isEmpty else {
            return .keptOrCannotTell
        }
        if let fieldValueAfterReturn = observation.fieldValueAfterReturn {
            if fieldValueAfterReturn == replacedValue {
                return .notKept(retryWithRealKeysInFieldMayHelp: observation.fieldStillHasKeyboardFocus)
            }
            // The field still answers with some other text (the typed text, or the app's formatting of it).
            return .keptOrCannotTell
        }
        return observation.typedTextIsShownInWindow ? .keptOrCannotTell : .notKept(retryWithRealKeysInFieldMayHelp: false)
    }

    /// An element shows the typed text when its text contains it, or equals it without its file extension (Finder hides
    /// extensions unless the user asked to see them).
    static func elementText(_ elementText: String, showsTypedText typedText: String) -> Bool {
        guard !elementText.isEmpty, !typedText.isEmpty else { return false }
        if elementText.range(of: typedText, options: .caseInsensitive) != nil { return true }
        let typedTextWithoutExtension = (typedText as NSString).deletingPathExtension
        guard typedTextWithoutExtension != typedText, !typedTextWithoutExtension.isEmpty else { return false }
        return elementText.caseInsensitiveCompare(typedTextWithoutExtension) == .orderedSame
    }
}
