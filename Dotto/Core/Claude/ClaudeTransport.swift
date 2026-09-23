import Foundation

protocol ClaudeTransport: AnyObject, Sendable {
    func sendMessagesRequest(_ request: ClaudeMessagesRequest,
                             onProgress: @escaping @Sendable (ClaudeStreamProgressEvent) -> Void) async throws -> ClaudeMessagesResponse
}
