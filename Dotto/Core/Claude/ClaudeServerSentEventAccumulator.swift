import Foundation

enum ClaudeStreamProgressEvent: Equatable, Sendable {
    case thinkingStarted
    case textDelta(String)
    case toolUseStarted(toolName: String)
    /// A fragment of a tool call's input as it streams. Only for progress: the input is parsed once the block is whole.
    case toolInputDelta(toolName: String, partialJSON: String)
}

enum ClaudeStreamError: Error, Equatable {
    case streamReportedError(ClaudeAPIErrorPayload)
    case malformedEvent(String)
    case streamEndedBeforeMessageStop
}

struct ClaudeServerSentEventAccumulator {
    /// The block as announced by content_block_start plus everything its deltas appended. Keeping the start
    /// object means fields we don't model survive into the assembled block.
    private struct StreamingContentBlock {
        var contentBlockStartObject: [String: JSONValue]
        var accumulatedText = ""
        var accumulatedThinking = ""
        var accumulatedSignature = ""
        var accumulatedPartialJSON = ""
    }

    private var messageIdentifier = ""
    private var model = ""
    private var usage = ClaudeUsage(inputTokens: 0, outputTokens: 0, cacheCreationInputTokens: nil, cacheReadInputTokens: nil)
    private var stopReasonAPIValue: String?
    private var refusalExplanation: String?
    private var streamingContentBlocksByIndex: [Int: StreamingContentBlock] = [:]
    private(set) var hasReceivedMessageStop = false

    init() {}

