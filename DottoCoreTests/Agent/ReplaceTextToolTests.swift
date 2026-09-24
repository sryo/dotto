import Foundation

private func decodeReplaceText(_ inputJSONText: String) throws -> Result<AgentToolCall, AgentToolInputError> {
    AgentToolCallDecoder.decodeToolCall(ClaudeToolUseBlock(toolUseIdentifier: "toolu_replace", toolName: "replace_text",
                                                          input: try JSONValue(parsingJSONText: inputJSONText)))
}

private func replaceTextInput(elementIdentifier: String = #""e3""#, find: String, replaceWith: String, occurrence: String = "first",
                              position: String = "at_find") -> String {
    #"{"element_id":\#(elementIdentifier),"find":"\#(find)","replace_with":"\#(replaceWith)","occurrence":"\#(occurrence)","position":"\#(position)","expect":null}"#
}

private func expectReplaceTextRejected(_ inputJSONText: String, mentioning expectedFragment: String) throws {
    switch try decodeReplaceText(inputJSONText) {
    case .success(let toolCall):
        throw CoreTestFailure(description: "replace_text unexpectedly decoded to \(toolCall)")
    case .failure(let inputError):
        try expectTrue(inputError.messageForModel.contains(expectedFragment), inputError.messageForModel)
    }
}

