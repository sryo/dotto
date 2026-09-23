import Foundation

private func encodedText(_ request: ClaudeMessagesRequest) throws -> String {
    String(decoding: try ClaudeRequestEncoding.encodeRequestBody(request), as: UTF8.self)
}

private func sortedJSONText<EncodableValue: Encodable>(_ encodableValue: EncodableValue) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(encodableValue), as: UTF8.self)
}

private let goldenConversationMessages: [ClaudeMessage] = [
    ClaudeMessage(role: .user, content: [.text(ClaudeTextBlock(text: "hi", cacheControl: nil))]),
    ClaudeMessage(role: .assistant, content: [
        .thinking(ClaudeThinkingBlock(thinkingText: "", signature: "EqQB")),
        .toolUse(ClaudeToolUseBlock(toolUseIdentifier: "toolu_01A", toolName: "click",
                                    input: .object(["element_id": .string("e12"), "click_type": .string("single")]))),
    ]),
    ClaudeMessage(role: .user, content: [
        .toolResult(ClaudeToolResultBlock(toolUseIdentifier: "toolu_01A", content: [.text("ok")], isError: false)),
        .toolResult(ClaudeToolResultBlock(toolUseIdentifier: "toolu_01B", content: [.text("bad")], isError: true)),
    ]),
]

