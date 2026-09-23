import Foundation

/// A decorator, so metering needs no change to ClaudeToolConversationRunner.
final class MeteredClaudeTransport: ClaudeTransport, @unchecked Sendable {
    private let underlyingTransport: ClaudeTransport
    private let metricsAccumulator: TaskRunMetricsAccumulator

    init(wrapping underlyingTransport: ClaudeTransport, metricsAccumulator: TaskRunMetricsAccumulator) {
        self.underlyingTransport = underlyingTransport
        self.metricsAccumulator = metricsAccumulator
    }

    func sendMessagesRequest(_ request: ClaudeMessagesRequest,
                             onProgress: @escaping @Sendable (ClaudeStreamProgressEvent) -> Void) async throws -> ClaudeMessagesResponse {
        let response = try await underlyingTransport.sendMessagesRequest(request, onProgress: onProgress)
        metricsAccumulator.recordModelCall(usage: response.usage)
        return response
    }
}
