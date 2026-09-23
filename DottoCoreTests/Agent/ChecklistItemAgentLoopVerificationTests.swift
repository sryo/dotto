import Foundation
import CoreGraphics

private func clickTurn(_ elementIdentifier: String, expectJSON: String) throws -> ScriptedClaudeTransport.ScriptedReply {
    try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_click", "click",
        #"{"element_id":"\#(elementIdentifier)","click_type":"single","expect":\#(expectJSON)}"#))
}

let checklistItemAgentLoopVerificationTestSuite = CoreTestSuite(name: "ChecklistItemAgentLoopVerification", testCases: [
    CoreTestCase(name: "agent loop: a satisfied expect is ok and records the step") {
        let harness = try ItemLoopTestHarness(replies: [
            try clickTurn("e2", expectJSON: #"{"kind":"text_appears","text":"Renamed"}"#),
            try ConversationFixtures.finishItemTurn(outcome: "completed"),
        ])
        harness.actionBackend.actionHookAfterPerform = { [unowned actionBackend = harness.actionBackend] _ in
            actionBackend.snapshotRootNodes[0].children.append(ConversationFixtures.node("e9", role: "AXStaticText", title: "Renamed"))
        }
        let itemResult = try await harness.runItem()
        let clickResult = try firstToolResult(ofRequest: 1, in: harness.transport)
        try expectEqual(clickResult.isError, false)
        try expectEqual(itemResult.recordedSteps.map(\.expectation), [StepExpectation(kind: .textAppears, text: "Renamed")])
    },
    CoreTestCase(name: "agent loop: text that was already on screen does not satisfy text_appears") {
        let harness = try ItemLoopTestHarness(replies: [
            try clickTurn("e2", expectJSON: #"{"kind":"text_appears","text":"Rename"}"#),
            try ConversationFixtures.finishItemTurn(outcome: "failed"),
        ])
        let itemResult = try await harness.runItem()
        let clickResult = try firstToolResult(ofRequest: 1, in: harness.transport)
        try expectEqual(clickResult.isError, true)
        try expectTrue(ConversationFixtures.firstText(of: clickResult).contains("was already in the focused window"))
        try expectEqual(itemResult.recordedSteps.map(\.expectation), [nil])
    },
    CoreTestCase(name: "agent loop: an unmet expect is an error, but the performed action is still recorded without it") {
        let harness = try ItemLoopTestHarness(replies: [
            try clickTurn("e2", expectJSON: #"{"kind":"text_appears","text":"Renamed file"}"#),
            try ConversationFixtures.finishItemTurn(outcome: "failed"),
        ])
        let itemResult = try await harness.runItem()
        let clickResult = try firstToolResult(ofRequest: 1, in: harness.transport)
        try expectEqual(clickResult.isError, true)
        try expectTrue(ConversationFixtures.firstText(of: clickResult).contains("Expectation not met"))
        try expectEqual(itemResult.recordedSteps.map(\.toolCall), [.action(.clickElement(elementIdentifier: "e2", clickType: .single))])
        try expectEqual(itemResult.recordedSteps.map(\.expectation), [nil])
        try expectEqual(harness.actionBackend.performedActions.count, 1)
    },
    CoreTestCase(name: "agent loop: verified evidence completes the item") {
        let harness = try ItemLoopTestHarness(replies: [try ConversationFixtures.finishItemTurn(outcome: "completed")])
        let itemResult = try await harness.runItem()
        try expectEqual(itemResult.runStatus, .completed)
        try expectEqual(itemResult.verifiedCompletionEvidence, StepExpectation(kind: .windowTitleContains, text: "Documents"))
    },
    CoreTestCase(name: "agent loop: evidence failing twice fails the item") {
        let failingEvidenceTurn = try ConversationFixtures.finishItemTurn(
            outcome: "completed", evidenceJSON: #"{"kind":"text_appears","text":"shot-01.png"}"#)
        let harness = try ItemLoopTestHarness(replies: [failingEvidenceTurn, failingEvidenceTurn])
        let itemResult = try await harness.runItem()
        try expectEqual(itemResult.runStatus, .failed)
        try expectTrue(itemResult.resultSummary.hasPrefix("Verification failed"), itemResult.resultSummary)
        try expectEqual(try firstToolResult(ofRequest: 1, in: harness.transport).isError, true)
    },
    CoreTestCase(name: "agent loop: completed with evidence none is rejected once, then accepted unverified") {
        let noEvidenceTurn = try ConversationFixtures.finishItemTurn(outcome: "completed", evidenceJSON: #"{"kind":"none","text":""}"#)
        let harness = try ItemLoopTestHarness(replies: [noEvidenceTurn, noEvidenceTurn])
        let itemResult = try await harness.runItem()
        try expectEqual(itemResult.runStatus, .completed)
        try expectEqual(itemResult.verifiedCompletionEvidence, nil)
        try expectEqual(ConversationFixtures.firstText(of: try firstToolResult(ofRequest: 1, in: harness.transport)),
                        ChecklistItemAgentLoop.evidenceRequiredText)
    },
    CoreTestCase(name: "agent loop: an action held by a pause is not performed after resume") {
        let harness = try ItemLoopTestHarness(replies: [
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_click", "click", ConversationFixtures.clickInput("e2"))),
            try ConversationFixtures.finishItemTurn(outcome: "failed"),
        ])
        let runControl = TaskRunControl(pollIntervalNanoseconds: 1_000_000)
        runControl.requestPause(reason: .userTookOver(.mouseClicked))
        let resumeTask = Task {
            try await Task.sleep(nanoseconds: 30_000_000)
            runControl.resume()
        }
        _ = try await harness.runItem(runControl: runControl)
        _ = try await resumeTask.value
        try expectTrue(harness.actionBackend.performedActions.isEmpty)
        let clickResult = try firstToolResult(ofRequest: 1, in: harness.transport)
        try expectEqual(clickResult.isError, true)
        try expectTrue(ConversationFixtures.firstText(of: clickResult).hasPrefix(ChecklistItemAgentLoop.pausedBeforeActionText))
    },
    CoreTestCase(name: "agent loop: a skip request skips the item at the next action") {
        let harness = try ItemLoopTestHarness(replies: [
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_click", "click", ConversationFixtures.clickInput("e2"))),
        ])
        let runControl = TaskRunControl(pollIntervalNanoseconds: 1_000_000)
        runControl.requestSkipCurrentItem()
        let itemResult = try await harness.runItem(runControl: runControl)
        try expectEqual(itemResult.runStatus, .skipped)
        try expectEqual(itemResult.resultSummary, "Skipped by the user.")
        try expectTrue(harness.actionBackend.performedActions.isEmpty)
    },
])
