import Foundation
import CoreGraphics

private func mockRequest(tools: [ClaudeToolDefinition], messages: [ClaudeMessage]) -> ClaudeMessagesRequest {
    ClaudeMessagesRequest(model: ClaudeModelConfiguration.executorModelIdentifier, maximumOutputTokens: 1000, isStreaming: true,
                          effort: "low", usesAdaptiveThinking: false, usesAutomaticConversationCacheBreakpoint: false, system: [],
                          tools: tools, messages: messages)
}

private func userText(_ text: String) -> ClaudeMessage {
    ClaudeMessage(role: .user, content: [.text(ClaudeTextBlock(text: text, cacheControl: nil))])
}

private func toolResult(_ text: String) -> ClaudeMessage {
    ClaudeMessage(role: .user, content: [.toolResult(ClaudeToolResultBlock(toolUseIdentifier: "toolu_1", content: [.text(text)], isError: false))])
}

private let textEditOutline = """
app="TextEdit" window="notes.txt" scope=focused_window snapshot=1 elements=4 shown=3
[e1] window "notes.txt"
  [e2] textarea value="hello"
"""

private let calculatorOutline = """
app="Calculator" scope=focused_window snapshot=1 elements=4 shown=3
[e1] window "Calculator"
  [e5] button "AC"
  [e6] button "7"
"""

let claudeMockConversationScriptTestSuite = CoreTestSuite(name: "ClaudeMockConversationScript", testCases: [
    CoreTestCase(name: "the planner reads the window, then submits a two-item plan naming the target app") {
        let plannerTools = AgentToolCatalog.plannerTools
        let firstTurn = ClaudeMockConversationScript.response(
            to: mockRequest(tools: plannerTools, messages: [userText("Command: tidy\nTarget app: TextEdit (frontmost when the user summoned Dotto)")]),
            responseNumber: 1)
        try expectEqual(firstTurn.toolUseBlocks.map(\.toolName), ["read_ui"])
        let secondTurn = ClaudeMockConversationScript.response(
            to: mockRequest(tools: plannerTools, messages: [userText("Target app: TextEdit (x)"), toolResult(textEditOutline)]),
            responseNumber: 2)
        let submitPlan = try unwrapOrFail(secondTurn.toolUseBlocks.first)
        try expectEqual(submitPlan.toolName, "submit_plan")
        try expectEqual(submitPlan.input["task_title"]?.stringValue, "Mock task in TextEdit")
        try expectEqual(submitPlan.input["items"]?.arrayValue?.count, 2)
    },
    CoreTestCase(name: "an item inserts a line into a text area, or presses a digit key, then finishes with on-screen evidence") {
        let executorTools = AgentToolCatalog.executorTools
        let textEditTurn = ClaudeMockConversationScript.response(
            to: mockRequest(tools: executorTools, messages: [userText("Target app: TextEdit\nCurrent UI outline:\n" + textEditOutline)]),
            responseNumber: 1)
        let replaceText = try unwrapOrFail(textEditTurn.toolUseBlocks.first)
        try expectEqual(replaceText.toolName, "replace_text")
        try expectEqual(replaceText.input["element_id"]?.stringValue, "e2")
        try expectEqual(replaceText.input["position"]?.stringValue, "end")

        let calculatorTurn = ClaudeMockConversationScript.response(
            to: mockRequest(tools: executorTools, messages: [userText("Target app: Calculator\nCurrent UI outline:\n" + calculatorOutline)]),
            responseNumber: 1)
        let click = try unwrapOrFail(calculatorTurn.toolUseBlocks.first)
        try expectEqual(click.toolName, "click")
        try expectEqual(click.input["element_id"]?.stringValue, "e6")

        let finishTurn = ClaudeMockConversationScript.response(
            to: mockRequest(tools: executorTools, messages: [userText("Target app: Calculator"), toolResult("ok\n" + calculatorOutline)]),
            responseNumber: 2)
        let finishItem = try unwrapOrFail(finishTurn.toolUseBlocks.first)
        try expectEqual(finishItem.toolName, "finish_item")
        try expectEqual(finishItem.input["outcome"]?.stringValue, "completed")
        try expectEqual(finishItem.input["evidence"]?["text"]?.stringValue, "Calculator")
    },
    CoreTestCase(name: "every mock tool call decodes as the app's own tool calls") {
        let executorTools = AgentToolCatalog.executorTools
        for outline in [textEditOutline, calculatorOutline] {
            let turn = ClaudeMockConversationScript.response(
                to: mockRequest(tools: executorTools, messages: [userText("Current UI outline:\n" + outline)]), responseNumber: 1)
            let decoded = AgentToolCallDecoder.decodeToolCall(try unwrapOrFail(turn.toolUseBlocks.first))
            if case .failure(let decodingError) = decoded { throw CoreTestFailure(description: "\(decodingError)") }
        }
    },
])