    /// Feed each line of the SSE body (with or without the "data: " prefix; non-data lines are ignored).
    mutating func consumeLine(_ serverSentEventLine: String) throws -> [ClaudeStreamProgressEvent] {
        let trimmedLine = serverSentEventLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let eventJSONText: String
        if trimmedLine.hasPrefix("data:") {
            eventJSONText = String(trimmedLine.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
        } else if trimmedLine.hasPrefix("{") {
            eventJSONText = trimmedLine
        } else {
            return []
        }
        guard let eventJSONValue = try? JSONValue(parsingJSONText: eventJSONText),
              let eventType = eventJSONValue["type"]?.stringValue else {
            throw ClaudeStreamError.malformedEvent(String(eventJSONText.prefix(200)))
        }

        switch eventType {
        case "message_start":
            messageIdentifier = eventJSONValue["message"]?["id"]?.stringValue ?? ""
            model = eventJSONValue["message"]?["model"]?.stringValue ?? ""
            if let usageJSONValue = eventJSONValue["message"]?["usage"] { mergeUsage(usageJSONValue) }
            return []
        case "content_block_start":
            guard let blockIndex = blockIndex(of: eventJSONValue),
                  let contentBlockStartObject = eventJSONValue["content_block"]?.objectValue else {
                throw ClaudeStreamError.malformedEvent(String(eventJSONText.prefix(200)))
            }
            streamingContentBlocksByIndex[blockIndex] = StreamingContentBlock(contentBlockStartObject: contentBlockStartObject)
            switch contentBlockStartObject["type"]?.stringValue {
            case "thinking": return [.thinkingStarted]
            case "tool_use": return [.toolUseStarted(toolName: contentBlockStartObject["name"]?.stringValue ?? "")]
            default: return []
            }
        case "content_block_delta":
            guard let blockIndex = blockIndex(of: eventJSONValue), streamingContentBlocksByIndex[blockIndex] != nil,
                  let delta = eventJSONValue["delta"] else {
                throw ClaudeStreamError.malformedEvent(String(eventJSONText.prefix(200)))
            }
            switch delta["type"]?.stringValue {
            case "text_delta":
                let textFragment = delta["text"]?.stringValue ?? ""
                streamingContentBlocksByIndex[blockIndex]?.accumulatedText += textFragment
                return [.textDelta(textFragment)]
            case "input_json_delta":
                let partialJSONFragment = delta["partial_json"]?.stringValue ?? ""
                streamingContentBlocksByIndex[blockIndex]?.accumulatedPartialJSON += partialJSONFragment
                let toolName = streamingContentBlocksByIndex[blockIndex]?.contentBlockStartObject["name"]?.stringValue ?? ""
                return partialJSONFragment.isEmpty ? [] : [.toolInputDelta(toolName: toolName, partialJSON: partialJSONFragment)]
            case "thinking_delta":
                streamingContentBlocksByIndex[blockIndex]?.accumulatedThinking += delta["thinking"]?.stringValue ?? ""
            case "signature_delta":
                streamingContentBlocksByIndex[blockIndex]?.accumulatedSignature += delta["signature"]?.stringValue ?? ""
            default:
                break
            }
            return []
        case "message_delta":
            if let stopReasonValue = eventJSONValue["delta"]?["stop_reason"]?.stringValue {
                stopReasonAPIValue = stopReasonValue
            }
            if let explanation = eventJSONValue["delta"]?["stop_details"]?["explanation"]?.stringValue {
                refusalExplanation = explanation
            }
            if let usageJSONValue = eventJSONValue["usage"] { mergeUsage(usageJSONValue) }
            return []
        case "message_stop":
            hasReceivedMessageStop = true
            return []
        case "error":
            let errorPayload = ClaudeAPIErrorPayload(
                errorType: eventJSONValue["error"]?["type"]?.stringValue ?? "unknown_error",
                message: eventJSONValue["error"]?["message"]?.stringValue ?? "")
            throw ClaudeStreamError.streamReportedError(errorPayload)
        default:
            // content_block_stop, ping and future event types carry nothing we need: blocks are assembled at the end.
            return []
        }
    }

    func assembledResponse() throws -> ClaudeMessagesResponse {
        guard hasReceivedMessageStop else { throw ClaudeStreamError.streamEndedBeforeMessageStop }
        let assembledContentBlocks = streamingContentBlocksByIndex.keys.sorted().compactMap { blockIndex in
            streamingContentBlocksByIndex[blockIndex].map(assembleContentBlock)
        }
        return ClaudeMessagesResponse(messageIdentifier: messageIdentifier, model: model, content: assembledContentBlocks,
                                      stopReason: ClaudeStopReason(apiValue: stopReasonAPIValue ?? ""),
                                      refusalExplanation: refusalExplanation, usage: usage)
    }

    private func assembleContentBlock(_ streamingContentBlock: StreamingContentBlock) -> ClaudeContentBlock {
        var blockObject = streamingContentBlock.contentBlockStartObject
        switch blockObject["type"]?.stringValue {
        case "text":
            blockObject["text"] = .string((blockObject["text"]?.stringValue ?? "") + streamingContentBlock.accumulatedText)
        case "thinking":
            blockObject["thinking"] = .string((blockObject["thinking"]?.stringValue ?? "") + streamingContentBlock.accumulatedThinking)
            blockObject["signature"] = .string((blockObject["signature"]?.stringValue ?? "") + streamingContentBlock.accumulatedSignature)
        case "tool_use":
            blockObject["input"] = parseToolInput(partialJSON: streamingContentBlock.accumulatedPartialJSON,
                                                  inputFromBlockStart: blockObject["input"])
        default:
            break
        }
        return ClaudeContentBlock(parsedFromJSONValue: .object(blockObject))
    }

    // Invalid JSON must not throw: every tool_use id needs a tool_result, so the loop answers the sentinel with is_error.
    private func parseToolInput(partialJSON: String, inputFromBlockStart: JSONValue?) -> JSONValue {
        if partialJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return inputFromBlockStart ?? .object([:])
        }
        if let parsedInput = try? JSONValue(parsingJSONText: partialJSON), parsedInput.objectValue != nil {
            return parsedInput
        }
        return .object([AgentToolCallDecoder.invalidJSONSentinelKey: .string(partialJSON)])
    }

    private func blockIndex(of eventJSONValue: JSONValue) -> Int? {
        eventJSONValue["index"]?.numberValue.map { Int($0) }
    }

    private mutating func mergeUsage(_ usageJSONValue: JSONValue) {
        if let inputTokens = usageJSONValue["input_tokens"]?.numberValue { usage.inputTokens = Int(inputTokens) }
        if let outputTokens = usageJSONValue["output_tokens"]?.numberValue { usage.outputTokens = Int(outputTokens) }
        if let cacheCreationTokens = usageJSONValue["cache_creation_input_tokens"]?.numberValue {
            usage.cacheCreationInputTokens = Int(cacheCreationTokens)
        }
        if let cacheReadTokens = usageJSONValue["cache_read_input_tokens"]?.numberValue {
            usage.cacheReadInputTokens = Int(cacheReadTokens)
        }
    }
}
