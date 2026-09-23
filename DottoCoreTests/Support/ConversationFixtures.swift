import Foundation
import CoreGraphics

enum ConversationFixtures {
    /// An on-screen element of the item loop's window; only buttons can be pressed.
    static func node(_ elementIdentifier: String, role: String, title: String?) -> AccessibilityElementNode {
        makeFixtureNode(elementIdentifier, role, title: title, frame: CGRect(x: 100, y: 100, width: 80, height: 24),
                        supportsPressAction: role == "AXButton")
    }

    static func windowRootNodes() -> [AccessibilityElementNode] {
        var windowNode = node("e1", role: "AXWindow", title: "Documents")
        windowNode.children = [node("e2", role: "AXButton", title: "Rename"),
                               node("e3", role: "AXTextField", title: "Name"),
                               node("e4", role: "AXButton", title: "Send")]
        return [windowNode]
    }

    static func response(stopReason: String, blocks: [String], stopDetailsJSON: String = "null") throws -> ClaudeMessagesResponse {
        let responseJSON = """
        {"id":"msg_test","type":"message","role":"assistant","model":"claude-sonnet-5","content":[\(blocks.joined(separator: ","))],\
        "stop_reason":"\(stopReason)","stop_details":\(stopDetailsJSON),\
        "usage":{"input_tokens":100,"output_tokens":20,"cache_creation_input_tokens":0,"cache_read_input_tokens":80}}
        """
        return try ClaudeMessagesResponse.decodingNonStreamingJSON(Data(responseJSON.utf8))
    }

    static func toolUse(_ toolUseIdentifier: String, _ toolName: String, _ inputJSON: String) -> String {
        #"{"type":"tool_use","id":"\#(toolUseIdentifier)","name":"\#(toolName)","input":\#(inputJSON)}"#
    }

    static func toolTurn(_ toolUseBlocks: String...) throws -> ScriptedClaudeTransport.ScriptedReply {
        .response(try response(stopReason: "tool_use", blocks: toolUseBlocks))
    }

    /// Completed items carry evidence the fake backend always satisfies (its window is titled "Documents").
    static func finishItemTurn(outcome: String, summary: String = "done",
                               evidenceJSON: String? = nil) throws -> ScriptedClaudeTransport.ScriptedReply {
        let defaultEvidenceJSON = outcome == "completed" ? #"{"kind":"window_title_contains","text":"Documents"}"# : #"{"kind":"none","text":""}"#
        return try toolTurn(toolUse("toolu_finish", "finish_item",
            #"{"outcome":"\#(outcome)","summary":"\#(summary)","evidence":\#(evidenceJSON ?? defaultEvidenceJSON)}"#))
    }

    static func clickInput(_ elementIdentifier: String) -> String {
        #"{"element_id":"\#(elementIdentifier)","click_type":"single"}"#
    }

    static func makeAuditLogWriter() throws -> AuditLogWriter {
        try AuditLogWriter(taskIdentifier: "test-task", logsDirectoryURL: makeScratchDirectoryURL(prefix: "audit-logs"))
    }

    static func makeChecklist(itemLabels: [String], irreversibleItemLabels: Set<String> = []) -> Checklist {
        let submittedItems = itemLabels.map { itemLabel in
            SubmittedChecklistDraftItem(label: itemLabel, actionSummary: "Do \(itemLabel).", parameters: [],
                                        isIrreversible: irreversibleItemLabels.contains(itemLabel))
        }
        return Checklist.fromPlannerSubmission(
            SubmittedChecklistDraft(taskTitle: "Test task", messageToUser: nil, items: submittedItems),
            originalCommand: "do the test chore", targetApplication: fixtureTargetApplication,
            taskIdentifier: "test-task", createdAt: Date(timeIntervalSince1970: 0))
    }

    static func itemContext(checklist: Checklist, riskCategoryConfirmedForThisItem: SafetyRiskCategory? = nil,
                            remainingTaskActionBudget: Int = 500, runControl: TaskRunControl? = nil) -> ChecklistItemExecutionContext {
        ChecklistItemExecutionContext(checklist: checklist, item: checklist.items[0], itemPositionAmongIncludedItems: 1,
                                      includedItemCount: checklist.items.count, previousItemResultSummary: nil,
                                      riskCategoryConfirmedForThisItem: riskCategoryConfirmedForThisItem,
                                      remainingTaskActionBudget: remainingTaskActionBudget,
                                      taskResourceBudget: TaskResourceBudget(safetyLimits: .standard), runControl: runControl)
    }

    static func toolResults(inLastMessageOf request: ClaudeMessagesRequest) -> [ClaudeToolResultBlock] {
        guard let lastMessage = request.messages.last else { return [] }
        return lastMessage.content.compactMap { contentBlock in
            if case .toolResult(let toolResultBlock) = contentBlock { return toolResultBlock }
            return nil
        }
    }

    static func firstText(of toolResultBlock: ClaudeToolResultBlock) -> String {
        for resultContent in toolResultBlock.content {
            if case .text(let resultText) = resultContent { return resultText }
        }
        return ""
    }

    static func initialUserText(of request: ClaudeMessagesRequest) -> String {
        guard case .text(let textBlock)? = request.messages.first?.content.first else { return "" }
        return textBlock.text
    }
}

func firstToolResult(ofRequest requestIndex: Int, in transport: ScriptedClaudeTransport) throws -> ClaudeToolResultBlock {
    try unwrapOrFail(ConversationFixtures.toolResults(inLastMessageOf: transport.recordedRequests[requestIndex]).first)
}
