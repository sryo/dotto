import Foundation
import CoreGraphics

/// Plays the model for testing Dotto end to end without the API (Debug builds only, see `MockClaudeTransport`): from a
/// request it decides the next tool calls a believable model would make, using only what Dotto itself put in the
/// conversation (the command, the target app's name, outlines).
///
/// Planning reads the window, then submits a two-item checklist. Each item reads the window, then does one harmless
/// thing in it: inserts a line at the end of the first text area, or presses the first button whose title is a single
/// digit (a calculator key); with neither it takes a screenshot. It then finishes with evidence that is on screen.
enum ClaudeMockConversationScript {
    static let insertedTextMarker = "Dotto mock line"

    static func response(to request: ClaudeMessagesRequest, responseNumber: Int) -> ClaudeMessagesResponse {
        let toolNames = Set(request.tools.map(\.name))
        let toolResultTexts = request.messages.flatMap(\.content).compactMap { contentBlock -> String? in
            guard case .toolResult(let toolResultBlock) = contentBlock else { return nil }
            return toolResultBlock.content.compactMap { resultContent -> String? in
                if case .text(let resultText) = resultContent { return resultText }
                return nil
            }.joined(separator: "\n")
        }
        let toolUse: ClaudeToolUseBlock
        if toolNames.contains("submit_plan") {
            toolUse = nextPlannerToolUse(initialUserText: initialUserText(of: request), toolResultTexts: toolResultTexts,
                                         responseNumber: responseNumber)
        } else if toolNames.contains("finish_item") {
            toolUse = nextExecutorToolUse(initialUserText: initialUserText(of: request), toolResultTexts: toolResultTexts,
                                          responseNumber: responseNumber)
        } else {
            return ClaudeMessagesResponse(messageIdentifier: "msg_mock_\(responseNumber)", model: request.model,
                                          content: [.text(ClaudeTextBlock(text: "The mock has no script for this request.", cacheControl: nil))],
                                          stopReason: .endTurn, refusalExplanation: nil, usage: mockUsage)
        }
        return ClaudeMessagesResponse(messageIdentifier: "msg_mock_\(responseNumber)", model: request.model,
                                      content: [.toolUse(toolUse)], stopReason: .toolUse, refusalExplanation: nil, usage: mockUsage)
    }

    // MARK: - Planner

    private static func nextPlannerToolUse(initialUserText: String, toolResultTexts: [String], responseNumber: Int) -> ClaudeToolUseBlock {
        guard !toolResultTexts.isEmpty else { return readUserInterfaceToolUse(responseNumber: responseNumber) }
        let applicationName = targetApplicationName(in: initialUserText) ?? "the app"
        let checklistItems: [JSONValue] = [
            .object(["label": .string("Look over the “\(applicationName)” window"),
                     "action_summary": .string("Reads the window and leaves a harmless mark in it."),
                     "parameters": .array([]), "is_irreversible": .bool(false)]),
            .object(["label": .string("Check the “\(applicationName)” window again"),
                     "action_summary": .string("Reads the window once more and leaves another harmless mark."),
                     "parameters": .array([]), "is_irreversible": .bool(false)]),
        ]
        return ClaudeToolUseBlock(toolUseIdentifier: "toolu_mock_\(responseNumber)", toolName: "submit_plan", input: .object([
            "task_title": .string("Mock task in \(applicationName)"),
            "message_to_user": .string("This plan comes from Dotto's mock model; no request reached Anthropic."),
            "items": .array(checklistItems),
        ]))
    }

    // MARK: - Executor

    private static func nextExecutorToolUse(initialUserText: String, toolResultTexts: [String], responseNumber: Int) -> ClaudeToolUseBlock {
        let toolUseIdentifier = "toolu_mock_\(responseNumber)"
        // The item's first message carries the current outline, so the item can act at once.
        let latestOutline = toolResultTexts.last ?? initialUserText
        switch toolResultTexts.count {
        case 0 where !latestOutline.contains("[e"):
            return readUserInterfaceToolUse(responseNumber: responseNumber)
        case 0:
            if let textAreaIdentifier = firstElementIdentifier(in: latestOutline, role: "textarea") {
                return ClaudeToolUseBlock(toolUseIdentifier: toolUseIdentifier, toolName: "replace_text", input: .object([
                    "element_id": .string(textAreaIdentifier), "find": .string(""),
                    "replace_with": .string("\n\(insertedTextMarker)"), "occurrence": .string("first"),
                    "position": .string("end"), "expect": .null]))
            }
            if let digitButtonIdentifier = firstDigitButtonIdentifier(in: latestOutline) {
                return ClaudeToolUseBlock(toolUseIdentifier: toolUseIdentifier, toolName: "click", input: .object([
                    "element_id": .string(digitButtonIdentifier), "click_type": .string("single"), "expect": .null]))
            }
            return ClaudeToolUseBlock(toolUseIdentifier: toolUseIdentifier, toolName: "screenshot", input: .object([:]))
        default:
            let evidenceText = firstQuotedText(in: latestOutline) ?? targetApplicationName(in: initialUserText) ?? ""
            return ClaudeToolUseBlock(toolUseIdentifier: toolUseIdentifier, toolName: "finish_item", input: .object([
                "outcome": .string("completed"), "summary": .string("Done by Dotto's mock model."),
                "evidence": .object(["kind": .string("text_appears"), "text": .string(evidenceText)])]))
        }
    }

