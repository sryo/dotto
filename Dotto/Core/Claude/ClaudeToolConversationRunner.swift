import Foundation

struct ClaudeToolTurnResolution {
    var toolResultBlocks: [ClaudeContentBlock]
    var shouldStopAfterThisTurn: Bool
    /// The turn asked the user something: its tool results are held back until `resume` adds the user's reply, so
    /// every tool_use of the turn is answered in one user message.
    var waitsForUserReply: Bool = false
}

enum ClaudeToolConversationEnd: Equatable {
    case stoppedByToolHandler
    /// The tool handler asked the user a question; `resume(withUserReplyBlocks:…)` continues the same conversation.
    case pausedForUserReply
    /// The model answered in text alone and the caller chose to take that text as the end of this stretch (the
    /// planner shows it as a question); `resume(withUserReplyBlocks:…)` continues after it.
    case endedWithTextOnlyTurn(text: String)
    case endedWithoutRequiredTool
    case refused(explanation: String?)
    case turnLimitReached
    case truncatedRepeatedly
    case unexpectedStopReason(String)
}

/// The request → tool_use → tool_result loop shared by the planner and the per-item executor.
/// Assistant turns are stored exactly as received so thinking signatures and the cached prefix stay
/// byte-identical on every re-send. The one edit ever made to history is swapping old screenshot images in
/// tool results for a placeholder, which leaves every assistant turn (and so every thinking block) untouched.
final class ClaudeToolConversationRunner {
    static let truncatedTurnErrorText = "Your response was cut off at max_tokens. Retry with fewer tool calls and less text."
    static let removedScreenshotPlaceholderText = "[older screenshot removed]"

    private let transport: ClaudeTransport
    private let makeRequest: ([ClaudeMessage]) -> ClaudeMessagesRequest
    private let nudgeTextWhenRequiredToolMissing: String
    private let maximumModelTurns: Int
    private let auditLogWriter: AuditLogWriter
    private let itemIdentifierForAudit: String?
    private let maximumRetainedScreenshots: Int?
    private let taskResourceBudget: TaskResourceBudget

    private(set) var conversationMessages: [ClaudeMessage] = []
    /// Counted across `run` and every `resume`, so a conversation that waits on the user still has one turn ceiling.
    private var modelTurnCount = 0
    /// The tool results of a turn that asked the user something, sent together with the reply.
    private var toolResultBlocksAwaitingUserReply: [ClaudeContentBlock] = []

    init(transport: ClaudeTransport,
         makeRequest: @escaping ([ClaudeMessage]) -> ClaudeMessagesRequest,
         nudgeTextWhenRequiredToolMissing: String,
         maximumModelTurns: Int,
         auditLogWriter: AuditLogWriter,
         itemIdentifierForAudit: String?,
         maximumRetainedScreenshots: Int? = nil,
         taskResourceBudget: TaskResourceBudget) {
        self.transport = transport
        self.makeRequest = makeRequest
        self.nudgeTextWhenRequiredToolMissing = nudgeTextWhenRequiredToolMissing
        self.maximumModelTurns = maximumModelTurns
        self.auditLogWriter = auditLogWriter
        self.itemIdentifierForAudit = itemIdentifierForAudit
        self.maximumRetainedScreenshots = maximumRetainedScreenshots
        self.taskResourceBudget = taskResourceBudget
    }

    /// `shouldEndOnTextOnlyTurn` is asked when the model ends a turn with text and no tool call: true ends the
    /// conversation with `.endedWithTextOnlyTurn`, false nudges it once toward the required tool.
    func run(initialUserText: String,
             abortSignal: TaskAbortSignal,
             onProgress: @escaping @Sendable (ClaudeStreamProgressEvent) -> Void = { _ in },
             shouldEndOnTextOnlyTurn: () -> Bool = { false },
             handleToolUses: ([ClaudeToolUseBlock]) async throws -> ClaudeToolTurnResolution) async throws -> ClaudeToolConversationEnd {
        conversationMessages.append(ClaudeMessage(role: .user, content: [.plainText(initialUserText)]))
        return try await continueConversation(abortSignal: abortSignal, onProgress: onProgress,
                                              shouldEndOnTextOnlyTurn: shouldEndOnTextOnlyTurn, handleToolUses: handleToolUses)
    }

    /// Continues after `.pausedForUserReply` or `.endedWithTextOnlyTurn`. The reply goes into one user message after
    /// any tool results the paused turn held back, so the history stays exactly as the model will see it.
    func resume(withUserReplyBlocks userReplyBlocks: [ClaudeContentBlock],
                abortSignal: TaskAbortSignal,
                onProgress: @escaping @Sendable (ClaudeStreamProgressEvent) -> Void = { _ in },
                shouldEndOnTextOnlyTurn: () -> Bool = { false },
                handleToolUses: ([ClaudeToolUseBlock]) async throws -> ClaudeToolTurnResolution) async throws -> ClaudeToolConversationEnd {
        let userMessageContent = toolResultBlocksAwaitingUserReply + userReplyBlocks
        toolResultBlocksAwaitingUserReply = []
        conversationMessages.append(ClaudeMessage(role: .user, content: userMessageContent))
        return try await continueConversation(abortSignal: abortSignal, onProgress: onProgress,
                                              shouldEndOnTextOnlyTurn: shouldEndOnTextOnlyTurn, handleToolUses: handleToolUses)
    }

