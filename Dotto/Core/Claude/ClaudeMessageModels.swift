import Foundation

enum ClaudeMessageRole: String, Codable, Sendable { case user, assistant }

struct ClaudeCacheControl: Codable, Equatable, Sendable {
    var type: String = "ephemeral"
    static let ephemeral = ClaudeCacheControl()
}

struct ClaudeTextBlock: Equatable, Sendable { var text: String; var cacheControl: ClaudeCacheControl? }
struct ClaudeImageBlock: Equatable, Sendable { var mediaType: String; var base64EncodedData: String }
struct ClaudeToolUseBlock: Equatable, Sendable { var toolUseIdentifier: String; var toolName: String; var input: JSONValue }
enum ClaudeToolResultContent: Equatable, Sendable { case text(String); case image(ClaudeImageBlock) }
struct ClaudeToolResultBlock: Equatable, Sendable { var toolUseIdentifier: String; var content: [ClaudeToolResultContent]; var isError: Bool }
struct ClaudeThinkingBlock: Equatable, Sendable { var thinkingText: String; var signature: String }
struct ClaudeRedactedThinkingBlock: Equatable, Sendable { var opaqueData: String }

/// Content blocks are converted through `JSONValue` in both directions so that any block the app does not
/// model exactly (unknown types, or known types carrying extra fields) is replayed to the API byte-for-byte.
enum ClaudeContentBlock: Codable, Equatable, Sendable {
    case text(ClaudeTextBlock)
    case image(ClaudeImageBlock)
    case toolUse(ClaudeToolUseBlock)
    case toolResult(ClaudeToolResultBlock)
    case thinking(ClaudeThinkingBlock)
    case redactedThinking(ClaudeRedactedThinkingBlock)
    case unrecognized(JSONValue)

    init(from decoder: Decoder) throws {
        self.init(parsedFromJSONValue: try JSONValue(from: decoder))
    }

    func encode(to encoder: Encoder) throws {
        try jsonRepresentation.encode(to: encoder)
    }

    init(parsedFromJSONValue blockJSONValue: JSONValue) {
        self = ClaudeContentBlock.parseKnownBlock(blockJSONValue) ?? .unrecognized(blockJSONValue)
    }

    private static func parseKnownBlock(_ blockJSONValue: JSONValue) -> ClaudeContentBlock? {
        guard let blockObject = blockJSONValue.objectValue, let blockType = blockObject["type"]?.stringValue else { return nil }
        // A known type with fields we don't model is kept as .unrecognized, otherwise re-encoding would
        // silently drop them and break the byte-identical history the API expects.
        func hasOnlyKeys(_ allowedKeys: Set<String>) -> Bool { Set(blockObject.keys).isSubset(of: allowedKeys) }

        switch blockType {
        case "text":
            guard hasOnlyKeys(["type", "text", "cache_control"]), let text = blockObject["text"]?.stringValue else { return nil }
            var cacheControl: ClaudeCacheControl?
            if let cacheControlType = blockObject["cache_control"]?["type"]?.stringValue {
                cacheControl = ClaudeCacheControl(type: cacheControlType)
            }
            return .text(ClaudeTextBlock(text: text, cacheControl: cacheControl))
        case "image":
            guard hasOnlyKeys(["type", "source"]), let imageBlock = parseImageBlock(blockJSONValue) else { return nil }
            return .image(imageBlock)
        case "tool_use":
            guard let toolUseIdentifier = blockObject["id"]?.stringValue, let toolName = blockObject["name"]?.stringValue else { return nil }
            return .toolUse(ClaudeToolUseBlock(toolUseIdentifier: toolUseIdentifier, toolName: toolName,
                                               input: blockObject["input"] ?? .object([:])))
        case "tool_result":
            guard let toolUseIdentifier = blockObject["tool_use_id"]?.stringValue else { return nil }
            var resultContent: [ClaudeToolResultContent] = []
            if let plainTextContent = blockObject["content"]?.stringValue {
                resultContent = [.text(plainTextContent)]
            } else if let contentArray = blockObject["content"]?.arrayValue {
                for contentElement in contentArray {
                    if contentElement["type"]?.stringValue == "text", let text = contentElement["text"]?.stringValue {
                        resultContent.append(.text(text))
                    } else if let imageBlock = parseImageBlock(contentElement) {
                        resultContent.append(.image(imageBlock))
                    } else {
                        return nil
                    }
                }
            }
            return .toolResult(ClaudeToolResultBlock(toolUseIdentifier: toolUseIdentifier, content: resultContent,
                                                     isError: blockObject["is_error"]?.boolValue ?? false))
        case "thinking":
            guard hasOnlyKeys(["type", "thinking", "signature"]),
                  let thinkingText = blockObject["thinking"]?.stringValue,
                  let signature = blockObject["signature"]?.stringValue else { return nil }
            return .thinking(ClaudeThinkingBlock(thinkingText: thinkingText, signature: signature))
        case "redacted_thinking":
            guard hasOnlyKeys(["type", "data"]), let opaqueData = blockObject["data"]?.stringValue else { return nil }
            return .redactedThinking(ClaudeRedactedThinkingBlock(opaqueData: opaqueData))
        default:
            return nil
        }
    }

