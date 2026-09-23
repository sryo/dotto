import Foundation

enum ClaudeMessagesRequestGuardError: Error, Equatable, LocalizedError {
    case modelNotAllowed(modelIdentifier: String)
    case toolTypeNotAllowed(toolType: String)
    case malformedRequestBody(explanation: String)

    var errorDescription: String? {
        switch self {
        case .modelNotAllowed(let modelIdentifier):
            return "Dotto refused to send a request for the model \(modelIdentifier). Allowed: "
                + ClaudeMessagesRequestGuard.allowedModelIdentifiers.sorted().joined(separator: ", ") + "."
        case .toolTypeNotAllowed(let toolType):
            return "Dotto refused to send a request with a non-custom tool (type \(toolType))."
        case .malformedRequestBody(let explanation):
            return "Dotto refused to send a malformed request: \(explanation)"
        }
    }
}

/// The spend limits Dotto holds itself to before any request leaves the Mac, since the user's own API key pays for
/// every call: only Dotto's two models, a capped `max_tokens`, and custom tools only (server tools such as web search
/// or code execution run on Anthropic's side and bill extra). The model allowlist is spelled out here rather than read
/// from `ClaudeModelConfiguration`, so a changed model id has to be allowed on purpose.
enum ClaudeMessagesRequestGuard {
    static let allowedModelIdentifiers: Set<String> = ["claude-opus-5-5", "claude-sonnet-5"]
    /// Opus 5.5 always thinks and thinking counts against max_tokens, so this leaves headroom beyond the visible
    /// answer while still bounding the cost of one request.
    static let maximumOutputTokens = 16000

    /// Caps `max_tokens`, encodes the request, then checks the encoded bytes, so what is checked is exactly what is sent.
    static func guardedRequestBody(for request: ClaudeMessagesRequest) throws -> Data {
        var cappedRequest = request
        cappedRequest.maximumOutputTokens = cappedMaximumOutputTokens(requestedMaximumOutputTokens: request.maximumOutputTokens)
        let encodedRequestBody = try ClaudeRequestEncoding.encodeRequestBody(cappedRequest)
        try validateEncodedRequestBody(encodedRequestBody)
        return encodedRequestBody
    }

    static func cappedMaximumOutputTokens(requestedMaximumOutputTokens: Int) -> Int {
        guard requestedMaximumOutputTokens > 0 else { return maximumOutputTokens }
        return min(requestedMaximumOutputTokens, maximumOutputTokens)
    }

    static func validateEncodedRequestBody(_ encodedRequestBody: Data) throws {
        let parsedRequestBody: JSONValue
        do {
            parsedRequestBody = try JSONValue(parsingJSONData: encodedRequestBody)
        } catch {
            throw ClaudeMessagesRequestGuardError.malformedRequestBody(explanation: "the body is not JSON.")
        }
        guard case .object(let requestFields) = parsedRequestBody else {
            throw ClaudeMessagesRequestGuardError.malformedRequestBody(explanation: "the body is not a JSON object.")
        }

        guard case .string(let modelIdentifier)? = requestFields["model"] else {
            throw ClaudeMessagesRequestGuardError.malformedRequestBody(explanation: "model is missing.")
        }
        guard allowedModelIdentifiers.contains(modelIdentifier) else {
            throw ClaudeMessagesRequestGuardError.modelNotAllowed(modelIdentifier: modelIdentifier)
        }

        guard case .number(let requestedMaximumOutputTokens)? = requestFields["max_tokens"],
              requestedMaximumOutputTokens > 0,
              requestedMaximumOutputTokens <= Double(maximumOutputTokens) else {
            throw ClaudeMessagesRequestGuardError.malformedRequestBody(
                explanation: "max_tokens must be between 1 and \(maximumOutputTokens).")
        }

        try requireOnlyCustomTools(requestFields["tools"])
    }

    private static func requireOnlyCustomTools(_ encodedTools: JSONValue?) throws {
        guard let encodedTools else { return }
        guard case .array(let toolDefinitions) = encodedTools else {
            throw ClaudeMessagesRequestGuardError.malformedRequestBody(explanation: "tools must be an array.")
        }
        for toolDefinition in toolDefinitions {
            guard case .object(let toolFields) = toolDefinition else {
                throw ClaudeMessagesRequestGuardError.malformedRequestBody(explanation: "each tool must be an object.")
            }
            switch toolFields["type"] {
            case nil, .string("custom")?:
                continue
            case .string(let toolType)?:
                throw ClaudeMessagesRequestGuardError.toolTypeNotAllowed(toolType: toolType)
            case .some:
                throw ClaudeMessagesRequestGuardError.toolTypeNotAllowed(toolType: "non-string")
            }
        }
    }
}