    private func continueConversation(abortSignal: TaskAbortSignal,
                                      onProgress: @escaping @Sendable (ClaudeStreamProgressEvent) -> Void,
                                      shouldEndOnTextOnlyTurn: () -> Bool,
                                      handleToolUses: ([ClaudeToolUseBlock]) async throws -> ClaudeToolTurnResolution) async throws -> ClaudeToolConversationEnd {
        var hasNudgedForMissingRequiredTool = false
        var hasAnsweredTruncatedTurn = false

        while true {
            try abortSignal.throwIfAborted()
            guard modelTurnCount < maximumModelTurns else { return .turnLimitReached }
            try taskResourceBudget.throwIfExhausted()
            modelTurnCount += 1

            replaceOlderScreenshotsWithPlaceholders()
            let response = try await transport.sendMessagesRequest(makeRequest(conversationMessages), onProgress: onProgress)
            taskResourceBudget.recordModelTurn(usage: response.usage)
            conversationMessages.append(response.assistantMessageForHistory)
            logModelResponse(response)

            switch response.stopReason {
            case .toolUse:
                let turnResolution = try await handleToolUses(response.toolUseBlocks)
                if turnResolution.waitsForUserReply && !turnResolution.shouldStopAfterThisTurn {
                    toolResultBlocksAwaitingUserReply = turnResolution.toolResultBlocks
                    return .pausedForUserReply
                }
                conversationMessages.append(ClaudeMessage(role: .user, content: turnResolution.toolResultBlocks))
                if turnResolution.shouldStopAfterThisTurn { return .stoppedByToolHandler }

            case .endTurn:
                let responseText = Self.joinedText(of: response)
                if !responseText.isEmpty && shouldEndOnTextOnlyTurn() {
                    return .endedWithTextOnlyTurn(text: responseText)
                }
                if hasNudgedForMissingRequiredTool { return .endedWithoutRequiredTool }
                hasNudgedForMissingRequiredTool = true
                conversationMessages.append(ClaudeMessage(role: .user, content: [.plainText(nudgeTextWhenRequiredToolMissing)]))

            case .maxTokens:
                // The last tool_use of a truncated turn may hold partial input, so none of that turn's
                // tools run; every tool_use id still needs an answer or the next request is rejected.
                if hasAnsweredTruncatedTurn { return .truncatedRepeatedly }
                hasAnsweredTruncatedTurn = true
                conversationMessages.append(ClaudeMessage(role: .user,
                                                          content: truncatedTurnReplyBlocks(for: response.toolUseBlocks)))

            case .refusal:
                return .refused(explanation: response.refusalExplanation)

            case .stopSequence, .pauseTurn, .other:
                return .unexpectedStopReason(response.stopReason.apiValue)
            }
        }
    }

    /// The text blocks of a response, in order; thinking blocks are left out.
    static func joinedText(of response: ClaudeMessagesResponse) -> String {
        joinedText(of: response.content)
    }

    static func joinedText(of contentBlocks: [ClaudeContentBlock]) -> String {
        contentBlocks.compactMap { contentBlock -> String? in
            if case .text(let textBlock) = contentBlock { return textBlock.text }
            return nil
        }.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Keeps the newest screenshots and replaces older ones in place, so the stored history (and with it the
    /// cached prefix) only changes at the moment a screenshot ages out.
    private func replaceOlderScreenshotsWithPlaceholders() {
        guard let maximumRetainedScreenshots else { return }
        var retainedScreenshotCount = 0
        for messageIndex in conversationMessages.indices.reversed() where conversationMessages[messageIndex].role == .user {
            for blockIndex in conversationMessages[messageIndex].content.indices.reversed() {
                guard case .toolResult(var toolResultBlock) = conversationMessages[messageIndex].content[blockIndex] else { continue }
                var didReplaceScreenshot = false
                for contentIndex in toolResultBlock.content.indices.reversed() {
                    guard case .image = toolResultBlock.content[contentIndex] else { continue }
                    if retainedScreenshotCount < maximumRetainedScreenshots {
                        retainedScreenshotCount += 1
                    } else {
                        toolResultBlock.content[contentIndex] = .text(Self.removedScreenshotPlaceholderText)
                        didReplaceScreenshot = true
                    }
                }
                if didReplaceScreenshot {
                    conversationMessages[messageIndex].content[blockIndex] = .toolResult(toolResultBlock)
                }
            }
        }
    }

    private func truncatedTurnReplyBlocks(for toolUseBlocks: [ClaudeToolUseBlock]) -> [ClaudeContentBlock] {
        if toolUseBlocks.isEmpty {
            return [.plainText(Self.truncatedTurnErrorText)]
        }
        return toolUseBlocks.map { toolUseBlock in
            ClaudeToolResultBuilding.textResult(toolUseIdentifier: toolUseBlock.toolUseIdentifier,
                                                text: Self.truncatedTurnErrorText, isError: true)
        }
    }

    private func logModelResponse(_ response: ClaudeMessagesResponse) {
        var responseDetails: [String: String] = [
            "model": response.model,
            "stop_reason": response.stopReason.apiValue,
            "input_tokens": String(response.usage.inputTokens),
            "output_tokens": String(response.usage.outputTokens),
            "cache_read_input_tokens": String(response.usage.cacheReadInputTokens ?? 0),
            "cache_creation_input_tokens": String(response.usage.cacheCreationInputTokens ?? 0),
        ]
        let requestedToolNames = response.toolUseBlocks.map(\.toolName)
        if !requestedToolNames.isEmpty {
            responseDetails["tool_names"] = requestedToolNames.joined(separator: ",")
        }
        auditLogWriter.append(eventKind: .modelResponse, itemIdentifier: itemIdentifierForAudit,
                              message: "Model turn \(response.messageIdentifier)", details: responseDetails)
    }
}