    private static func parseImageBlock(_ imageJSONValue: JSONValue) -> ClaudeImageBlock? {
        guard imageJSONValue["type"]?.stringValue == "image",
              imageJSONValue["source"]?["type"]?.stringValue == "base64",
              let mediaType = imageJSONValue["source"]?["media_type"]?.stringValue,
              let base64EncodedData = imageJSONValue["source"]?["data"]?.stringValue else { return nil }
        return ClaudeImageBlock(mediaType: mediaType, base64EncodedData: base64EncodedData)
    }

    private static func imageJSONRepresentation(_ imageBlock: ClaudeImageBlock) -> JSONValue {
        .object(["type": .string("image"),
                 "source": .object(["type": .string("base64"),
                                    "media_type": .string(imageBlock.mediaType),
                                    "data": .string(imageBlock.base64EncodedData)])])
    }

    var jsonRepresentation: JSONValue {
        switch self {
        case .text(let textBlock):
            var textObject: [String: JSONValue] = ["type": .string("text"), "text": .string(textBlock.text)]
            if let cacheControl = textBlock.cacheControl {
                textObject["cache_control"] = .object(["type": .string(cacheControl.type)])
            }
            return .object(textObject)
        case .image(let imageBlock):
            return ClaudeContentBlock.imageJSONRepresentation(imageBlock)
        case .toolUse(let toolUseBlock):
            return .object(["type": .string("tool_use"), "id": .string(toolUseBlock.toolUseIdentifier),
                            "name": .string(toolUseBlock.toolName), "input": toolUseBlock.input])
        case .toolResult(let toolResultBlock):
            let contentArray: [JSONValue] = toolResultBlock.content.map { resultContent in
                switch resultContent {
                case .text(let text): return .object(["type": .string("text"), "text": .string(text)])
                case .image(let imageBlock): return ClaudeContentBlock.imageJSONRepresentation(imageBlock)
                }
            }
            var toolResultObject: [String: JSONValue] = ["type": .string("tool_result"),
                                                         "tool_use_id": .string(toolResultBlock.toolUseIdentifier),
                                                         "content": .array(contentArray)]
            if toolResultBlock.isError { toolResultObject["is_error"] = .bool(true) }
            return .object(toolResultObject)
        case .thinking(let thinkingBlock):
            return .object(["type": .string("thinking"), "thinking": .string(thinkingBlock.thinkingText),
                            "signature": .string(thinkingBlock.signature)])
        case .redactedThinking(let redactedThinkingBlock):
            return .object(["type": .string("redacted_thinking"), "data": .string(redactedThinkingBlock.opaqueData)])
        case .unrecognized(let rawBlockJSONValue):
            return rawBlockJSONValue
        }
    }
}

extension ClaudeContentBlock {
    /// A text block without a cache breakpoint, the only kind Dotto itself writes into a conversation.
    static func plainText(_ text: String) -> ClaudeContentBlock {
        .text(ClaudeTextBlock(text: text, cacheControl: nil))
    }
}

struct ClaudeMessage: Codable, Equatable, Sendable {
    var role: ClaudeMessageRole
    var content: [ClaudeContentBlock]
}

struct ClaudeSystemTextBlock: Encodable, Equatable, Sendable {
    var text: String
    var cacheControl: ClaudeCacheControl?

    private enum CodingKeys: String, CodingKey { case type, text, cacheControl = "cache_control" }

    func encode(to encoder: Encoder) throws {
        var keyedContainer = encoder.container(keyedBy: CodingKeys.self)
        try keyedContainer.encode("text", forKey: .type)
        try keyedContainer.encode(text, forKey: .text)
        try keyedContainer.encodeIfPresent(cacheControl, forKey: .cacheControl)
    }
}