    // MARK: - Reading what Dotto wrote

    private static func readUserInterfaceToolUse(responseNumber: Int) -> ClaudeToolUseBlock {
        ClaudeToolUseBlock(toolUseIdentifier: "toolu_mock_\(responseNumber)", toolName: "read_ui", input: .object([
            "scope": .string("focused_window"), "application_name": .null, "query": .null]))
    }

    private static func initialUserText(of request: ClaudeMessagesRequest) -> String {
        guard let firstMessage = request.messages.first else { return "" }
        return firstMessage.content.compactMap { contentBlock -> String? in
            if case .text(let textBlock) = contentBlock { return textBlock.text }
            return nil
        }.joined(separator: "\n")
    }

    static func targetApplicationName(in initialUserText: String) -> String? {
        for textLine in initialUserText.components(separatedBy: "\n") where textLine.hasPrefix("Target app: ") {
            let afterPrefix = textLine.dropFirst("Target app: ".count)
            let applicationName = afterPrefix.components(separatedBy: " (").first ?? String(afterPrefix)
            return applicationName.isEmpty ? nil : applicationName
        }
        return nil
    }

    /// The id of the first outline line of this role, like `[e12] textarea …`.
    static func firstElementIdentifier(in outline: String, role: String) -> String? {
        for outlineLine in outline.components(separatedBy: "\n") {
            let trimmedLine = outlineLine.trimmingCharacters(in: .whitespaces)
            guard trimmedLine.hasPrefix("[e"), let closingBracket = trimmedLine.firstIndex(of: "]") else { continue }
            let afterIdentifier = trimmedLine[trimmedLine.index(after: closingBracket)...].trimmingCharacters(in: .whitespaces)
            if afterIdentifier == role || afterIdentifier.hasPrefix(role + " ") {
                return String(trimmedLine[trimmedLine.index(after: trimmedLine.startIndex)..<closingBracket])
            }
        }
        return nil
    }

    /// A button titled with one digit, such as a calculator's `[e40] button "7"`.
    static func firstDigitButtonIdentifier(in outline: String) -> String? {
        for outlineLine in outline.components(separatedBy: "\n") {
            let trimmedLine = outlineLine.trimmingCharacters(in: .whitespaces)
            guard trimmedLine.hasPrefix("[e"), let closingBracket = trimmedLine.firstIndex(of: "]") else { continue }
            let afterIdentifier = trimmedLine[trimmedLine.index(after: closingBracket)...].trimmingCharacters(in: .whitespaces)
            guard afterIdentifier.hasPrefix("button \""), afterIdentifier.count >= 10 else { continue }
            let titleCharacters = Array(afterIdentifier.dropFirst("button \"".count).prefix(2))
            if titleCharacters.count == 2, titleCharacters[0].isNumber, titleCharacters[1] == "\"" {
                return String(trimmedLine[trimmedLine.index(after: trimmedLine.startIndex)..<closingBracket])
            }
        }
        return nil
    }

    /// The first quoted title or value of an element line, which is on screen right now.
    static func firstQuotedText(in outline: String) -> String? {
        for outlineLine in outline.components(separatedBy: "\n") where outlineLine.trimmingCharacters(in: .whitespaces).hasPrefix("[e") {
            let quoteParts = outlineLine.components(separatedBy: "\"")
            if quoteParts.count >= 3, !quoteParts[1].isEmpty, !quoteParts[1].contains("\\") { return quoteParts[1] }
        }
        return nil
    }

    private static let mockUsage = ClaudeUsage(inputTokens: 1, outputTokens: 1, cacheCreationInputTokens: 0, cacheReadInputTokens: 0)
}
