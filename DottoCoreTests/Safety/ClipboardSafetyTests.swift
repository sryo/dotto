import Foundation

private let pasteChords: [[AgentKeyModifier]] = [[.command], [.command, .shift], [.command, .option, .shift], [.shift, .command]]

let clipboardSafetyTestSuite = CoreTestSuite(name: "ClipboardSafety", testCases: [
    CoreTestCase(name: "every ⌘V variant counts as pasting: it runs without asking but stays risky") {
        for pasteModifiers in pasteChords {
            for keyName in ["v", "V", " v "] {
                let paste = AgentAction.pressKey(keyName: keyName, modifiers: pasteModifiers)
                try expectEqual(ungrantedVerdict(paste), .allow, "\(pasteModifiers) \(keyName)")
                try expectEqual(SafetyGate.isClipboardPasteShortcut(keyName: keyName, modifiers: pasteModifiers), true, "\(pasteModifiers) \(keyName)")
                try expectEqual(SafetyGate.actionIsRiskyWithoutAnyGrant(paste, targetNode: nil), true, "\(pasteModifiers) \(keyName)")
            }
        }
        try expectEqual(SafetyRiskCategory.pastingClipboard.asksUser, false)
        // ⌃V isn't paste on macOS, and a plain v types a letter.
        try expectEqual(SafetyGate.actionIsRiskyWithoutAnyGrant(.pressKey(keyName: "v", modifiers: [.control]), targetNode: nil), false)
        try expectEqual(SafetyGate.actionIsRiskyWithoutAnyGrant(.pressKey(keyName: "v", modifiers: []), targetNode: nil), false)
        try expectEqual(SafetyGate.isClipboardPasteShortcut(keyName: "V", modifiers: [.command, .option, .shift]), true)
        try expectEqual(SafetyGate.isClipboardPasteShortcut(keyName: "v", modifiers: [.command, .control]), false)
        try expectEqual(SafetyRiskCategory.pastingClipboard.userFacingScopeDescription, "pasting from the clipboard")
    },
    CoreTestCase(name: "⌘C and ⌘X don't ask") {
        for keyName in ["c", "x"] {
            try expectEqual(ungrantedVerdict(.pressKey(keyName: keyName, modifiers: [.command])), .allow)
        }
        try expectEqual(SafetyGate.actionIsRiskyWithoutAnyGrant(.pressKey(keyName: "c", modifiers: [.command]), targetNode: nil), false)
    },
    CoreTestCase(name: "a pasting grant covers no category that asks") {
        let sendButton = makeFixtureNode("e7", "AXButton", title: "Send", supportsPressAction: true)
        let clickSend = AgentAction.clickElement(elementIdentifier: "e7", clickType: .single)
        try expectEqual(riskCategory(of: SafetyGate.evaluateAction(clickSend, targetNode: sendButton, riskCategoryConfirmedForThisItem: .pastingClipboard,
                                                                   riskCategoriesAllowedForRestOfTask: [.pastingClipboard])),
                        .sendingOrPublishing)
    },
    CoreTestCase(name: "agent loop: ⌘C and every ⌘V variant run without asking") {
        let harness = try ItemLoopTestHarness(replies: [
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_copy", "press_key", #"{"key":"c","modifiers":["command"],"expect":null}"#),
                                              ConversationFixtures.toolUse("toolu_paste", "press_key", #"{"key":"v","modifiers":["command"],"expect":null}"#)),
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_paste_plain", "press_key",
                                                                          #"{"key":"v","modifiers":["command","option","shift"],"expect":null}"#)),
            try ConversationFixtures.finishItemTurn(outcome: "failed"),
        ], confirmationAnswers: [])
        let itemResult = try await harness.runItem(itemLabel: "Paste the address")
        let receivedRequests = await harness.confirmationRequester.receivedRequests
        try expectEqual(receivedRequests.map(\.riskCategory), [])
        try expectEqual(harness.actionBackend.performedActions.count, 3)
        try expectEqual(itemResult.riskCategoriesAllowedForRestOfTask, [])
    },
])
