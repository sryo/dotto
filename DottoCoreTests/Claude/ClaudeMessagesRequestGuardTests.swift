import Foundation

private func makeGuardTestRequest(model: String, maximumOutputTokens: Int,
                                  tools: [ClaudeToolDefinition] = []) -> ClaudeMessagesRequest {
    ClaudeMessagesRequest(model: model, maximumOutputTokens: maximumOutputTokens, isStreaming: true, effort: "medium",
                          usesAdaptiveThinking: true, usesAutomaticConversationCacheBreakpoint: true,
                          system: [], tools: tools, messages: [])
}

private func parsedRequestFields(_ encodedRequestBody: Data) throws -> [String: JSONValue] {
    guard case .object(let requestFields) = try JSONValue(parsingJSONData: encodedRequestBody) else {
        throw CoreTestFailure(description: "encoded body is not an object")
    }
    return requestFields
}

let claudeMessagesRequestGuardTestSuite = CoreTestSuite(name: "ClaudeMessagesRequestGuard", testCases: [
    CoreTestCase(name: "the planner, executor and routine compiler requests pass unchanged") {
        let executorRequest = PromptLibrary.makeExecutorRequest(conversationMessages: [])
        let plannerRequest = PromptLibrary.makePlannerRequest(conversationMessages: [])
        let routineCompilerRequest = PromptLibrary.makeRoutineCompilerRequest(conversationMessages: [])
        for request in [executorRequest, plannerRequest, routineCompilerRequest] {
            try expectEqual(try ClaudeMessagesRequestGuard.guardedRequestBody(for: request),
                            try ClaudeRequestEncoding.encodeRequestBody(request))
        }
    },
    CoreTestCase(name: "the configured models are both on the allowlist") {
        try expectTrue(ClaudeMessagesRequestGuard.allowedModelIdentifiers.contains(ClaudeModelConfiguration.plannerModelIdentifier))
        try expectTrue(ClaudeMessagesRequestGuard.allowedModelIdentifiers.contains(ClaudeModelConfiguration.executorModelIdentifier))
        try expectEqual(ClaudeMessagesRequestGuard.allowedModelIdentifiers, ["claude-opus-5-5", "claude-sonnet-5"])
    },
    CoreTestCase(name: "a model outside the allowlist is refused") {
        let thrownError = try expectThrowsError {
            _ = try ClaudeMessagesRequestGuard.guardedRequestBody(for: makeGuardTestRequest(model: "claude-fable-5-1", maximumOutputTokens: 1000))
        }
        try expectEqual(thrownError as? ClaudeMessagesRequestGuardError, .modelNotAllowed(modelIdentifier: "claude-fable-5-1"))
    },
    CoreTestCase(name: "max_tokens above the cap is lowered to 16000, and a non-positive value becomes the cap") {
        let oversizedBody = try ClaudeMessagesRequestGuard.guardedRequestBody(
            for: makeGuardTestRequest(model: "claude-sonnet-5", maximumOutputTokens: 128_000))
        try expectEqual(try parsedRequestFields(oversizedBody)["max_tokens"], .number(16000))
        let zeroBody = try ClaudeMessagesRequestGuard.guardedRequestBody(
            for: makeGuardTestRequest(model: "claude-sonnet-5", maximumOutputTokens: 0))
        try expectEqual(try parsedRequestFields(zeroBody)["max_tokens"], .number(16000))
        let smallBody = try ClaudeMessagesRequestGuard.guardedRequestBody(
            for: makeGuardTestRequest(model: "claude-sonnet-5", maximumOutputTokens: 512))
        try expectEqual(try parsedRequestFields(smallBody)["max_tokens"], .number(512))
    },
    CoreTestCase(name: "an encoded body with max_tokens over the cap is refused") {
        let oversizedBody = Data(#"{"model":"claude-sonnet-5","max_tokens":64000,"messages":[]}"#.utf8)
        _ = try expectThrowsError { try ClaudeMessagesRequestGuard.validateEncodedRequestBody(oversizedBody) }
    },
    CoreTestCase(name: "server tools are refused; tools without a type or typed custom pass") {
        let serverToolBody = Data(#"{"model":"claude-sonnet-5","max_tokens":100,"messages":[],"tools":[{"name":"t","input_schema":{}},{"type":"web_search_20260209","name":"web_search"}]}"#.utf8)
        let thrownError = try expectThrowsError { try ClaudeMessagesRequestGuard.validateEncodedRequestBody(serverToolBody) }
        try expectEqual(thrownError as? ClaudeMessagesRequestGuardError, .toolTypeNotAllowed(toolType: "web_search_20260209"))

        let customToolBody = Data(#"{"model":"claude-opus-5-5","max_tokens":100,"messages":[],"tools":[{"name":"t","input_schema":{}},{"type":"custom","name":"u","input_schema":{}}]}"#.utf8)
        try ClaudeMessagesRequestGuard.validateEncodedRequestBody(customToolBody)
    },
    CoreTestCase(name: "a body without a model or that isn't a JSON object is refused") {
        _ = try expectThrowsError {
            try ClaudeMessagesRequestGuard.validateEncodedRequestBody(Data(#"{"max_tokens":100,"messages":[]}"#.utf8))
        }
        _ = try expectThrowsError { try ClaudeMessagesRequestGuard.validateEncodedRequestBody(Data("[]".utf8)) }
        _ = try expectThrowsError { try ClaudeMessagesRequestGuard.validateEncodedRequestBody(Data("{not json".utf8)) }
    },
])
