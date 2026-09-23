import Foundation
import CoreGraphics

private func makePlanner(replies: [ScriptedClaudeTransport.ScriptedReply]) throws -> (ChecklistPlanner, ScriptedClaudeTransport, FakeActionBackend) {
    let transport = ScriptedClaudeTransport(replies: replies)
    let actionBackend = FakeActionBackend(snapshotRootNodes: ConversationFixtures.windowRootNodes())
    let checklistPlanner = ChecklistPlanner(transport: transport, actionBackend: actionBackend,
                                            auditLogWriter: try ConversationFixtures.makeAuditLogWriter(),
                                            taskResourceBudget: TaskResourceBudget(safetyLimits: .standard))
    return (checklistPlanner, transport, actionBackend)
}

private func produceChecklist(with checklistPlanner: ChecklistPlanner) async throws -> ChecklistPlanningResult {
    try await checklistPlanner.produceChecklist(command: "rename the files", targetApplication: fixtureTargetApplication,
                                                taskIdentifier: "test-task", abortSignal: TaskAbortSignal(), onProgress: { _ in })
}

private func continuePlanning(with checklistPlanner: ChecklistPlanner, reply: String) async throws -> ChecklistPlanningResult {
    try await checklistPlanner.continuePlanning(withUserReply: reply, abortSignal: TaskAbortSignal(), onProgress: { _ in })
}

private let folderQuestionInput = #"{"question":"Which folder should Dotto rename files in?","choices":[{"label":"Desktop","detail":null},{"label":"Downloads","detail":"12 files"}],"allow_free_text":true}"#

private let twoItemSubmitPlanInput = #"{"task_title":"Rename files","message_to_user":null,"items":[{"label":"Rename a","action_summary":"Rename a.","parameters":[{"name":"file","value":"a"}],"is_irreversible":false},{"label":"Rename b","action_summary":"Rename b.","parameters":[],"is_irreversible":false}]}"#

