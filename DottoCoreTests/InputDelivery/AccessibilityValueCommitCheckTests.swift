import Foundation

private let oldFileName = "Captura de pantalla 2026-06-17 a la(s) 1.08.46 p. m..png"
private let newFileName = "223x142 Captura de pantalla 2026-06-17 a la(s) 1.08.46 p. m..png"

private func renameObservation(fieldValueAfterReturn: String?, fieldStillHasKeyboardFocus: Bool = false,
                               typedTextIsShownInWindow: Bool = false, valueBeforeTyping: String? = oldFileName,
                               replacedExistingText: Bool = true, typedText: String = newFileName) -> AccessibilityValueCommitObservation {
    AccessibilityValueCommitObservation(typedText: typedText, valueBeforeTyping: valueBeforeTyping,
                                        replacedExistingText: replacedExistingText, fieldValueAfterReturn: fieldValueAfterReturn,
                                        fieldStillHasKeyboardFocus: fieldStillHasKeyboardFocus,
                                        typedTextIsShownInWindow: typedTextIsShownInWindow)
}

let accessibilityValueCommitCheckTestSuite = CoreTestSuite(name: "AccessibilityValueCommitCheck", testCases: [
    CoreTestCase(name: "Finder's name editor closed on Return and the new name is nowhere: not kept, no retry in place") {
        try expectEqual(AccessibilityValueCommitCheck.verdict(for: renameObservation(fieldValueAfterReturn: nil)),
                        .notKept(retryWithRealKeysInFieldMayHelp: false))
    },
    CoreTestCase(name: "the editor closed and the window shows the new name: kept") {
        try expectEqual(AccessibilityValueCommitCheck.verdict(for: renameObservation(fieldValueAfterReturn: nil, typedTextIsShownInWindow: true)),
                        .keptOrCannotTell)
    },
    CoreTestCase(name: "the field went back to the old text: not kept, and real keys may help only while it is still focused") {
        try expectEqual(AccessibilityValueCommitCheck.verdict(for: renameObservation(fieldValueAfterReturn: oldFileName,
                                                                                     fieldStillHasKeyboardFocus: true)),
                        .notKept(retryWithRealKeysInFieldMayHelp: true))
        try expectEqual(AccessibilityValueCommitCheck.verdict(for: renameObservation(fieldValueAfterReturn: oldFileName)),
                        .notKept(retryWithRealKeysInFieldMayHelp: false))
    },
    CoreTestCase(name: "the field still holds the typed text, or the app's formatting of it: kept") {
        try expectEqual(AccessibilityValueCommitCheck.verdict(for: renameObservation(fieldValueAfterReturn: newFileName)), .keptOrCannotTell)
        try expectEqual(AccessibilityValueCommitCheck.verdict(for: renameObservation(
            fieldValueAfterReturn: "1,000", valueBeforeTyping: "250", typedText: "1000")), .keptOrCannotTell)
    },
    CoreTestCase(name: "a field that started empty is never judged: a sent message clears it just like a dropped value") {
        try expectEqual(AccessibilityValueCommitCheck.verdict(for: renameObservation(fieldValueAfterReturn: "", valueBeforeTyping: "")),
                        .keptOrCannotTell)
        try expectEqual(AccessibilityValueCommitCheck.verdict(for: renameObservation(fieldValueAfterReturn: nil, valueBeforeTyping: nil)),
                        .keptOrCannotTell)
    },
    CoreTestCase(name: "appending is never judged, nor retyping the same text") {
        try expectEqual(AccessibilityValueCommitCheck.verdict(for: renameObservation(fieldValueAfterReturn: nil, replacedExistingText: false)),
                        .keptOrCannotTell)
        try expectEqual(AccessibilityValueCommitCheck.verdict(for: renameObservation(fieldValueAfterReturn: nil, valueBeforeTyping: newFileName)),
                        .keptOrCannotTell)
    },
    CoreTestCase(name: "an element shows the typed text when it contains it or equals it without the hidden extension") {
        try expectTrue(AccessibilityValueCommitCheck.elementText(newFileName, showsTypedText: newFileName))
        try expectTrue(AccessibilityValueCommitCheck.elementText("Renamed: " + newFileName, showsTypedText: newFileName))
        try expectTrue(AccessibilityValueCommitCheck.elementText("223x142 Captura de pantalla 2026-06-17 a la(s) 1.08.46 p. m.",
                                                                 showsTypedText: newFileName))
        try expectEqual(AccessibilityValueCommitCheck.elementText(oldFileName, showsTypedText: newFileName), false)
        try expectEqual(AccessibilityValueCommitCheck.elementText("223x142", showsTypedText: newFileName), false)
        try expectEqual(AccessibilityValueCommitCheck.elementText("", showsTypedText: newFileName), false)
    },
    CoreTestCase(name: "once a value was dropped, typing plans real keys only, in the background and in front") {
        let settableNativeField = ElementInputTraits(supportsPressAction: false, supportsShowMenuAction: false, isInsideWebArea: false,
                                                     isSingleLineTextInput: true, isValueSettable: true, hasSettableScrollBar: false)
        for targetIsFrontmost in [false, true] {
            var planningRequest = InputTierPlanningRequest(
                actionKind: .typeText, applicationKind: .cocoa, elementTraits: settableNativeField, capabilities: .none,
                enhancedUserInterfaceIsActive: false, windowIdentifierIsKnown: true, targetIsFrontmost: targetIsFrontmost)
            try expectEqual(InputTierPlanner.backgroundTiers(for: planningRequest), [.processKeyboardEvents, .accessibilityValue])
            planningRequest.accessibilityValueTypingIsUnreliable = true
            try expectEqual(InputTierPlanner.backgroundTiers(for: planningRequest), [.processKeyboardEvents])
        }
    },
])
