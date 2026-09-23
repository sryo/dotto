import Foundation

/// One answer the planner offers under its question. Tapping it sends `label` as the user's reply.
struct PlannerQuestionChoice: Equatable, Sendable {
    static let maximumLabelLength = 32
    static let maximumDetailLength = 80

    var label: String
    var detail: String?
}

/// What the planner says to the user while it plans: a question (from `ask_user`, or a text-only answer taken as
/// one), or, when nothing can be replied, its explanation of what blocks the plan.
struct PlannerQuestion: Equatable, Sendable {
    static let maximumChoiceCount = 4
    /// Long enough for the two short sentences the prompt asks for, and for a text-only answer's first paragraphs;
    /// the thread must never be flooded.
    static let maximumTextLength = 600

    var text: String
    var choices: [PlannerQuestionChoice]
    var allowsFreeText: Bool

    /// False for the planner's final word on a task it can't plan: the thread shows it without a reply field.
    var acceptsReply: Bool { allowsFreeText || !choices.isEmpty }

    /// Cleans what the model wrote: markdown stripped, lengths capped, empty or repeated choices dropped, at most
    /// four choices, and free text allowed whenever no choice is left (a question must be answerable).
    static func sanitized(text rawText: String, choices rawChoices: [PlannerQuestionChoice], allowsFreeText: Bool) -> PlannerQuestion {
        var seenLabels = Set<String>()
        var sanitizedChoices: [PlannerQuestionChoice] = []
        for rawChoice in rawChoices {
            let label = PlannerPlainText.singleLine(fromMarkdown: rawChoice.label, maximumLength: PlannerQuestionChoice.maximumLabelLength)
            guard !label.isEmpty, seenLabels.insert(label.lowercased()).inserted else { continue }
            let detail = rawChoice.detail.map {
                PlannerPlainText.singleLine(fromMarkdown: $0, maximumLength: PlannerQuestionChoice.maximumDetailLength)
            }
            sanitizedChoices.append(PlannerQuestionChoice(label: label, detail: detail?.isEmpty == false ? detail : nil))
            if sanitizedChoices.count == maximumChoiceCount { break }
        }
        return PlannerQuestion(text: PlannerPlainText.paragraphs(fromMarkdown: rawText, maximumLength: maximumTextLength),
                               choices: sanitizedChoices,
                               allowsFreeText: allowsFreeText || sanitizedChoices.isEmpty)
    }

    /// The planner's last word when it can't plan: shown in the thread with nothing to reply to.
    static func blockingExplanation(_ rawText: String) -> PlannerQuestion {
        PlannerQuestion(text: PlannerPlainText.paragraphs(fromMarkdown: rawText, maximumLength: maximumTextLength),
                        choices: [], allowsFreeText: false)
    }
}

/// One bubble in the planning thread.
struct PlannerConversationEntry: Equatable, Sendable, Identifiable {
    enum Author: Equatable, Sendable { case user, dotto }

    var id: Int
    var author: Author
    var text: String
    /// Only on Dotto's questions; the chips show under the latest one.
    var choices: [PlannerQuestionChoice] = []
}

/// The planning thread the popover shows: the user's command first, then each question and reply in order. It is
/// what the user sees; the planner keeps the model-facing conversation itself.
struct PlannerConversationTranscript: Equatable, Sendable {
    private(set) var entries: [PlannerConversationEntry] = []

    init() {}

    init(command: String) {
        appendUserMessage(command)
    }

    /// True once the planner has said anything, so the checklist can offer "Show conversation".
    var containsPlannerMessages: Bool { entries.contains { $0.author == .dotto } }

    /// The question the chips belong to: Dotto's message when it is the newest entry.
    var latestUnansweredQuestionEntry: PlannerConversationEntry? {
        guard let lastEntry = entries.last, lastEntry.author == .dotto else { return nil }
        return lastEntry
    }

    mutating func appendUserMessage(_ messageText: String) {
        entries.append(PlannerConversationEntry(id: entries.count, author: .user, text: messageText))
    }

    mutating func appendPlannerQuestion(_ plannerQuestion: PlannerQuestion) {
        entries.append(PlannerConversationEntry(id: entries.count, author: .dotto, text: plannerQuestion.text,
                                                choices: plannerQuestion.choices))
    }
}

/// Turns model-written markdown into plain text for the thread. Only the syntax the model tends to use is taken out
/// (emphasis, headings, bullets, inline code, links, rules); the words stay as written.
enum PlannerPlainText {
    /// Keeps paragraph breaks (at most one blank line in a row) and collapses spaces inside lines.
    static func paragraphs(fromMarkdown markdownText: String, maximumLength: Int) -> String {
        let plainLines = markdownText.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map(plainLine(fromMarkdownLine:))
        var keptLines: [String] = []
        for plainLine in plainLines {
            if plainLine.isEmpty && (keptLines.last?.isEmpty ?? true) { continue }
            keptLines.append(plainLine)
        }
        while keptLines.last?.isEmpty == true { keptLines.removeLast() }
        return truncated(keptLines.joined(separator: "\n"), maximumLength: maximumLength)
    }

    static func singleLine(fromMarkdown markdownText: String, maximumLength: Int) -> String {
        let joinedText = markdownText.components(separatedBy: .newlines)
            .map(plainLine(fromMarkdownLine:))
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return truncated(joinedText, maximumLength: maximumLength)
    }

    private static func plainLine(fromMarkdownLine markdownLine: String) -> String {
        var line = markdownLine.trimmingCharacters(in: .whitespaces)
        // A horizontal rule carries no words.
        if line.count >= 3, Set(line.replacingOccurrences(of: " ", with: "")).isSubset(of: ["-", "*", "_"]) { return "" }
        line = replacing(pattern: "^#{1,6}\\s+", in: line, with: "")
        line = replacing(pattern: "^>\\s?", in: line, with: "")
        line = replacing(pattern: "^[-*+]\\s+", in: line, with: "")
        // [text](url) keeps its text; a bare URL stays as written.
        line = replacing(pattern: "!?\\[([^\\]]*)\\]\\([^)]*\\)", in: line, with: "$1")
        line = replacing(pattern: "\\*\\*(.+?)\\*\\*", in: line, with: "$1")
        line = replacing(pattern: "__(.+?)__", in: line, with: "$1")
        // Single-star emphasis only when it hugs a word, so "5 * 3" survives.
        line = replacing(pattern: "(?<![\\w*])\\*(?=\\S)(.+?)(?<=\\S)\\*(?![\\w*])", in: line, with: "$1")
        line = replacing(pattern: "`+([^`]*)`+", in: line, with: "$1")
        // Unpaired bold markers left over carry no words either.
        line = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
        line = replacing(pattern: "\\s{2,}", in: line, with: " ")
        return line.trimmingCharacters(in: .whitespaces)
    }

    private static func replacing(pattern: String, in text: String, with template: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
        return expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    private static func truncated(_ text: String, maximumLength: Int) -> String {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedText.count > maximumLength, maximumLength > 1 else { return trimmedText }
        return String(trimmedText.prefix(maximumLength - 1)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}
