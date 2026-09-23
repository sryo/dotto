import Foundation

private func stallPolicyAfter(_ stepProgresses: [AgentStepProgress]) -> ChecklistItemStallPolicy {
    var stallPolicy = ChecklistItemStallPolicy()
    for stepProgress in stepProgresses { stallPolicy.record(stepProgress) }
    return stallPolicy
}

private let unmatchedReadInputJSON = #"{"application_name":null,"query":"223x142","scope":"focused_window"}"#

let checklistItemStallPolicyTestSuite = CoreTestSuite(name: "ChecklistItemStallPolicy", testCases: [
    CoreTestCase(name: "four actions in a row that changed nothing stall the item") {
        let noChangeAction = AgentStepProgress.changedNothing(isAction: true)
        try expectEqual(stallPolicyAfter([noChangeAction, noChangeAction, noChangeAction]).itemHasStalled, false)
        try expectEqual(stallPolicyAfter([noChangeAction, noChangeAction, noChangeAction, noChangeAction]).itemHasStalled, true)
    },
    CoreTestCase(name: "the logged Finder rename: a dropped value, then three reads that find nothing") {
        let loggedSteps: [AgentStepProgress] = [
            .changedSomething,                   // click the file
            .changedSomething,                   // ⌘I
            .changedSomething,                   // click in Get Info
            .neutral,                            // click refused: paused before the action
            .changedSomething,                   // click the name field
            .changedNothing(isAction: false),    // read_ui "1.08.46": 0 matches
            .neutral,                            // screenshot
            .changedSomething,                   // Return
            .changedNothing(isAction: true),     // type_text: the set value wasn't kept
            .changedNothing(isAction: false),    // read_ui "223x142": 0 matches
            .changedNothing(isAction: false),    // read_ui "1.08.46": 0 matches
        ]
        try expectEqual(stallPolicyAfter(loggedSteps).itemHasStalled, false)
        try expectEqual(stallPolicyAfter(loggedSteps + [.changedNothing(isAction: false)]).itemHasStalled, true,
                        "read_ui \"223\": 0 matches")
    },
    CoreTestCase(name: "reads and waits before the item's first action never count") {
        let unmatchedRead = AgentStepProgress.changedNothing(isAction: false)
        let stallPolicy = stallPolicyAfter([unmatchedRead, unmatchedRead, unmatchedRead, unmatchedRead, unmatchedRead])
        try expectEqual(stallPolicy.itemHasStalled, false)
        try expectEqual(stallPolicy.consecutiveStepsWithoutChange, 0)
    },
    CoreTestCase(name: "a visible change resets the count; screenshots and matched reads leave it alone") {
        let noChangeAction = AgentStepProgress.changedNothing(isAction: true)
        try expectEqual(stallPolicyAfter([noChangeAction, noChangeAction, noChangeAction, .changedSomething, noChangeAction]).itemHasStalled,
                        false)
        try expectEqual(stallPolicyAfter([noChangeAction, .neutral, noChangeAction, .neutral, noChangeAction, noChangeAction]).itemHasStalled,
                        true)
    },
    CoreTestCase(name: "the loop ends the item as needs-user after four clicks that changed nothing") {
        let clickTurn = try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_x", "click", ConversationFixtures.clickInput("e2")))
        let harness = try ItemLoopTestHarness(replies: [clickTurn, clickTurn, clickTurn, clickTurn, clickTurn, clickTurn])
        harness.actionBackend.reportsNoVisibleChange = true
        let itemResult = try await harness.runItem()
        try expectEqual(itemResult.runStatus, .needsUser)
        try expectEqual(itemResult.resultSummary, "Nothing changed after the last 4 steps.")
        try expectEqual(harness.actionBackend.performedActions.count, 4)
        try expectEqual(harness.transport.recordedRequests.count, 4, "no model turn after the fourth click")
    },
    CoreTestCase(name: "the loop counts not-delivered input and reads that find nothing after an action") {
        let clickTurn = try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_c", "click", ConversationFixtures.clickInput("e2")))
        let unmatchedReadTurn = try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_r", "read_ui", unmatchedReadInputJSON))
        let harness = try ItemLoopTestHarness(replies: [clickTurn, unmatchedReadTurn, unmatchedReadTurn, unmatchedReadTurn,
                                                        try ConversationFixtures.finishItemTurn(outcome: "failed")])
        harness.actionBackend.errorForNextPerform = ActionBackendError.inputNotDelivered("the text didn't arrive.",
                                                                                         foregroundAssistMayHelp: false)
        let itemResult = try await harness.runItem()
        try expectEqual(itemResult.runStatus, .needsUser)
        try expectEqual(itemResult.resultSummary, ChecklistItemStallPolicy.stalledItemSummary)
        try expectEqual(harness.transport.recordedRequests.count, 4)
    },
    CoreTestCase(name: "the loop leaves an item alone that only reads before acting") {
        let unmatchedReadTurn = try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_r", "read_ui", unmatchedReadInputJSON))
        let harness = try ItemLoopTestHarness(replies: [unmatchedReadTurn, unmatchedReadTurn, unmatchedReadTurn, unmatchedReadTurn,
                                                        unmatchedReadTurn, try ConversationFixtures.finishItemTurn(outcome: "failed")])
        let itemResult = try await harness.runItem()
        try expectEqual(itemResult.runStatus, .failed)
    },
])