let replaceTextToolTestSuite = CoreTestSuite(name: "ReplaceTextTool", testCases: [
    CoreTestCase(name: "replace_text is an executor tool sent without a strict schema") {
        let replaceTextDefinition = try unwrapOrFail(AgentToolCatalog.executorTools.first { $0.name == "replace_text" })
        try expectTrue(!replaceTextDefinition.isStrict)
        try expectTrue(!AgentToolCatalog.plannerTools.contains { $0.name == "replace_text" })
    },
    CoreTestCase(name: "replace_text decodes a replacement and an insertion") {
        try expectEqual(try decodeReplaceText(replaceTextInput(find: "teh", replaceWith: "the", occurrence: "all")).get(),
                        .action(.replaceText(elementIdentifier: "e3", findText: "teh", replacementText: "the",
                                             occurrence: .all, insertionPosition: .atFind)))
        try expectEqual(try decodeReplaceText(replaceTextInput(find: "", replaceWith: "Dear Ana,", position: "start")).get(),
                        .action(.replaceText(elementIdentifier: "e3", findText: "", replacementText: "Dear Ana,",
                                             occurrence: .first, insertionPosition: .start)))
        try expectEqual(try decodeReplaceText(replaceTextInput(find: "draft ", replaceWith: "")).get(),
                        .action(.replaceText(elementIdentifier: "e3", findText: "draft ", replacementText: "",
                                             occurrence: .first, insertionPosition: .atFind)))
    },
    CoreTestCase(name: "replace_text rejects invalid inputs with a message for the model") {
        try expectReplaceTextRejected(replaceTextInput(elementIdentifier: "null", find: "a", replaceWith: "b"), mentioning: "element_id")
        try expectReplaceTextRejected(replaceTextInput(elementIdentifier: #""""#, find: "a", replaceWith: "b"), mentioning: "element_id")
        try expectReplaceTextRejected(replaceTextInput(find: "a", replaceWith: "b", occurrence: "last"), mentioning: "occurrence")
        try expectReplaceTextRejected(replaceTextInput(find: "a", replaceWith: "b", position: "middle"), mentioning: "position")
        try expectReplaceTextRejected(replaceTextInput(find: "", replaceWith: "b"), mentioning: "start or end")
        try expectReplaceTextRejected(replaceTextInput(find: "a", replaceWith: "b", position: "end"), mentioning: "at_find")
        try expectReplaceTextRejected(replaceTextInput(find: "", replaceWith: "", position: "end"), mentioning: "nothing to change")
        try expectReplaceTextRejected(replaceTextInput(find: "same", replaceWith: "same"), mentioning: "nothing would change")
        try expectReplaceTextRejected(#"{"element_id":"e3","find":"a","occurrence":"first","position":"at_find","expect":null}"#,
                                      mentioning: "replace_with")
        try expectReplaceTextRejected(#"{"element_id":"e3","find":7,"replace_with":"b","occurrence":"first","position":"at_find","expect":null}"#,
                                      mentioning: "find")
    },
    CoreTestCase(name: "the audit summary of replace_text shows fingerprints of find and replace_with, never the text") {
        let auditSummary = AgentActionDescriptions.auditSummary(
            ofToolInput: try JSONValue(parsingJSONText: replaceTextInput(find: "Private draft", replaceWith: "Secret plan")),
            toolName: "replace_text")
        try expectTrue(!auditSummary.contains("Private draft") && !auditSummary.contains("Secret plan"), auditSummary)
        try expectTrue(auditSummary.contains(AuditLogRedaction.fingerprint(of: "Private draft")), auditSummary)
        try expectTrue(auditSummary.contains(AuditLogRedaction.fingerprint(of: "Secret plan")), auditSummary)
    },
    CoreTestCase(name: "the executor prompt steers partial edits to replace_text and away from the caret") {
        let executorSystemPrompt = PromptLibrary.executorSystemPrompt
        try expectTrue(executorSystemPrompt.contains("To change part of a field's text, use replace_text"))
        try expectTrue(executorSystemPrompt.contains("use occurrence all"))
        try expectTrue(executorSystemPrompt.contains("empty find and position start or end"))
        try expectTrue(executorSystemPrompt.contains("type_text with replace_existing_text true only to replace everything"))
        try expectTrue(executorSystemPrompt.contains("Never click to place the caret"))
        try expectTrue(executorSystemPrompt.contains("Don't save, close, send or submit unless the item says to"))
        try expectTrue(!executorSystemPrompt.contains("type the whole edited text with replace_existing_text true"))
    },
    CoreTestCase(name: "replace_text reaches the backend as a replaceText action, and the audit log keeps neither text") {
        let findText = "Quarterly draft notes"
        let replacementText = "Quarterly final notes"
        let harness = try ItemLoopTestHarness(replies: [
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_replace", "replace_text",
                replaceTextInput(find: findText, replaceWith: replacementText, occurrence: "all"))),
            try ConversationFixtures.finishItemTurn(outcome: "completed", summary: "Replaced \(findText) with \(replacementText)."),
        ])
        let itemResult = try await harness.runItem(itemLabel: "Fix the notes")
        try expectEqual(harness.actionBackend.performedActions, [
            .replaceText(elementIdentifier: "e3", findText: findText, replacementText: replacementText, occurrence: .all,
                         insertionPosition: .atFind),
        ])
        try expectEqual(itemResult.runStatus, .completed)
        try expectEqual(await harness.confirmationRequester.receivedRequests.count, 0)
        let logText = try String(contentsOf: harness.auditLogWriter.logFileURL, encoding: .utf8)
        try expectTrue(!logText.contains(findText) && !logText.contains(replacementText), logText)
        try expectTrue(logText.contains(AuditLogRedaction.fingerprint(of: findText)), logText)
    },
    CoreTestCase(name: "replace_text into a password field is denied before it reaches the backend") {
        var windowNode = ConversationFixtures.node("e1", role: "AXWindow", title: "Sign in")
        windowNode.children = [makeFixtureNode("e3", "AXTextField", subrole: "AXSecureTextField", isSecure: true)]
        let harness = try ItemLoopTestHarness(replies: [
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_replace", "replace_text",
                replaceTextInput(find: "old", replaceWith: "new"))),
            try ConversationFixtures.finishItemTurn(outcome: "failed"),
        ], snapshotRootNodes: [windowNode])
        _ = try await harness.runItem()
        try expectTrue(harness.actionBackend.performedActions.isEmpty)
        let deniedResult = ConversationFixtures.toolResults(inLastMessageOf: harness.transport.recordedRequests[1])[0]
        try expectEqual(deniedResult.isError, true)
        try expectEqual(ConversationFixtures.firstText(of: deniedResult), "Typing into password fields is not allowed.")
    },
])