let claudeRequestEncodingTestSuite = CoreTestSuite(name: "ClaudeRequestEncoding", testCases: [
    CoreTestCase(name: "golden request JSON has sorted keys, strict tools, auto tool choice, adaptive thinking and both cache breakpoints") {
        let request = ClaudeMessagesRequest(
            model: "claude-sonnet-5", maximumOutputTokens: 16000, isStreaming: true, effort: "medium",
            usesAdaptiveThinking: true, usesAutomaticConversationCacheBreakpoint: true,
            system: [ClaudeSystemTextBlock(text: "SYS", cacheControl: .ephemeral)],
            tools: [ClaudeToolDefinition(name: "t", description: "d",
                                         inputSchema: try JSONValue(parsingJSONText: #"{"type":"object","properties":{},"required":[],"additionalProperties":false}"#),
                                         isStrict: true)],
            messages: goldenConversationMessages)
        let expectedJSONText = #"{"cache_control":{"type":"ephemeral"},"max_tokens":16000,"messages":[{"content":[{"text":"hi","type":"text"}],"role":"user"},{"content":[{"signature":"EqQB","thinking":"","type":"thinking"},{"id":"toolu_01A","input":{"click_type":"single","element_id":"e12"},"name":"click","type":"tool_use"}],"role":"assistant"},{"content":[{"content":[{"text":"ok","type":"text"}],"tool_use_id":"toolu_01A","type":"tool_result"},{"content":[{"text":"bad","type":"text"}],"is_error":true,"tool_use_id":"toolu_01B","type":"tool_result"}],"role":"user"}],"model":"claude-sonnet-5","output_config":{"effort":"medium"},"stream":true,"system":[{"cache_control":{"type":"ephemeral"},"text":"SYS","type":"text"}],"thinking":{"type":"adaptive"},"tool_choice":{"type":"auto"},"tools":[{"description":"d","input_schema":{"additionalProperties":false,"properties":{},"required":[],"type":"object"},"name":"t","strict":true}]}"#
        try expectEqual(try encodedText(request), expectedJSONText)
    },
    CoreTestCase(name: "encoding the same request twice is byte-identical") {
        let request = PromptLibrary.makeExecutorRequest(conversationMessages: goldenConversationMessages)
        try expectEqual(try ClaudeRequestEncoding.encodeRequestBody(request), try ClaudeRequestEncoding.encodeRequestBody(request))
    },
    CoreTestCase(name: "request without tools omits tools and tool_choice; disabled flags omit thinking and cache_control") {
        let request = ClaudeMessagesRequest(model: "claude-sonnet-5", maximumOutputTokens: 100, isStreaming: false, effort: "low",
                                            usesAdaptiveThinking: false, usesAutomaticConversationCacheBreakpoint: false,
                                            system: [], tools: [], messages: [])
        try expectEqual(try encodedText(request),
                        #"{"max_tokens":100,"messages":[],"model":"claude-sonnet-5","output_config":{"effort":"low"},"stream":false}"#)
    },
    CoreTestCase(name: "planner and executor factories use the configured models, effort and exactly two cache breakpoints") {
        let plannerRequest = PromptLibrary.makePlannerRequest(conversationMessages: [])
        try expectEqual(plannerRequest.model, "claude-opus-5-5")
        try expectEqual(plannerRequest.effort, "medium")
        try expectEqual(plannerRequest.tools.map(\.name), AgentToolCatalog.plannerTools.map(\.name))
        let executorRequest = PromptLibrary.makeExecutorRequest(conversationMessages: goldenConversationMessages)
        try expectEqual(executorRequest.model, "claude-sonnet-5")
        try expectEqual(executorRequest.effort, "medium")
        let executorJSONText = try encodedText(executorRequest)
        try expectEqual(executorJSONText.components(separatedBy: #""cache_control""#).count - 1, 2)
        try expectTrue(executorJSONText.hasPrefix(#"{"cache_control":{"type":"ephemeral"},"max_tokens":16000,"#))
        try expectTrue(executorJSONText.contains(#""stream":true"#))
        for forbiddenField in ["temperature", "top_p", "top_k", "budget_tokens", "\"disabled\""] {
            try expectTrue(!executorJSONText.contains(forbiddenField), "must not send \(forbiddenField)")
        }
    },
    CoreTestCase(name: "assistant blocks round-trip verbatim: thinking signature, redacted thinking, unknown types, extra fields") {
        let assistantMessageJSONText = #"{"content":[{"signature":"sig==","thinking":"hmm","type":"thinking"},{"data":"opaque","type":"redacted_thinking"},{"bar":{"baz":true},"foo":[1,2.5,null],"type":"future_block"},{"citations":null,"text":"hello","type":"text"},{"id":"toolu_9","input":{"pages":3},"name":"scroll","type":"tool_use"}],"role":"assistant"}"#
        let decodedMessage = try JSONDecoder().decode(ClaudeMessage.self, from: Data(assistantMessageJSONText.utf8))
        try expectEqual(decodedMessage.content[0], .thinking(ClaudeThinkingBlock(thinkingText: "hmm", signature: "sig==")))
        try expectEqual(decodedMessage.content[1], .redactedThinking(ClaudeRedactedThinkingBlock(opaqueData: "opaque")))
        guard case .unrecognized = decodedMessage.content[2] else { throw CoreTestFailure(description: "future_block should be unrecognized") }
        guard case .unrecognized = decodedMessage.content[3] else { throw CoreTestFailure(description: "text with citations should be kept verbatim") }
        try expectEqual(try sortedJSONText(decodedMessage), assistantMessageJSONText)
    },
    CoreTestCase(name: "tool_result with image and string content decode") {
        let userMessageJSONText = #"{"content":[{"content":[{"text":"Screenshot","type":"text"},{"source":{"data":"QUJD","media_type":"image/jpeg","type":"base64"},"type":"image"}],"tool_use_id":"toolu_1","type":"tool_result"},{"content":"plain","is_error":true,"tool_use_id":"toolu_2","type":"tool_result"}],"role":"user"}"#
        let decodedMessage = try JSONDecoder().decode(ClaudeMessage.self, from: Data(userMessageJSONText.utf8))
        try expectEqual(decodedMessage.content, [
            .toolResult(ClaudeToolResultBlock(toolUseIdentifier: "toolu_1", content: [
                .text("Screenshot"), .image(ClaudeImageBlock(mediaType: "image/jpeg", base64EncodedData: "QUJD"))], isError: false)),
            .toolResult(ClaudeToolResultBlock(toolUseIdentifier: "toolu_2", content: [.text("plain")], isError: true)),
        ])
    },
    CoreTestCase(name: "non-streaming response decodes stop reason, refusal explanation and usage") {
        let responseJSONText = #"{"id":"msg_1","type":"message","role":"assistant","model":"claude-opus-5-5","content":[{"type":"text","text":"no"}],"stop_reason":"refusal","stop_details":{"explanation":"policy"},"usage":{"input_tokens":10,"output_tokens":2,"cache_read_input_tokens":7}}"#
        let decodedResponse = try ClaudeMessagesResponse.decodingNonStreamingJSON(Data(responseJSONText.utf8))
        try expectEqual(decodedResponse.messageIdentifier, "msg_1")
        try expectEqual(decodedResponse.stopReason, .refusal)
        try expectEqual(decodedResponse.refusalExplanation, "policy")
        try expectEqual(decodedResponse.usage, ClaudeUsage(inputTokens: 10, outputTokens: 2, cacheCreationInputTokens: nil, cacheReadInputTokens: 7))
        try expectEqual(decodedResponse.assistantMessageForHistory,
                        ClaudeMessage(role: .assistant, content: [.text(ClaudeTextBlock(text: "no", cacheControl: nil))]))
        try expectEqual(decodedResponse.toolUseBlocks, [])
    },
    CoreTestCase(name: "stop reasons map from API values") {
        try expectEqual(ClaudeStopReason(apiValue: "end_turn"), .endTurn)
        try expectEqual(ClaudeStopReason(apiValue: "tool_use"), .toolUse)
        try expectEqual(ClaudeStopReason(apiValue: "max_tokens"), .maxTokens)
        try expectEqual(ClaudeStopReason(apiValue: "pause_turn"), .pauseTurn)
        try expectEqual(ClaudeStopReason(apiValue: "stop_sequence"), .stopSequence)
        try expectEqual(ClaudeStopReason(apiValue: "model_context_window_exceeded"), .other("model_context_window_exceeded"))
    },
    CoreTestCase(name: "API error payload decodes from the error envelope") {
        let errorPayload = try JSONDecoder().decode(ClaudeAPIErrorPayload.self,
            from: Data(#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#.utf8))
        try expectEqual(errorPayload, ClaudeAPIErrorPayload(errorType: "overloaded_error", message: "Overloaded"))
    },
    CoreTestCase(name: "JSONValue keeps booleans and numbers apart and encodes integers without a fraction") {
        try expectEqual(try JSONValue(parsingJSONText: "true"), .bool(true))
        try expectEqual(try JSONValue(parsingJSONText: "1"), .number(1))
        try expectEqual(try JSONValue(parsingJSONText: "0"), .number(0))
        try expectEqual(try JSONValue(parsingJSONText: #"{"flag":false,"count":0,"list":[1,true,null,"x"]}"#),
                        .object(["flag": .bool(false), "count": .number(0), "list": .array([.number(1), .bool(true), .null, .string("x")])]))
        try expectEqual(try sortedJSONText(JSONValue.object(["pages": .number(12), "ratio": .number(0.5)])), #"{"pages":12,"ratio":0.5}"#)
        try expectEqual(JSONValue.object(["key": .string("value")])["key"]?.stringValue, "value")
    },
])
