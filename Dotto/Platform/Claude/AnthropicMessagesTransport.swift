import Foundation

enum ClaudeTransportError: Error, Equatable, LocalizedError {
    case missingAPIKey
    case apiKeyUnreadable(String)
    case httpStatus(statusCode: Int, responseBody: String)
    case network(String)
    case stream(ClaudeStreamError)

    // Anthropic's error bodies never echo the API key, so showing a prefix of one is safe.
    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return TaskUserFacingMessages.missingAnthropicAPIKeyMessage
        case .apiKeyUnreadable(let explanation): return explanation
        case .httpStatus(401, _): return "Anthropic rejected the API key (HTTP 401). Replace it in the menu bar panel."
        case .httpStatus(let statusCode, let responseBody): return "Anthropic returned HTTP \(statusCode): \(responseBody.prefix(300))"
        case .network(let explanation): return "Network error: \(explanation)"
        case .stream(let streamError): return "Streaming error: \(streamError)"
        }
    }
}

/// Sends Messages API requests straight to api.anthropic.com with the user's own key from the Keychain, checked by
/// `ClaudeMessagesRequestGuard` first, and accumulates the SSE stream.
final class AnthropicMessagesTransport: ClaudeTransport {
    private static let retryableHTTPStatusCodes: Set<Int> = [408, 429, 500, 502, 503, 504, 529]
    private static let defaultRetryDelaysInSeconds: [Double] = [1, 4]
    private static let maximumHonoredRetryAfterSeconds: Double = 10
    /// Errors the API reports inside a 200 stream that are transient on Anthropic's side.
    private static let retryableStreamErrorTypes: Set<String> = ["overloaded_error", "api_error"]
    private static let maximumMidStreamRetryCount = 1
    private static let midStreamRetryDelayInSeconds: Double = 1
    private static let retryableURLErrorCodes: Set<URLError.Code> = [
        .timedOut, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet,
        .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed,
    ]

    private let apiKeyStore: AnthropicAPIKeyStore
    private let urlSession: URLSession

    init(apiKeyStore: AnthropicAPIKeyStore, urlSession: URLSession = AnthropicMessagesTransport.makeDefaultURLSession()) {
        self.apiKeyStore = apiKeyStore
        self.urlSession = urlSession
    }

    static func makeDefaultURLSession() -> URLSession {
        let sessionConfiguration = URLSessionConfiguration.default
        sessionConfiguration.timeoutIntervalForRequest = 180
        sessionConfiguration.urlCache = nil
        sessionConfiguration.httpCookieStorage = nil
        return URLSession(configuration: sessionConfiguration)
    }

