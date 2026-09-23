import Foundation

/// Recorded shape of a streamed executor turn: thinking with a split signature, text, and two tool_use blocks
/// whose input arrives in many input_json_delta fragments. Includes event:/blank lines the accumulator must skip.
private let recordedToolUseStreamLines: [String] = [
    "event: message_start",
    #"data: {"type":"message_start","message":{"id":"msg_01","type":"message","role":"assistant","model":"claude-sonnet-5","content":[],"stop_reason":null,"usage":{"input_tokens":1200,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":900}}}"#,
    "",
    #"data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}"#,
    #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Find the "}}"#,
    #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"row."}}"#,
    #"data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"EqQB"}}"#,
    #"data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"xyz=="}}"#,
    #"data: {"type":"content_block_stop","index":0}"#,
    "event: ping",
    #"data: {"type":"ping"}"#,
    #"data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
    #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Renaming "}}"#,
    #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"now."}}"#,
    #"data: {"type":"content_block_stop","index":1}"#,
    #"data: {"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_A","name":"click","input":{}}}"#,
    #"data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":""}}"#,
    #"data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"element_"}}"#,
    #"data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"id\": \"e1"}}"#,
    #"data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"2\", \"click_type\""}}"#,
    #"data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":": \"single\"}"}}"#,
    #"data: {"type":"content_block_stop","index":2}"#,
    #"data:{"type":"content_block_start","index":3,"content_block":{"type":"tool_use","id":"toolu_B","name":"finish_item","input":{}}}"#,
    #"data: {"type":"content_block_delta","index":3,"delta":{"type":"input_json_delta","partial_json":"{\"outcome\":\"comp"}}"#,
    #"data: {"type":"content_block_delta","index":3,"delta":{"type":"input_json_delta","partial_json":"leted\",\"summary\":\"Done.\"}"}}"#,
    #"{"type":"content_block_stop","index":3}"#,
    #"data: {"type":"message_delta","delta":{"stop_reason":"tool_use","stop_details":null},"usage":{"output_tokens":123}}"#,
    #"data: {"type":"message_stop"}"#,
]

private func accumulate(_ streamLines: [String]) throws -> (accumulator: ClaudeServerSentEventAccumulator, progressEvents: [ClaudeStreamProgressEvent]) {
    var accumulator = ClaudeServerSentEventAccumulator()
    var progressEvents: [ClaudeStreamProgressEvent] = []
    for streamLine in streamLines {
        progressEvents += try accumulator.consumeLine(streamLine)
    }
    return (accumulator, progressEvents)
}

private func singleToolUseStream(partialJSONFragments: [String], stopReason: String = "tool_use") -> [String] {
    var streamLines = [
        #"data: {"type":"message_start","message":{"id":"msg_2","model":"claude-sonnet-5","role":"assistant","content":[],"usage":{"input_tokens":5,"output_tokens":1}}}"#,
        #"data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_X","name":"click","input":{}}}"#,
    ]
    for partialJSONFragment in partialJSONFragments {
        let deltaObject = JSONValue.object(["type": .string("content_block_delta"), "index": .number(0),
                                            "delta": .object(["type": .string("input_json_delta"), "partial_json": .string(partialJSONFragment)])])
        streamLines.append("data: " + String(decoding: try! JSONEncoder().encode(deltaObject), as: UTF8.self))
    }
    streamLines += [
        #"data: {"type":"content_block_stop","index":0}"#,
        #"data: {"type":"message_delta","delta":{"stop_reason":"\#(stopReason)"},"usage":{"output_tokens":9}}"#,
        #"data: {"type":"message_stop"}"#,
    ]
    return streamLines
}

