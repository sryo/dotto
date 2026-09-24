import Foundation

/// One edit of a field's text, in UTF-16 code units because that is how AXSelectedTextRange counts.
struct TextReplacementEdit: Equatable, Sendable {
    var utf16Location: Int
    var utf16Length: Int
    var replacementText: String
}

struct TextReplacementPlan: Equatable, Sendable {
    /// Applied in this order, so each edit's range is still valid when its turn comes: an edit only shifts the text
    /// after it.
    var editsLastToFirst: [TextReplacementEdit]
    var expectedValueAfterEdits: String
}

/// How replace_text changes a field without a caret, in the order the backend tries them.
enum TextReplacementRoute: Equatable, Sendable {
    /// AXSelectedTextRange, then AXSelectedText, per edit: only the matched text changes.
    case selectedText
    /// The whole edited text set as AXValue.
    case wholeValue
}

enum TextReplacementPlanner {
    /// nil when `findText` isn't in `currentValue`. Matching is exact and case-sensitive, occurrences don't overlap,
    /// and an empty `findText` inserts at the start or the end of the text.
    static func plan(currentValue: String, findText: String, replacementText: String,
                     occurrence: TextReplacementOccurrence, insertionPosition: TextInsertionPosition) -> TextReplacementPlan? {
        let currentValueAsNSString = currentValue as NSString
        var editsFirstToLast: [TextReplacementEdit] = []
        if findText.isEmpty {
            let insertionLocation = insertionPosition == .start ? 0 : currentValueAsNSString.length
            editsFirstToLast = [TextReplacementEdit(utf16Location: insertionLocation, utf16Length: 0, replacementText: replacementText)]
        } else {
            var searchRange = NSRange(location: 0, length: currentValueAsNSString.length)
            while searchRange.length > 0 {
                let matchRange = currentValueAsNSString.range(of: findText, options: .literal, range: searchRange)
                if matchRange.location == NSNotFound { break }
                editsFirstToLast.append(TextReplacementEdit(utf16Location: matchRange.location, utf16Length: matchRange.length,
                                                            replacementText: replacementText))
                if occurrence == .first { break }
                let searchStart = matchRange.location + matchRange.length
                searchRange = NSRange(location: searchStart, length: currentValueAsNSString.length - searchStart)
            }
            if editsFirstToLast.isEmpty { return nil }
        }
        let editsLastToFirst = Array(editsFirstToLast.reversed())
        let editedValue = NSMutableString(string: currentValue)
        for edit in editsLastToFirst {
            editedValue.replaceCharacters(in: NSRange(location: edit.utf16Location, length: edit.utf16Length), with: edit.replacementText)
        }
        return TextReplacementPlan(editsLastToFirst: editsLastToFirst, expectedValueAfterEdits: editedValue as String)
    }

    /// Setting AXValue on a web text area or content-editable region skips the page's input events, so the page keeps
    /// its old text; those take only the selected-text route. Once the app has dropped a value Dotto set directly, it
    /// takes neither (`accessibilityValueTypingIsUnreliable`): its text then goes in only as real keys, through type_text.
    static func routes(selectedTextIsSettable: Bool, elementTraits: ElementInputTraits,
                       accessibilityValueTypingIsUnreliable: Bool) -> [TextReplacementRoute] {
        guard !accessibilityValueTypingIsUnreliable else { return [] }
        let wholeValueIsSafe = elementTraits.isValueSettable && (!elementTraits.isInsideWebArea || elementTraits.isSingleLineTextInput)
        return (selectedTextIsSettable ? [.selectedText] : []) + (wholeValueIsSafe ? [.wholeValue] : [])
    }

    /// The start of the field's text, for telling the model what the field holds.
    static func fieldTextExcerpt(_ currentValue: String, maximumCharacterCount: Int = 200) -> String {
        guard currentValue.count > maximumCharacterCount else { return currentValue }
        return String(currentValue.prefix(maximumCharacterCount)) + "…"
    }
}