    func sendMessagesRequest(_ request: ClaudeMessagesRequest,
                             onProgress: @escaping @Sendable (ClaudeStreamProgressEvent) -> Void) async throws -> ClaudeMessagesResponse {
        let guardedRequestBody = try ClaudeMessagesRequestGuard.guardedRequestBody(for: request)
        let apiKey: String
        do {
            guard let storedAPIKey = try apiKeyStore.readAPIKey() else { throw ClaudeTransportError.missingAPIKey }
            apiKey = storedAPIKey
        } catch let apiKeyStoreError as AnthropicAPIKeyStoreError {
            throw ClaudeTransportError.apiKeyUnreadable(apiKeyStoreError.localizedDescription)
        }

        var urlRequest = URLRequest(url: AnthropicMessagesEndpoint.messagesURL)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = guardedRequestBody
        for (headerName, headerValue) in AnthropicMessagesEndpoint.requestHeaders(apiKey: apiKey) {
            urlRequest.setValue(headerValue, forHTTPHeaderField: headerName)
        }

        // HTTP-level retries happen before any response body is consumed. A mid-stream error is retried only when no
        // content block had started, so nothing the caller saw (progress events) is ever replayed or duplicated.
        var retryAttemptIndex = 0
        var midStreamRetryCount = 0
        while true {
            let canRetry = retryAttemptIndex < Self.defaultRetryDelaysInSeconds.count
            let defaultRetryDelay = canRetry ? Self.defaultRetryDelaysInSeconds[retryAttemptIndex] : 0

            let responseBytes: URLSession.AsyncBytes
            let urlResponse: URLResponse
            do {
                (responseBytes, urlResponse) = try await urlSession.bytes(for: urlRequest)
            } catch let urlError as URLError where canRetry && Self.retryableURLErrorCodes.contains(urlError.code) {
                try await Task.sleep(nanoseconds: UInt64(defaultRetryDelay * 1_000_000_000))
                retryAttemptIndex += 1
                continue
            } catch let urlError as URLError {
                throw ClaudeTransportError.network(urlError.localizedDescription)
            }

            guard let httpResponse = urlResponse as? HTTPURLResponse else {
                throw ClaudeTransportError.network("Anthropic returned a non-HTTP response.")
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                if canRetry && Self.retryableHTTPStatusCodes.contains(httpResponse.statusCode) {
                    let retryDelay = Self.retryDelay(fromRetryAfterHeader: httpResponse.value(forHTTPHeaderField: "retry-after"))
                        ?? defaultRetryDelay
                    try await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
                    retryAttemptIndex += 1
                    continue
                }
                let responseBody = try await Self.readErrorBody(from: responseBytes)
                throw ClaudeTransportError.httpStatus(statusCode: httpResponse.statusCode, responseBody: responseBody)
            }

            switch try await accumulateStreamedResponse(from: responseBytes, onProgress: onProgress) {
            case .completed(let assembledResponse):
                return assembledResponse
            case .failedBeforeAnyContentBlock(let streamError):
                guard midStreamRetryCount < Self.maximumMidStreamRetryCount,
                      Self.isRetryableStreamError(streamError) else {
                    throw ClaudeTransportError.stream(streamError)
                }
                midStreamRetryCount += 1
                try await Task.sleep(nanoseconds: UInt64(Self.midStreamRetryDelayInSeconds * 1_000_000_000))
            }
        }
    }

    private enum StreamAttemptResult {
        case completed(ClaudeMessagesResponse)
        /// The stream reported an error before any content_block_start, so a fresh attempt can't duplicate output.
        case failedBeforeAnyContentBlock(ClaudeStreamError)
    }

    private func accumulateStreamedResponse(from responseBytes: URLSession.AsyncBytes,
                                            onProgress: @escaping @Sendable (ClaudeStreamProgressEvent) -> Void) async throws -> StreamAttemptResult {
        var serverSentEventAccumulator = ClaudeServerSentEventAccumulator()
        var anyContentBlockHasStarted = false
        do {
            for try await serverSentEventLine in responseBytes.lines {
                // Every delta follows its block's start, so the first line mentioning the event type marks the point
                // after which a retry could repeat output.
                if serverSentEventLine.contains("\"content_block_start\"") { anyContentBlockHasStarted = true }
                for progressEvent in try serverSentEventAccumulator.consumeLine(serverSentEventLine) {
                    onProgress(progressEvent)
                }
                if serverSentEventAccumulator.hasReceivedMessageStop { break }
            }
            return .completed(try serverSentEventAccumulator.assembledResponse())
        } catch let streamError as ClaudeStreamError {
            if !anyContentBlockHasStarted, case .streamReportedError = streamError {
                return .failedBeforeAnyContentBlock(streamError)
            }
            throw ClaudeTransportError.stream(streamError)
        } catch let urlError as URLError {
            throw ClaudeTransportError.network(urlError.localizedDescription)
        }
    }

    private static func isRetryableStreamError(_ streamError: ClaudeStreamError) -> Bool {
        guard case .streamReportedError(let errorPayload) = streamError else { return false }
        return retryableStreamErrorTypes.contains(errorPayload.errorType)
    }

    private static func retryDelay(fromRetryAfterHeader retryAfterHeaderValue: String?) -> Double? {
        guard let retryAfterHeaderValue, let retryAfterSeconds = Double(retryAfterHeaderValue.trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        return min(max(retryAfterSeconds, 0), maximumHonoredRetryAfterSeconds)
    }

    private static func readErrorBody(from responseBytes: URLSession.AsyncBytes) async throws -> String {
        var errorBodyLines: [String] = []
        var errorBodyCharacterCount = 0
        for try await errorBodyLine in responseBytes.lines {
            errorBodyLines.append(errorBodyLine)
            errorBodyCharacterCount += errorBodyLine.count
            if errorBodyCharacterCount > 4000 { break }
        }
        return errorBodyLines.joined(separator: "\n")
    }
}
