import Foundation
import CoreGraphics

enum RoutineRunFixtures {
    static let fileNames = ["a.png", "b.png", "c.png"]

    /// The Finder file list in a window titled "Documents" (the title the item loop's evidence checks), plus a
    /// "Send" button ("e3") for risky clicks.
    static func finderRootNodes(fileNames: [String] = fileNames) -> [AccessibilityElementNode] {
        let fileRows = makeFinderFileRows(fileNames: fileNames,
                                          rowFrame: { rowOffset in CGRect(x: 0, y: 100 + rowOffset * 30, width: 800, height: 24) },
                                          supportsPressAction: false)
        return [makeFixtureNode("e1", "AXWindow", title: "Documents", frame: CGRect(x: 0, y: 0, width: 800, height: 600), children: [
            makeFixtureNode("e2", "AXOutline", frame: CGRect(x: 100, y: 100, width: 80, height: 24), supportsPressAction: false,
                            children: fileRows),
            ConversationFixtures.node("e3", role: "AXButton", title: "Send"),
        ])]
    }

    static func settingValue(_ newValue: String, ofNodeWithIdentifier elementIdentifier: String,
                             in nodes: [AccessibilityElementNode]) -> [AccessibilityElementNode] {
        nodes.map { node in
            var updatedNode = node
            if node.elementIdentifier == elementIdentifier { updatedNode.value = newValue }
            updatedNode.children = settingValue(newValue, ofNodeWithIdentifier: elementIdentifier, in: node.children)
            return updatedNode
        }
    }

    static func renameChecklist(oldNames: [String] = fileNames, irreversible: Bool = false) -> Checklist {
        makeFixtureChecklist(items: oldNames.enumerated().map { itemOffset, oldName in
            ChecklistItem(itemIdentifier: "item-\(itemOffset + 1)", label: "Rename \(oldName)", actionSummary: "Rename \(oldName).",
                          parameters: [ChecklistItemParameter(name: "old_name", value: oldName),
                                       ChecklistItemParameter(name: "new_name", value: "shot-0\(itemOffset + 1).png")],
                          isIrreversible: irreversible)
        }, taskIdentifier: "test-task")
    }

    static func agentRenameTurns(fieldIdentifier: String, newName: String) throws -> [ScriptedClaudeTransport.ScriptedReply] {
        [try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_click", "click", ConversationFixtures.clickInput(fieldIdentifier))),
         try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_type", "type_text",
            #"{"element_id":"\#(fieldIdentifier)","text":"\#(newName)","replace_existing_text":true,"press_return_after":false}"#)),
         try ConversationFixtures.finishItemTurn(outcome: "completed", evidenceJSON: #"{"kind":"text_appears","text":"\#(newName)"}"#)]
    }

    /// The routine an agent run of item 1 compiles into: click the field holding {{old_name}}, type {{new_name}}.
    static func learnedRenameRoutine() throws -> Routine {
        let snapshot = makeFixtureSnapshot(finderRootNodes(), windowTitle: "Documents")
        let fieldContext = try unwrapOrFail(snapshot.recordedElementContext(forNodeWithIdentifier: "e11"))
        let checklist = renameChecklist()
        let recordedSteps = [
            RecordedAgentStep(toolCall: .action(.clickElement(elementIdentifier: "e11", clickType: .single)),
                              targetContext: fieldContext, expectation: nil, wasConfirmedByUser: false),
            RecordedAgentStep(toolCall: .action(.typeText(elementIdentifier: "e11", text: "shot-01.png", replaceExistingText: true,
                                                          pressReturnAfter: false)),
                              targetContext: fieldContext, expectation: nil, wasConfirmedByUser: false),
        ]
        return try unwrapOrFail(RoutineCompiler.compileFromAgentRun(
            recordedSteps: recordedSteps, completionEvidence: StepExpectation(kind: .textAppears, text: "shot-01.png"),
            checklist: checklist, item: checklist.items[0], modelCallsUsed: 3, routineIdentifier: "routine-test-task",
            now: Date(timeIntervalSince1970: 0)))
    }
}