let claudeServerSentEventAccumulatorTestSuite = CoreTestSuite(name: "ClaudeServerSentEventAccumulator", testCases: [
    CoreTestCase(name: "recorded stream assembles thinking+signature, text and two fragmented tool_use blocks") {
        let (accumulator, progressEvents) = try accumulate(recordedToolUseStreamLines)
        let progressEventsWithoutInputFragments = progressEvents.filter { progressEvent in
            if case .toolInputDelta = progressEvent { return false }
            return true
        }
        try expectEqual(progressEventsWithoutInputFragments, [.thinkingStarted, .textDelta("Renaming "), .textDelta("now."),
                                                              .toolUseStarted(toolName: "click"), .toolUseStarted(toolName: "finish_item")])
        let streamedToolInput = progressEvents.compactMap { progressEvent -> String? in
            if case .toolInputDelta(let toolName, let partialJSON) = progressEvent, toolName == "click" { return partialJSON }
            return nil
        }.joined()
        try expectTrue(streamedToolInput.contains("element_id"), "each tool's input fragments are reported under its own name")
        try expectTrue(accumulator.hasReceivedMessageStop)
        let assembledResponse = try accumulator.assembledResponse()
        try expectEqual(assembledResponse.messageIdentifier, "msg_01")
        try expectEqual(assembledResponse.model, "claude-sonnet-5")
        try expectEqual(assembledResponse.stopReason, .toolUse)
        try expectEqual(assembledResponse.usage, ClaudeUsage(inputTokens: 1200, outputTokens: 123, cacheCreationInputTokens: 0, cacheReadInputTokens: 900))
        try expectEqual(assembledResponse.content, [
            .thinking(ClaudeThinkingBlock(thinkingText: "Find the row.", signature: "EqQBxyz==")),
            .text(ClaudeTextBlock(text: "Renaming now.", cacheControl: nil)),
            .toolUse(ClaudeToolUseBlock(toolUseIdentifier: "toolu_A", toolName: "click",
                                        input: .object(["element_id": .string("e12"), "click_type": .string("single")]))),
            .toolUse(ClaudeToolUseBlock(toolUseIdentifier: "toolu_B", toolName: "finish_item",
                                        input: .object(["outcome": .string("completed"), "summary": .string("Done.")]))),
        ])
        try expectEqual(assembledResponse.toolUseBlocks.map(\.toolUseIdentifier), ["toolu_A", "toolu_B"])
        try expectEqual(assembledResponse.assistantMessageForHistory.content, assembledResponse.content)
    },
    CoreTestCase(name: "stream error event throws streamReportedError") {
        var accumulator = ClaudeServerSentEventAccumulator()
        _ = try accumulator.consumeLine(recordedToolUseStreamLines[1])
        let thrownError = try expectThrowsError {
            _ = try accumulator.consumeLine(#"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)
        }
        try expectEqual(thrownError as? ClaudeStreamError,
                        .streamReportedError(ClaudeAPIErrorPayload(errorType: "overloaded_error", message: "Overloaded")))
    },
    CoreTestCase(name: "invalid tool JSON becomes the sentinel input instead of throwing, and decodes to INVALID_JSON") {
        let (accumulator, _) = try accumulate(singleToolUseStream(partialJSONFragments: [#"{"element_id": "e1"#]))
        let toolUseBlock = try unwrapOrFail(try accumulator.assembledResponse().toolUseBlocks.first)
        try expectEqual(toolUseBlock.input, .object([AgentToolCallDecoder.invalidJSONSentinelKey: .string(#"{"element_id": "e1"#)]))
        guard case .failure(let inputError) = AgentToolCallDecoder.decodeToolCall(toolUseBlock) else {
            throw CoreTestFailure(description: "sentinel input must fail decoding")
        }
        try expectEqual(inputError.messageForModel, #"{"INVALID_JSON":"{\"element_id\": \"e1"}"#)
    },
    CoreTestCase(name: "tool_use without input deltas gets an empty object") {
        let (accumulator, _) = try accumulate(singleToolUseStream(partialJSONFragments: []))
        try expectEqual(try accumulator.assembledResponse().toolUseBlocks.first?.input, .object([:]))
    },
    CoreTestCase(name: "stream without message_stop cannot be assembled") {
        let (accumulator, _) = try accumulate(Array(recordedToolUseStreamLines.dropLast()))
        try expectTrue(!accumulator.hasReceivedMessageStop)
        let thrownError = try expectThrowsError { _ = try accumulator.assembledResponse() }
        try expectEqual(thrownError as? ClaudeStreamError, .streamEndedBeforeMessageStop)
    },
    CoreTestCase(name: "refusal stop reason carries stop_details explanation") {
        let (accumulator, _) = try accumulate([
            #"data: {"type":"message_start","message":{"id":"msg_3","model":"claude-opus-5-5","usage":{"input_tokens":3}}}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"refusal","stop_details":{"explanation":"Not allowed."}},"usage":{"output_tokens":1}}"#,
            #"data: {"type":"message_stop"}"#,
        ])
        let assembledResponse = try accumulator.assembledResponse()
        try expectEqual(assembledResponse.stopReason, .refusal)
        try expectEqual(assembledResponse.refusalExplanation, "Not allowed.")
        try expectEqual(assembledResponse.content, [])
    },
    CoreTestCase(name: "redacted thinking and unknown blocks are kept verbatim") {
        let (accumulator, progressEvents) = try accumulate([
            #"data: {"type":"message_start","message":{"id":"msg_4","model":"claude-sonnet-5","usage":{"input_tokens":3}}}"#,
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"redacted_thinking","data":"opaque=="}}"#,
            #"data: {"type":"content_block_stop","index":0}"#,
            #"data: {"type":"content_block_start","index":1,"content_block":{"type":"future_block","payload":{"level":2}}}"#,
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"future_delta","anything":true}}"#,
            #"data: {"type":"content_block_stop","index":1}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":4}}"#,
            #"data: {"type":"message_stop"}"#,
        ])
        try expectEqual(progressEvents, [])
        try expectEqual(try accumulator.assembledResponse().content, [
            .redactedThinking(ClaudeRedactedThinkingBlock(opaqueData: "opaque==")),
            .unrecognized(.object(["type": .string("future_block"), "payload": .object(["level": .number(2)])])),
        ])
    },
    CoreTestCase(name: "malformed data line throws malformedEvent; comment and event lines are ignored") {
        var accumulator = ClaudeServerSentEventAccumulator()
        try expectEqual(try accumulator.consumeLine(": keep-alive"), [])
        try expectEqual(try accumulator.consumeLine("event: message_start"), [])
        let thrownError = try expectThrowsError { _ = try accumulator.consumeLine("data: {not json") }
        guard case .malformedEvent? = thrownError as? ClaudeStreamError else {
            throw CoreTestFailure(description: "expected malformedEvent, got \(thrownError)")
        }
    },
])
