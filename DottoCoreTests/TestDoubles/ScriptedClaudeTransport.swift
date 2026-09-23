import Foundation
import CoreGraphics

final class ScriptedClaudeTransport: ClaudeTransport, @unchecked Sendable {
    enum ScriptedReply {
        case response(ClaudeMessagesResponse)
        case failure(Error)
    }

    private let stateLock = NSLock()
    private var remainingReplies: [ScriptedReply]
    private var requestsReceivedSoFar: [ClaudeMessagesRequest] = []

    init(replies: [ScriptedReply]) { self.remainingReplies = replies }

    var recordedRequests: [ClaudeMessagesRequest] { stateLock.withLock { requestsReceivedSoFar } }

    func sendMessagesRequest(_ request: ClaudeMessagesRequest,
                             onProgress: @escaping @Sendable (ClaudeStreamProgressEvent) -> Void) async throws -> ClaudeMessagesResponse {
        let nextReply: ScriptedReply? = stateLock.withLock {
            requestsReceivedSoFar.append(request)
            return remainingReplies.isEmpty ? nil : remainingReplies.removeFirst()
        }
        switch nextReply {
        case .response(let scriptedResponse): return scriptedResponse
        case .failure(let scriptedError): throw scriptedError
        case nil: throw CoreTestFailure(description: "ScriptedClaudeTransport ran out of scripted replies")
        }
    }
}
