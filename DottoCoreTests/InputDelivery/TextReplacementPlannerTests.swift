import Foundation

private func makeTraits(isInsideWebArea: Bool = false, isSingleLineTextInput: Bool = false,
                        isValueSettable: Bool = true) -> ElementInputTraits {
    ElementInputTraits(supportsPressAction: false, supportsShowMenuAction: false, isInsideWebArea: isInsideWebArea,
                       isSingleLineTextInput: isSingleLineTextInput, isValueSettable: isValueSettable, hasSettableScrollBar: false)
}

let textReplacementPlannerTestSuite = CoreTestSuite(name: "TextReplacementPlanner", testCases: [
    CoreTestCase(name: "the first occurrence is replaced, matching exactly and case-sensitively") {
        let replacementPlan = try unwrapOrFail(TextReplacementPlanner.plan(
            currentValue: "Teh cat saw teh dog", findText: "teh", replacementText: "the", occurrence: .first, insertionPosition: .atFind))
        try expectEqual(replacementPlan.editsLastToFirst, [TextReplacementEdit(utf16Location: 12, utf16Length: 3, replacementText: "the")])
        try expectEqual(replacementPlan.expectedValueAfterEdits, "Teh cat saw the dog")
    },
    CoreTestCase(name: "all occurrences are edited last to first, so earlier ranges stay valid") {
        let replacementPlan = try unwrapOrFail(TextReplacementPlanner.plan(
            currentValue: "aa-aa-aa", findText: "aa", replacementText: "bbb", occurrence: .all, insertionPosition: .atFind))
        try expectEqual(replacementPlan.editsLastToFirst.map(\.utf16Location), [6, 3, 0])
        try expectEqual(replacementPlan.expectedValueAfterEdits, "bbb-bbb-bbb")
        let overlappingPlan = try unwrapOrFail(TextReplacementPlanner.plan(
            currentValue: "aaaa", findText: "aa", replacementText: "b", occurrence: .all, insertionPosition: .atFind))
        try expectEqual(overlappingPlan.expectedValueAfterEdits, "bb", "matches don't overlap")
    },
    CoreTestCase(name: "ranges count UTF-16 code units, as AXSelectedTextRange does") {
        let replacementPlan = try unwrapOrFail(TextReplacementPlanner.plan(
            currentValue: "🎉 party café", findText: "café", replacementText: "bar", occurrence: .first, insertionPosition: .atFind))
        try expectEqual(replacementPlan.editsLastToFirst, [TextReplacementEdit(utf16Location: 9, utf16Length: 4, replacementText: "bar")])
        try expectEqual(replacementPlan.expectedValueAfterEdits, "🎉 party bar")
    },
    CoreTestCase(name: "an empty find inserts at the start or the end") {
        try expectEqual(TextReplacementPlanner.plan(currentValue: "body", findText: "", replacementText: "Title\n", occurrence: .first,
                                                    insertionPosition: .start)?.expectedValueAfterEdits, "Title\nbody")
        let endPlan = try unwrapOrFail(TextReplacementPlanner.plan(currentValue: "🎉body", findText: "", replacementText: " end",
                                                                   occurrence: .all, insertionPosition: .end))
        try expectEqual(endPlan.editsLastToFirst, [TextReplacementEdit(utf16Location: 6, utf16Length: 0, replacementText: " end")])
        try expectEqual(endPlan.expectedValueAfterEdits, "🎉body end")
    },
    CoreTestCase(name: "text that isn't there gives no plan") {
        try expectEqual(TextReplacementPlanner.plan(currentValue: "Hello", findText: "hello", replacementText: "Hi", occurrence: .all,
                                                    insertionPosition: .atFind), nil)
        try expectEqual(TextReplacementPlanner.plan(currentValue: "", findText: "x", replacementText: "y", occurrence: .first,
                                                    insertionPosition: .atFind), nil)
    },
    CoreTestCase(name: "routes: selected text first, whole value only where setting AXValue is safe") {
        try expectEqual(TextReplacementPlanner.routes(selectedTextIsSettable: true, elementTraits: makeTraits(),
                                                      accessibilityValueTypingIsUnreliable: false), [.selectedText, .wholeValue])
        try expectEqual(TextReplacementPlanner.routes(selectedTextIsSettable: false, elementTraits: makeTraits(isValueSettable: false),
                                                      accessibilityValueTypingIsUnreliable: false), [])
        try expectEqual(TextReplacementPlanner.routes(selectedTextIsSettable: true, elementTraits: makeTraits(isInsideWebArea: true),
                                                      accessibilityValueTypingIsUnreliable: false), [.selectedText])
        try expectEqual(TextReplacementPlanner.routes(selectedTextIsSettable: false,
                                                      elementTraits: makeTraits(isInsideWebArea: true, isSingleLineTextInput: true),
                                                      accessibilityValueTypingIsUnreliable: false), [.wholeValue])
        try expectEqual(TextReplacementPlanner.routes(selectedTextIsSettable: true, elementTraits: makeTraits(),
                                                      accessibilityValueTypingIsUnreliable: true), [])
    },
])