let checklistPlannerTestSuite = CoreTestSuite(name: "ChecklistPlanner", testCases: [
    CoreTestCase(name: "planner reads the UI, then submit_plan produces a plan") {
        let (checklistPlanner, transport, actionBackend) = try makePlanner(replies: [
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_read", "read_ui",
                #"{"scope":"focused_window","application_name":null,"query":"png"}"#)),
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_plan", "submit_plan", twoItemSubmitPlanInput)),
        ])
        let planningResult = try await produceChecklist(with: checklistPlanner)
        guard case .checklist(let checklist) = planningResult else { throw CoreTestFailure(description: "expected a plan, got \(planningResult)") }
        try expectEqual(checklist.items.map(\.label), ["Rename a", "Rename b"])
        try expectEqual(checklist.items.map(\.itemIdentifier), ["item-1", "item-2"])
        try expectEqual(transport.recordedRequests.count, 2)
        try expectEqual(transport.recordedRequests[0].model, ClaudeModelConfiguration.plannerModelIdentifier)
        try expectEqual(actionBackend.readRequests.count, 2, "initial outline + read_ui tool")
        let readResults = ConversationFixtures.toolResults(inLastMessageOf: transport.recordedRequests[1])
        try expectEqual(readResults.map(\.toolUseIdentifier), ["toolu_read"])
        try expectEqual(readResults[0].isError, false)
    },
    CoreTestCase(name: "planner takes a text-only answer as an open question, with its markdown stripped") {
        let (checklistPlanner, transport, _) = try makePlanner(replies: [
            .response(try ConversationFixtures.response(stopReason: "end_turn", blocks: [
                ###"{"type":"text","text":"## Question\n**Which folder** should Dotto use?\n\n- `Desktop`\n- Downloads"}"###])),
        ])
        let planningResult = try await produceChecklist(with: checklistPlanner)
        try expectEqual(planningResult, .question(PlannerQuestion(
            text: "Question\nWhich folder should Dotto use?\n\nDesktop\nDownloads", choices: [], allowsFreeText: true)))
        try expectEqual(transport.recordedRequests.count, 1, "no nudge: the text is shown to the user")
        try expectEqual(checklistPlanner.askedQuestionCount, 1)
    },
    CoreTestCase(name: "a reply to a text-only question goes in as a plain user message, then planning finishes") {
        let (checklistPlanner, transport, _) = try makePlanner(replies: [
            .response(try ConversationFixtures.response(stopReason: "end_turn", blocks: [#"{"type":"text","text":"Which folder?"}"#])),
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_plan", "submit_plan", twoItemSubmitPlanInput)),
        ])
        _ = try await produceChecklist(with: checklistPlanner)
        let planningResult = try await continuePlanning(with: checklistPlanner, reply: "Downloads")
        guard case .checklist = planningResult else { throw CoreTestFailure(description: "expected a plan, got \(planningResult)") }
        let replyMessage = try unwrapOrFail(transport.recordedRequests[1].messages.last)
        try expectEqual(replyMessage, ClaudeMessage(role: .user, content: [.plainText(PromptLibrary.plannerUserReplyText("Downloads"))]))
    },
    CoreTestCase(name: "ask_user pauses planning; the reply continues the same conversation as the tool's result") {
        let (checklistPlanner, transport, actionBackend) = try makePlanner(replies: [
            try ConversationFixtures.toolTurn(
                ConversationFixtures.toolUse("toolu_read", "read_ui", #"{"scope":"focused_window","application_name":null,"query":"png"}"#),
                ConversationFixtures.toolUse("toolu_ask", "ask_user", folderQuestionInput)),
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_plan", "submit_plan", twoItemSubmitPlanInput)),
        ])
        let firstResult = try await produceChecklist(with: checklistPlanner)
        try expectEqual(firstResult, .question(PlannerQuestion(
            text: "Which folder should Dotto rename files in?",
            choices: [PlannerQuestionChoice(label: "Desktop", detail: nil),
                      PlannerQuestionChoice(label: "Downloads", detail: "12 files")],
            allowsFreeText: true)))
        try expectEqual(transport.recordedRequests.count, 1)

        let secondResult = try await continuePlanning(with: checklistPlanner, reply: "Downloads")
        guard case .checklist(let checklist) = secondResult else { throw CoreTestFailure(description: "expected a plan, got \(secondResult)") }
        try expectEqual(checklist.originalCommand, "rename the files")
        try expectEqual(actionBackend.readRequests.count, 2, "initial outline + read_ui; nothing is read again after the reply")

        let continuedRequest = transport.recordedRequests[1]
        try expectEqual(Array(continuedRequest.messages.prefix(1)), transport.recordedRequests[0].messages,
                        "the reply continues the conversation instead of restarting it")
        try expectEqual(continuedRequest.messages.map(\.role), [.user, .assistant, .user])
        let replyResults = ConversationFixtures.toolResults(inLastMessageOf: continuedRequest)
        try expectEqual(replyResults.map(\.toolUseIdentifier), ["toolu_read", "toolu_ask"], "one user message answers both tool calls")
        try expectEqual(replyResults.map(\.isError), [false, false])
        let replyText = ConversationFixtures.firstText(of: replyResults[1])
        try expectEqual(replyText, PromptLibrary.plannerUserReplyText("Downloads"))
        try expectTrue(replyText.contains("<user_reply>\nDownloads\n</user_reply>"))
        try expectTrue(!replyText.contains("<untrusted_ui>"), "the user's reply is not fenced as screen data")
    },
    CoreTestCase(name: "the planner asks at most 3 questions; a 4th ask_user is refused and planning goes on") {
        let (checklistPlanner, transport, _) = try makePlanner(replies: [
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_ask1", "ask_user", folderQuestionInput)),
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_ask2", "ask_user", folderQuestionInput)),
            .response(try ConversationFixtures.response(stopReason: "end_turn", blocks: [#"{"type":"text","text":"And the prefix?"}"#])),
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_ask4", "ask_user", folderQuestionInput)),
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_plan", "submit_plan", twoItemSubmitPlanInput)),
        ])
        guard case .question = try await produceChecklist(with: checklistPlanner) else { throw CoreTestFailure(description: "expected question 1") }
        guard case .question = try await continuePlanning(with: checklistPlanner, reply: "Desktop") else {
            throw CoreTestFailure(description: "expected question 2")
        }
        guard case .question = try await continuePlanning(with: checklistPlanner, reply: "Desktop") else {
            throw CoreTestFailure(description: "expected question 3 (text-only)")
        }
        try expectEqual(checklistPlanner.askedQuestionCount, 3)
        let finalResult = try await continuePlanning(with: checklistPlanner, reply: "beach-")
        guard case .checklist = finalResult else { throw CoreTestFailure(description: "expected a plan, got \(finalResult)") }
        let refusedQuestionResults = ConversationFixtures.toolResults(inLastMessageOf: transport.recordedRequests[4])
        try expectEqual(refusedQuestionResults.map(\.toolUseIdentifier), ["toolu_ask4"])
        try expectEqual(refusedQuestionResults[0].isError, true)
        try expectEqual(ConversationFixtures.firstText(of: refusedQuestionResults[0]), ChecklistPlanner.questionLimitReachedText)
        try expectEqual(checklistPlanner.askedQuestionCount, 3)
    },
    CoreTestCase(name: "out of questions, a text-only answer is nudged toward submit_plan") {
        let (checklistPlanner, transport, _) = try makePlanner(replies: [
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_ask1", "ask_user", folderQuestionInput)),
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_ask2", "ask_user", folderQuestionInput)),
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_ask3", "ask_user", folderQuestionInput)),
            .response(try ConversationFixtures.response(stopReason: "end_turn", blocks: [#"{"type":"text","text":"One more thing?"}"#])),
            .response(try ConversationFixtures.response(stopReason: "end_turn", blocks: [#"{"type":"text","text":"**Dotto** can't see any files."}"#])),
        ])
        _ = try await produceChecklist(with: checklistPlanner)
        _ = try await continuePlanning(with: checklistPlanner, reply: "a")
        _ = try await continuePlanning(with: checklistPlanner, reply: "b")
        let finalResult = try await continuePlanning(with: checklistPlanner, reply: "c")
        try expectEqual(finalResult, .cannotPlan(messageToUser: "Dotto can't see any files."))
        let nudgeMessage = try unwrapOrFail(transport.recordedRequests[4].messages.last)
        try expectEqual(nudgeMessage, ClaudeMessage(role: .user, content: [.plainText(ChecklistPlanner.submitPlanNudgeText)]))
    },
    CoreTestCase(name: "planning turns and tokens across questions draw on the one task budget") {
        let taskResourceBudget = TaskResourceBudget(safetyLimits: .standard)
        let transport = ScriptedClaudeTransport(replies: [
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_ask", "ask_user", folderQuestionInput)),
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_plan", "submit_plan", twoItemSubmitPlanInput)),
        ])
        let checklistPlanner = ChecklistPlanner(transport: transport,
                                                actionBackend: FakeActionBackend(snapshotRootNodes: ConversationFixtures.windowRootNodes()),
                                                auditLogWriter: try ConversationFixtures.makeAuditLogWriter(),
                                                taskResourceBudget: taskResourceBudget)
        _ = try await produceChecklist(with: checklistPlanner)
        _ = try await continuePlanning(with: checklistPlanner, reply: "Desktop")
        try expectEqual(taskResourceBudget.modelTurnsUsed, 2)
    },
    CoreTestCase(name: "a second ask_user in the same turn is refused; only the first is shown") {
        let (checklistPlanner, transport, _) = try makePlanner(replies: [
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_ask1", "ask_user", folderQuestionInput),
                                              ConversationFixtures.toolUse("toolu_ask2", "ask_user", folderQuestionInput)),
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_plan", "submit_plan", twoItemSubmitPlanInput)),
        ])
        _ = try await produceChecklist(with: checklistPlanner)
        _ = try await continuePlanning(with: checklistPlanner, reply: "Desktop")
        let replyResults = ConversationFixtures.toolResults(inLastMessageOf: transport.recordedRequests[1])
        try expectEqual(replyResults.map(\.toolUseIdentifier), ["toolu_ask2", "toolu_ask1"])
        try expectEqual(replyResults.map(\.isError), [true, false])
        try expectEqual(checklistPlanner.askedQuestionCount, 1)
    },
    CoreTestCase(name: "planner fails with noPlanSubmitted when the model ends with no text and no tool") {
        let emptyEndTurnReply = ScriptedClaudeTransport.ScriptedReply.response(
            try ConversationFixtures.response(stopReason: "end_turn", blocks: []))
        let (checklistPlanner, transport, _) = try makePlanner(replies: [emptyEndTurnReply, emptyEndTurnReply])
        do {
            _ = try await produceChecklist(with: checklistPlanner)
            throw CoreTestFailure(description: "expected noPlanSubmitted")
        } catch let planningError as ChecklistPlanningError {
            try expectEqual(planningError, .noPlanSubmitted)
        }
        try expectEqual(transport.recordedRequests.count, 2, "one nudge")
    },
    CoreTestCase(name: "an empty submit_plan says why the task can't be planned") {
        let (checklistPlanner, _, _) = try makePlanner(replies: [
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_plan", "submit_plan",
                #"{"task_title":"?","message_to_user":"Dotto can't see a **Photos** window.","items":[]}"#)),
        ])
        try expectEqual(try await produceChecklist(with: checklistPlanner), .cannotPlan(messageToUser: "Dotto can't see a Photos window."))
    },
    CoreTestCase(name: "continuing without a pending question fails instead of sending anything") {
        let (checklistPlanner, transport, _) = try makePlanner(replies: [])
        do {
            _ = try await continuePlanning(with: checklistPlanner, reply: "Downloads")
            throw CoreTestFailure(description: "expected noPlanSubmitted")
        } catch let planningError as ChecklistPlanningError {
            try expectEqual(planningError, .noPlanSubmitted)
        }
        try expectEqual(transport.recordedRequests.count, 0)
    },
    CoreTestCase(name: "planner rejects action tools without performing them") {
        let (checklistPlanner, transport, actionBackend) = try makePlanner(replies: [
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_click", "click", ConversationFixtures.clickInput("e2"))),
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_plan", "submit_plan", twoItemSubmitPlanInput)),
        ])
        _ = try await produceChecklist(with: checklistPlanner)
        try expectTrue(actionBackend.performedActions.isEmpty)
        let clickResults = ConversationFixtures.toolResults(inLastMessageOf: transport.recordedRequests[1])
        try expectEqual(clickResults.map(\.isError), [true])
    },
])
