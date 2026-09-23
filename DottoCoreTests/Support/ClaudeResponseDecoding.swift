import Foundation

// The app only assembles responses from the SSE stream; tests write whole responses as JSON, so the decoding lives here.

extension ClaudeUsage: Decodable {
    private enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens", outputTokens = "output_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens", cacheReadInputTokens = "cache_read_input_tokens"
    }

    // Streaming usage objects are partial (message_delta carries only output_tokens), so missing counts decode as 0.
    init(from decoder: Decoder) throws {
        let keyedContainer = try decoder.container(keyedBy: CodingKeys.self)
        self.init(inputTokens: try keyedContainer.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0,
                  outputTokens: try keyedContainer.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0,
                  cacheCreationInputTokens: try keyedContainer.decodeIfPresent(Int.self, forKey: .cacheCreationInputTokens),
                  cacheReadInputTokens: try keyedContainer.decodeIfPresent(Int.self, forKey: .cacheReadInputTokens))
    }
}

extension ClaudeMessagesResponse: Decodable {
    private enum CodingKeys: String, CodingKey { case id, model, content, stopReason = "stop_reason", stopDetails = "stop_details", usage }
    private struct StopDetails: Decodable { var explanation: String? }

    init(from decoder: Decoder) throws {
        let keyedContainer = try decoder.container(keyedBy: CodingKeys.self)
        self.init(messageIdentifier: try keyedContainer.decode(String.self, forKey: .id),
                  model: try keyedContainer.decode(String.self, forKey: .model),
                  content: try keyedContainer.decode([ClaudeContentBlock].self, forKey: .content),
                  stopReason: ClaudeStopReason(apiValue: try keyedContainer.decodeIfPresent(String.self, forKey: .stopReason) ?? ""),
                  refusalExplanation: try? keyedContainer.decodeIfPresent(StopDetails.self, forKey: .stopDetails)?.explanation,
                  usage: try keyedContainer.decode(ClaudeUsage.self, forKey: .usage))
    }

    static func decodingNonStreamingJSON(_ responseData: Data) throws -> ClaudeMessagesResponse {
        try JSONDecoder().decode(ClaudeMessagesResponse.self, from: responseData)
    }
}

extension ClaudeAPIErrorPayload: Decodable {
    private enum OuterCodingKeys: String, CodingKey { case error }
    private enum ErrorCodingKeys: String, CodingKey { case type, message }

    init(from decoder: Decoder) throws {
        let errorContainer = try decoder.container(keyedBy: OuterCodingKeys.self)
            .nestedContainer(keyedBy: ErrorCodingKeys.self, forKey: .error)
        self.init(errorType: try errorContainer.decode(String.self, forKey: .type),
                  message: try errorContainer.decode(String.self, forKey: .message))
    }
}
