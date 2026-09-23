import Foundation

let anthropicMessagesEndpointTestSuite = CoreTestSuite(name: "AnthropicMessagesEndpoint", testCases: [
    CoreTestCase(name: "requests go to api.anthropic.com over HTTPS") {
        try expectEqual(AnthropicMessagesEndpoint.messagesURL.absoluteString, "https://api.anthropic.com/v1/messages")
        try expectEqual(AnthropicMessagesEndpoint.messagesURL.scheme, "https")
        try expectEqual(AnthropicMessagesEndpoint.messagesURL.host, "api.anthropic.com")
    },
    CoreTestCase(name: "headers carry the key, the API version and the JSON content type, and no beta values") {
        let requestHeaders = AnthropicMessagesEndpoint.requestHeaders(apiKey: "sk-ant-test")
        try expectEqual(requestHeaders, ["x-api-key": "sk-ant-test",
                                         "anthropic-version": "2023-06-01",
                                         "content-type": "application/json"])
        try expectTrue(requestHeaders["anthropic-beta"] == nil)
    },
])
