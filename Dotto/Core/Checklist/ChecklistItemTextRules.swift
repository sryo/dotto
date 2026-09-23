import Foundation

/// The planner prompt's item rules, enforced on what the planner actually submits. A checklist row shows one line, so
/// a label is short and names an outcome; an action summary is one outcome sentence. Step-by-step instructions
/// (menu paths, shortcuts, clicks) make every item long to write, which is what makes a long checklist slow to plan,
/// and the executor reads the live UI anyway.
enum ChecklistItemTextRules {
    static let maximumLabelLength = 60
    static let maximumActionSummaryLength = 140
    /// Labels a little over the limit are shortened; far over it, the label is written as instructions.
    static let maximumLabelLengthBeforeRejection = 100
    static let maximumReportedViolations = 5

    enum LabelViolation: Equatable, Sendable {
        case menuPath
        case keystroke
        case clickInstruction
        case tooLong(characterCount: Int)

        var reasonForModel: String {
            switch self {
            case .menuPath: return "contains a menu path"
            case .keystroke: return "contains a keyboard shortcut or key press"
            case .clickInstruction: return "describes clicks instead of the outcome"
            case .tooLong(let characterCount): return "is \(characterCount) characters long (60 at most)"
            }
        }
    }

    /// Why the label breaks the rules, or nil when it follows them (or only runs a little long, which
    /// `normalizedLabel` fixes). Quoted names are skipped: a file may be called “Save > Export ⌘.txt”.
    static func labelViolation(_ label: String) -> LabelViolation? {
        let labelWithoutQuotedNames = removingQuotedNames(from: label)
        if matches(menuPathPattern, in: labelWithoutQuotedNames) { return .menuPath }
        if matches(keystrokePattern, in: labelWithoutQuotedNames) { return .keystroke }
        if matches(clickInstructionPattern, in: labelWithoutQuotedNames) { return .clickInstruction }
        let labelCharacterCount = label.trimmingCharacters(in: .whitespacesAndNewlines).count
        if labelCharacterCount > maximumLabelLengthBeforeRejection { return .tooLong(characterCount: labelCharacterCount) }
        return nil
    }

    /// One line, at most 60 characters, cut at a word boundary with an ellipsis.
    static func normalizedLabel(_ label: String) -> String {
        truncatedAtWordBoundary(collapsingWhitespace(label), maximumLength: maximumLabelLength)
    }

    /// The first sentence only, one line, at most 140 characters. Later sentences are where step-by-step
    /// instructions go ("…, then press Return. Close the window with ⌘W.").
    static func normalizedActionSummary(_ actionSummary: String) -> String {
        let singleLineSummary = collapsingWhitespace(actionSummary)
        return truncatedAtWordBoundary(firstSentence(of: singleLineSummary), maximumLength: maximumActionSummaryLength)
    }

    /// The tool error that sends a submit_plan back: which items break the label rules and what a good label is.
    static func rejectionMessageForModel(labelViolations: [(itemNumber: Int, violation: LabelViolation)]) -> String {
        let reportedViolations = labelViolations.prefix(maximumReportedViolations).map { itemNumber, violation in
            "item \(itemNumber) \(violation.reasonForModel)"
        }
        let unreportedCount = labelViolations.count - reportedViolations.count
        let moreText = unreportedCount > 0 ? " (and \(unreportedCount) more)" : ""
        return "Plan not accepted: labels must name the outcome, not the steps. "
            + reportedViolations.joined(separator: "; ") + moreText + ". "
            + "Call submit_plan again with labels of 60 characters or fewer, like Rename “IMG_0412.jpg” to “beach-01.jpg”, "
            + "and a one-sentence action_summary of 140 characters or fewer; no menu paths, shortcuts or clicks."
    }

    // MARK: - Matching

    /// "File > New Folder", "Archivo › Nueva carpeta": a menu separator between two words. An arrow is left alone,
    /// since Rename “a” → “b” is a fine label.
    private static let menuPathPattern = #"\S\s*(>|›|»|▸)\s*\S"#
    /// Modifier symbols, and spelled-out chords such as "Cmd+W", "command-I", "Ctrl + C".
    private static let keystrokePattern = #"[⌘⌥⌃⇧↩⏎⎋]|\b(cmd|command|ctrl|control|opt|option|alt|shift)\s*[-+]\s*\w|\bpress(ing)?\b|\bkeyboard shortcut\b"#
    private static let clickInstructionPattern = #"\b(double[- ]?|right[- ]?|control[- ]?)?click(s|ing)?\b"#

    private static func matches(_ pattern: String, in text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Curly-quoted and straight-quoted names are data (file names, record titles), never instructions.
    private static func removingQuotedNames(from text: String) -> String {
        text.replacingOccurrences(of: #"“[^”]*”|"[^"]*"|‘[^’]*’"#, with: "“”", options: .regularExpression)
    }

    private static func collapsingWhitespace(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// A sentence ends at ". ", "! " or "? " outside quotes; a dot inside a file name ("IMG_0412.jpg") is not an end.
    private static func firstSentence(of text: String) -> String {
        var isInsideQuotes = false
        var previousCharacter: Character?
        for characterIndex in text.indices {
            let character = text[characterIndex]
            if character == "“" { isInsideQuotes = true }
            if character == "”" { isInsideQuotes = false }
            if character == " ", !isInsideQuotes, let previousCharacter, [".", "!", "?"].contains(previousCharacter) {
                return String(text[..<characterIndex])
            }
            previousCharacter = character
        }
        return text
    }

    private static func truncatedAtWordBoundary(_ text: String, maximumLength: Int) -> String {
        guard text.count > maximumLength else { return text }
        let hardCutText = String(text.prefix(maximumLength - 1))
        // Cut back to the last space unless that would drop more than a third of the text (one very long word).
        if let lastSpaceIndex = hardCutText.lastIndex(of: " "),
           hardCutText.distance(from: hardCutText.startIndex, to: lastSpaceIndex) >= maximumLength * 2 / 3 {
            return String(hardCutText[..<lastSpaceIndex]).trimmingCharacters(in: CharacterSet(charactersIn: " ,;:—–-")) + "…"
        }
        return hardCutText + "…"
    }
}