struct ClaudeToolDefinition: Encodable, Equatable, Sendable {
    var name: String
    var description: String
    var inputSchema: JSONValue
    var isStrict: Bool

    private enum CodingKeys: String, CodingKey { case name, description, inputSchema = "input_schema", isStrict = "strict" }
}

struct ClaudeMessagesRequest: Encodable, Equatable, Sendable {
    var model: String
    var maximumOutputTokens: Int
    var isStreaming: Bool
    var effort: String
    var usesAdaptiveThinking: Bool
    var usesAutomaticConversationCacheBreakpoint: Bool
    var system: [ClaudeSystemTextBlock]
    var tools: [ClaudeToolDefinition]
    var messages: [ClaudeMessage]

    private enum CodingKeys: String, CodingKey {
        case model, maximumOutputTokens = "max_tokens", isStreaming = "stream", outputConfiguration = "output_config"
        case thinking, cacheControl = "cache_control", system, tools, toolChoice = "tool_choice", messages
    }

    func encode(to encoder: Encoder) throws {
        var keyedContainer = encoder.container(keyedBy: CodingKeys.self)
        try keyedContainer.encode(model, forKey: .model)
        try keyedContainer.encode(maximumOutputTokens, forKey: .maximumOutputTokens)
        try keyedContainer.encode(isStreaming, forKey: .isStreaming)
        try keyedContainer.encode(["effort": effort], forKey: .outputConfiguration)
        if usesAdaptiveThinking {
            try keyedContainer.encode(["type": "adaptive"], forKey: .thinking)
        }
        if usesAutomaticConversationCacheBreakpoint {
            try keyedContainer.encode(ClaudeCacheControl.ephemeral, forKey: .cacheControl)
        }
        if !system.isEmpty {
            try keyedContainer.encode(system, forKey: .system)
        }
        if !tools.isEmpty {
            try keyedContainer.encode(tools, forKey: .tools)
            try keyedContainer.encode(["type": "auto"], forKey: .toolChoice)
        }
        try keyedContainer.encode(messages, forKey: .messages)
    }
}

enum ClaudeStopReason: Equatable, Sendable {
    case endTurn, toolUse, maxTokens, stopSequence, refusal, pauseTurn
    case other(String)

    init(apiValue: String) {
        switch apiValue {
        case "end_turn": self = .endTurn
        case "tool_use": self = .toolUse
        case "max_tokens": self = .maxTokens
        case "stop_sequence": self = .stopSequence
        case "refusal": self = .refusal
        case "pause_turn": self = .pauseTurn
        default: self = .other(apiValue)
        }
    }

    var apiValue: String {
        switch self {
        case .endTurn: return "end_turn"
        case .toolUse: return "tool_use"
        case .maxTokens: return "max_tokens"
        case .stopSequence: return "stop_sequence"
        case .refusal: return "refusal"
        case .pauseTurn: return "pause_turn"
        case .other(let apiValue): return apiValue
        }
    }
}

struct ClaudeUsage: Equatable, Sendable {
    var inputTokens: Int
    var outputTokens: Int
    var cacheCreationInputTokens: Int?
    var cacheReadInputTokens: Int?
}

/// Built by ClaudeServerSentEventAccumulator from the stream; the app never decodes a non-streaming response.
struct ClaudeMessagesResponse: Equatable, Sendable {
    var messageIdentifier: String
    var model: String
    var content: [ClaudeContentBlock]
    var stopReason: ClaudeStopReason
    var refusalExplanation: String?
    var usage: ClaudeUsage

    var toolUseBlocks: [ClaudeToolUseBlock] {
        content.compactMap { contentBlock in
            if case .toolUse(let toolUseBlock) = contentBlock { return toolUseBlock }
            return nil
        }
    }

    var assistantMessageForHistory: ClaudeMessage {
        ClaudeMessage(role: .assistant, content: content)
    }
}

struct ClaudeAPIErrorPayload: Equatable, Sendable {
    var errorType: String
    var message: String
}

enum ClaudeRequestEncoding {
    // Deterministic bytes keep the prompt cache and the preserved-thinking prefix check stable across re-sends of
    // the same history.
    static func encodeRequestBody(_ request: ClaudeMessagesRequest) throws -> Data {
        try CanonicalJSONEncoding.encode(request)
    }
}
