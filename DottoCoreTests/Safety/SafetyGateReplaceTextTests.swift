import Foundation

private func replaceTextAction(replacementText: String, findText: String = "old") -> AgentAction {
    .replaceText(elementIdentifier: "e3", findText: findText, replacementText: replacementText, occurrence: .first,
                 insertionPosition: .atFind)
}

private let plainTextAreaNode = makeFixtureNode("e3", "AXTextArea", value: "old text")
private let passwordFieldNode = makeFixtureNode("e3", "AXTextField", subrole: "AXSecureTextField", isSecure: true)

let safetyGateReplaceTextTestSuite = CoreTestSuite(name: "SafetyGate replace_text", testCases: [
    CoreTestCase(name: "a replacement without a line break runs without asking and is not risky") {
        let action = replaceTextAction(replacementText: "new")
        try expectEqual(SafetyGate.evaluateAction(action, targetNode: plainTextAreaNode, riskCategoryConfirmedForThisItem: nil,
                                                  targetApplicationBundleIdentifier: "com.apple.MobileSMS"), .allow)
        try expectTrue(!SafetyGate.actionIsRiskyWithoutAnyGrant(action, targetNode: plainTextAreaNode,
                                                                targetApplicationBundleIdentifier: "com.apple.MobileSMS"))
    },
    CoreTestCase(name: "a line break is classified like typed Return: a send in chat, mail and browsers, pressing Return elsewhere") {
        let action = replaceTextAction(replacementText: "first line\nsecond line")
        try expectEqual(riskCategory(of: SafetyGate.evaluateAction(action, targetNode: plainTextAreaNode, riskCategoryConfirmedForThisItem: nil,
                                                                   targetApplicationBundleIdentifier: "com.apple.MobileSMS")),
                        .sendingOrPublishing)
        try expectEqual(riskCategory(of: SafetyGate.evaluateAction(action, targetNode: plainTextAreaNode, riskCategoryConfirmedForThisItem: nil,
                                                                   targetApplicationBundleIdentifier: "com.apple.Safari")),
                        .sendingOrPublishing)
        // .pressingReturn no longer asks, but an item that took it is never retried automatically.
        try expectEqual(SafetyGate.evaluateAction(action, targetNode: plainTextAreaNode, riskCategoryConfirmedForThisItem: nil,
                                                  targetApplicationBundleIdentifier: "com.apple.TextEdit"), .allow)
        try expectTrue(SafetyGate.actionIsRiskyWithoutAnyGrant(action, targetNode: plainTextAreaNode,
                                                               targetApplicationBundleIdentifier: "com.apple.TextEdit"))
        try expectEqual(SafetyGate.evaluateAction(action, targetNode: plainTextAreaNode, riskCategoryConfirmedForThisItem: nil,
                                                  targetApplicationBundleIdentifier: "com.apple.TextEdit"),
                        SafetyGate.evaluateAction(.typeText(elementIdentifier: "e3", text: "first line\nsecond line",
                                                            replaceExistingText: false, pressReturnAfter: false),
                                                  targetNode: plainTextAreaNode, riskCategoryConfirmedForThisItem: nil,
                                                  targetApplicationBundleIdentifier: "com.apple.TextEdit"))
    },
    CoreTestCase(name: "a password field is denied, whatever was confirmed or granted") {
        let action = replaceTextAction(replacementText: "hunter2")
        guard case .deny = SafetyGate.evaluateAction(action, targetNode: passwordFieldNode, riskCategoryConfirmedForThisItem: .pressingReturn,
                                                     riskCategoriesAllowedForRestOfTask: Set(SafetyRiskCategory.allCases)) else {
            throw CoreTestFailure(description: "replace_text into a password field must be denied")
        }
        try expectTrue(SafetyGate.actionIsRiskyWithoutAnyGrant(action, targetNode: passwordFieldNode))
    },
    CoreTestCase(name: "replace_text never needs the app in front, may change data, and never closes a window") {
        let action = replaceTextAction(replacementText: "new")
        try expectTrue(!BackgroundActionPolicy.requiresForeground(action, targetNode: plainTextAreaNode))
        try expectTrue(ChecklistItemRetryPolicy.actionHasSideEffects(action, targetNode: plainTextAreaNode))
        try expectTrue(!UserTakeoverDetector.automatedActionMayCloseWindow(action))
    },
])
