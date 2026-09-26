import Foundation

#if DEBUG
/// Stands in for `AnthropicMessagesTransport` in Debug builds when `dottoMockClaudeTransport` is set, so Dotto can be
/// tried end to end (several tasks at once, cursors, checklists, questions) without spending API credits. Nothing
/// leaves the Mac: every answer comes from `ClaudeMockConversationScript`, after a pause like a model's.
final class MockClaudeTransport: ClaudeTransport, @unchecked Sendable {
    static let enabledDefaultsKey = "dottoMockClaudeTransport"
    private static let simulatedResponseSeconds: Double = 1.5

    private let responseCountLock = NSLock()
    private var responseCount = 0

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledDefaultsKey) }

    func sendMessagesRequest(_ request: ClaudeMessagesRequest,
                             onProgress: @escaping @Sendable (ClaudeStreamProgressEvent) -> Void) async throws -> ClaudeMessagesResponse {
        let responseNumber = responseCountLock.withLock {
            responseCount += 1
            return responseCount
        }
        try await Task.sleep(nanoseconds: UInt64(Self.simulatedResponseSeconds * 1_000_000_000))
        return ClaudeMockConversationScript.response(to: request, responseNumber: responseNumber)
    }
}
#endif
