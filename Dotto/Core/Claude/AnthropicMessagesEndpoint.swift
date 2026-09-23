import Foundation

/// Where Messages API requests go and the headers they carry. The API key is only ever placed in a request to
/// `messagesURL`. Nothing Dotto sends needs an `anthropic-beta` value: adaptive thinking, effort, strict tools,
/// top-level cache control and streaming are all generally available.
enum AnthropicMessagesEndpoint {
    static let messagesURL = URL(string: "https://api.anthropic.com/v1/messages")!
    static let apiVersion = "2023-06-01"
    static let apiKeyHeaderName = "x-api-key"

    static func requestHeaders(apiKey: String) -> [String: String] {
        [apiKeyHeaderName: apiKey,
         "anthropic-version": apiVersion,
         "content-type": "application/json"]
    }
}
