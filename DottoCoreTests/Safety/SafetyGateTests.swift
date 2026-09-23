import Foundation
import CoreGraphics

private func makeButtonNode(title: String?, description: String? = nil, helpText: String? = nil,
                            isSecureTextField: Bool = false,
                            children: [AccessibilityElementNode] = []) -> AccessibilityElementNode {
    makeFixtureNode("e7", isSecureTextField ? "AXTextField" : "AXButton", subrole: isSecureTextField ? "AXSecureTextField" : nil,
                    title: title, description: description, helpText: helpText, isSecure: isSecureTextField,
                    supportsPressAction: !isSecureTextField, children: children)
}

private let clickOnE7 = AgentAction.clickElement(elementIdentifier: "e7", clickType: .single)

/// A category that no longer asks (the owner's 2026-09-23 decision) still classifies the action as risky, so the
/// action runs without a question but an item that took it is never retried automatically.
private func expectRunsWithoutAskingButStaysRisky(_ action: AgentAction, targetNode: AccessibilityElementNode? = nil,
                                                  focusedNode: AccessibilityElementNode? = nil,
                                                  targetApplicationBundleIdentifier: String? = nil, _ message: String = "") throws {
    try expectEqual(SafetyGate.evaluateAction(action, targetNode: targetNode, riskCategoryConfirmedForThisItem: nil, focusedNode: focusedNode,
                                              targetApplicationBundleIdentifier: targetApplicationBundleIdentifier), .allow, message)
    try expectTrue(SafetyGate.actionIsRiskyWithoutAnyGrant(action, targetNode: targetNode, focusedNode: focusedNode,
                                                           targetApplicationBundleIdentifier: targetApplicationBundleIdentifier), message)
}

private func categoryIn(_ bundleIdentifier: String?, _ action: AgentAction, focusedNode: AccessibilityElementNode? = nil) -> SafetyRiskCategory? {
    riskCategory(of: SafetyGate.evaluateAction(action, targetNode: nil, riskCategoryConfirmedForThisItem: nil, focusedNode: focusedNode,
                                               targetApplicationBundleIdentifier: bundleIdentifier))
}

let safetyGateTestSuite = CoreTestSuite(name: "SafetyGate", testCases: [
    CoreTestCase(name: "risky verbs match whole words, case-insensitively, with plural and -ing forms") {
        for riskyText in ["Send", "Posts", "DELETE draft", "Move to Trash", "pay now", "Submit.", "check-out: Checkout", "Confirms order",
                          "Sending…", "Deleting", "Submitting", "Publishes", "Paying", "Delete…"] {
            try expectTrue(SafetyRiskVocabulary.firstRiskMatch(in: riskyText) != nil, riskyText)
        }
        for safeText in ["Deleted items", "Sender", "Postal code", "Payment", "Rename", "Scheduled", "", "submitted",
                         "Sort order", "Forward", "Email address", "Design", "Signal"] {
            try expectTrue(SafetyRiskVocabulary.firstRiskMatch(in: safeText) == nil, safeText)
        }
    },
    CoreTestCase(name: "extra English verbs and phrases are risky, each in its category") {
        let expectedCategoryByText: [String: SafetyRiskCategory] = [
            "Tweet": .sendingOrPublishing, "Reply all": .sendingOrPublishing, "Share": .sendingOrPublishing,
            "Place order": .payingOrBuying, "Check out": .payingOrBuying, "Order now": .payingOrBuying,
            "Move to Bin": .deleting, "Discard": .deleting, "Don't Save": .deleting, "Don’t Save": .deleting,
            "Archive": .deleting, "Unsubscribe": .deleting,
            "Merge pull request": .submittingOrApproving, "Deploy": .submittingOrApproving, "Accept": .submittingOrApproving,
            "Approve": .submittingOrApproving, "Upload": .submittingOrApproving, "Replace": .submittingOrApproving,
            "Sign": .submittingOrApproving, "Transfer": .payingOrBuying,
        ]
        for (riskyText, expectedCategory) in expectedCategoryByText {
            try expectEqual(SafetyRiskVocabulary.firstRiskMatch(in: riskyText)?.riskCategory, expectedCategory, riskyText)
        }
    },
    CoreTestCase(name: "localized verbs are risky") {
        for riskyText in ["Enviar", "Publicar", "Eliminar", "Borrar", "Comprar", "Pagar", "Senden", "Löschen", "Kaufen",
                          "Supprimer", "Envoyer", "Acheter", "Invia", "Elimina", "Acquista", "送信", "削除する", "立即购买", "发送消息",
                          "Excluir", "Bestätigen"] {
            try expectTrue(SafetyRiskVocabulary.firstRiskMatch(in: riskyText) != nil, riskyText)
        }
    },
    CoreTestCase(name: "an approved item's own wording never asks: irreversible or risky items run, their actions are checked") {
        var checklist = makeFixtureChecklist(itemCount: 4, irreversibleItemIdentifiers: ["item-1"])
        checklist.items[1].actionSummary = "Click Send in the compose window."
        checklist.items[3].parameters = [ChecklistItemParameter(name: "button", value: "Löschen")]
        for checklistItem in checklist.items {
            try expectEqual(SafetyGate.evaluateChecklistItem(checklistItem), .allow, checklistItem.itemIdentifier)
        }
        // The Send click the item leads to still asks.
        try expectEqual(riskCategory(of: ungrantedVerdict(clickOnE7, targetNode: makeButtonNode(title: "Send"))), .sendingOrPublishing)
    },
    CoreTestCase(name: "only sending, deleting, paying, bringing forward, uploading and shortcuts ask") {
        let askingCategories = Set(SafetyRiskCategory.allCases.filter(\.asksUser))
        try expectEqual(askingCategories, [.sendingOrPublishing, .deleting, .payingOrBuying, .bringingAppForward, .uploadingFiles, .runningShortcut])
        for riskCategory in SafetyRiskCategory.allCases {
            let verdict = SafetyVerdict.requireUserConfirmation(reason: "r", riskCategory: riskCategory)
            try expectEqual(SafetyGate.applyingAskPolicy(verdict), riskCategory.asksUser ? verdict : .allow, riskCategory.rawValue)
        }
        try expectEqual(SafetyGate.applyingAskPolicy(.deny(reasonForModel: "no")), .deny(reasonForModel: "no"))
    },
    CoreTestCase(name: "a label with several risky words asks under the one that asks") {
        try expectEqual(SafetyRiskVocabulary.firstRiskMatch(in: "Confirm and delete")?.riskCategory, .deleting)
        try expectEqual(SafetyRiskVocabulary.firstRiskMatch(in: "Accept and pay")?.riskCategory, .payingOrBuying)
        try expectEqual(SafetyRiskVocabulary.firstRiskMatch(in: "Confirm")?.riskCategory, .submittingOrApproving)
        try expectEqual(riskCategory(of: ungrantedVerdict(clickOnE7, targetNode: makeButtonNode(title: "Confirm purchase"))), .payingOrBuying)
        try expectEqual(riskCategory(of: ungrantedVerdict(clickOnE7, targetNode: makeButtonNode(title: "Submit", helpText: "Sends the form"))),
                        .sendingOrPublishing)
        try expectEqual(SafetyRiskVocabulary.firstRiskMatch(inChecklistItemLabel: "Approve", actionSummary: "Approve and remove it.",
                                                           parameters: [])?.riskCategory, .deleting)
    },
    CoreTestCase(name: "planner items with risky wording are marked irreversible at plan time") {
        let submittedChecklist = SubmittedChecklistDraft(taskTitle: "Tidy", messageToUser: nil, items: [
            SubmittedChecklistDraftItem(label: "Tidy note 1", actionSummary: "Open the note and press Discard.", parameters: [], isIrreversible: false),
            SubmittedChecklistDraftItem(label: "Rename note 2", actionSummary: "Rename it.",
                                        parameters: [ChecklistItemParameter(name: "action", value: "place order")], isIrreversible: false),
            SubmittedChecklistDraftItem(label: "Rename note 3", actionSummary: "Rename it.", parameters: [], isIrreversible: false),
        ])
        let checklist = Checklist.fromPlannerSubmission(submittedChecklist, originalCommand: "tidy", targetApplication: fixtureTargetApplication,
                                                        taskIdentifier: "t", createdAt: Date(timeIntervalSince1970: 0))
        try expectEqual(checklist.items.map(\.isIrreversible), [true, true, false])
    },
    CoreTestCase(name: "typing into a secure field is denied even when confirmed") {
        let secureNode = makeButtonNode(title: "Password", isSecureTextField: true)
        let typeAction = AgentAction.typeText(elementIdentifier: "e7", text: "hunter2", replaceExistingText: false, pressReturnAfter: false)
        try expectEqual(SafetyGate.evaluateAction(typeAction, targetNode: secureNode, riskCategoryConfirmedForThisItem: .irreversibleItem,
                                                  riskCategoriesAllowedForRestOfTask: Set(SafetyRiskCategory.allCases)),
                        .deny(reasonForModel: "Typing into password fields is not allowed."))
        try expectEqual(ungrantedVerdict(typeAction, targetNode: makeButtonNode(title: "Name")), .allow)
    },
    CoreTestCase(name: "typing then Return (newline or press_return_after) asks as a send only where Return sends") {
        let typeWithReturn = AgentAction.typeText(elementIdentifier: "e7", text: "hello", replaceExistingText: false, pressReturnAfter: true)
        let typeWithNewline = AgentAction.typeText(elementIdentifier: "e7", text: "hello\nworld", replaceExistingText: false, pressReturnAfter: false)
        let typeWithCarriageReturn = AgentAction.typeText(elementIdentifier: nil, text: "hi\r", replaceExistingText: false, pressReturnAfter: false)
        for submittingTypeAction in [typeWithReturn, typeWithNewline, typeWithCarriageReturn] {
            try expectRunsWithoutAskingButStaysRisky(submittingTypeAction, targetNode: makeButtonNode(title: "Name"))
            try expectRunsWithoutAskingButStaysRisky(submittingTypeAction, targetApplicationBundleIdentifier: "com.apple.TextEdit")
            for returnSendsBundleIdentifier in ["com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser", "net.whatsapp.WhatsApp"] {
                try expectEqual(categoryIn(returnSendsBundleIdentifier, submittingTypeAction), .sendingOrPublishing, returnSendsBundleIdentifier)
            }
        }
    },
    CoreTestCase(name: "clicking a risky element asks unless the item was confirmed for that category") {
        try expectEqual(ungrantedVerdict(clickOnE7, targetNode: makeButtonNode(title: "Send")),
                        .requireUserConfirmation(reason: "This step will click “Send”.", riskCategory: .sendingOrPublishing))
        try expectEqual(ungrantedVerdict(clickOnE7, targetNode: makeButtonNode(title: nil, description: "Delete")),
                        .requireUserConfirmation(reason: "This step will click “Delete”.", riskCategory: .deleting))
        try expectEqual(SafetyGate.evaluateAction(clickOnE7, targetNode: makeButtonNode(title: "Send"), riskCategoryConfirmedForThisItem: .sendingOrPublishing), .allow)
        try expectEqual(ungrantedVerdict(clickOnE7, targetNode: makeButtonNode(title: "Rename")), .allow)
    },
    CoreTestCase(name: "click risk also reads help text and child labels") {
        try expectEqual(riskCategory(of: ungrantedVerdict(clickOnE7, targetNode: makeButtonNode(title: "", helpText: "Move to Trash"))), .deleting)
        let childLabel = makeButtonNode(title: "Publicar")
        try expectEqual(riskCategory(of: ungrantedVerdict(clickOnE7, targetNode: makeButtonNode(title: nil, children: [childLabel]))),
                        .sendingOrPublishing)
    },
    CoreTestCase(name: "unresolved, unlabeled and pixel clicks run without asking but stay risky (never retried)") {
        try expectRunsWithoutAskingButStaysRisky(clickOnE7, targetNode: nil)
        try expectRunsWithoutAskingButStaysRisky(clickOnE7, targetNode: makeButtonNode(title: nil))
        try expectRunsWithoutAskingButStaysRisky(clickOnE7, targetNode: makeButtonNode(title: "   "))
        try expectRunsWithoutAskingButStaysRisky(.clickScreenshotPoint(screenshotPixelPoint: .zero, clickType: .single))
        try expectRunsWithoutAskingButStaysRisky(clickOnE7, targetNode: makeButtonNode(title: "Submit"))
        try expectRunsWithoutAskingButStaysRisky(clickOnE7, targetNode: makeButtonNode(title: "Accept"))
        try expectTrue(!SafetyGate.actionIsRiskyWithoutAnyGrant(clickOnE7, targetNode: makeButtonNode(title: "Rename")))
    },
    CoreTestCase(name: "key names are normalized before checks") {
        for returnAlias in ["return", "Return", "enter", "ENTER", "kp_enter", "keypad-enter", " enter ", "↩"] {
            try expectEqual(SafetyGate.canonicalKeyName(returnAlias), "return", returnAlias)
        }
        for deleteAlias in ["delete", "backspace", "BackSpace", "del", "⌫"] {
            try expectEqual(SafetyGate.canonicalKeyName(deleteAlias), "delete", deleteAlias)
        }
        try expectEqual(SafetyGate.canonicalKeyName("fwd_delete"), "forward_delete")
    },
    CoreTestCase(name: "Return asks as a send in browsers and chat apps, whatever the alias; elsewhere it runs but stays risky") {
        for returnAlias in ["return", "enter", "kp_enter", "Enter"] {
            for modifiers in [[], [AgentKeyModifier.command]] {
                let returnPress = AgentAction.pressKey(keyName: returnAlias, modifiers: modifiers)
                try expectRunsWithoutAskingButStaysRisky(returnPress, returnAlias)
                try expectRunsWithoutAskingButStaysRisky(returnPress, targetApplicationBundleIdentifier: "com.apple.TextEdit", returnAlias)
                for returnSendsBundleIdentifier in ["com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser",
                                                    "com.apple.MobileSMS", "net.whatsapp.WhatsApp", "desktop.WhatsApp"] {
                    try expectEqual(categoryIn(returnSendsBundleIdentifier, returnPress), .sendingOrPublishing, "\(returnSendsBundleIdentifier) \(returnAlias)")
                }
            }
        }
        try expectEqual(SafetyGate.evaluateAction(.pressKey(keyName: "return", modifiers: [.command]), targetNode: nil, riskCategoryConfirmedForThisItem: nil,
                                                  targetApplicationBundleIdentifier: "com.apple.Safari"),
                        .requireUserConfirmation(reason: "This step will press ⌘Return, which sends or submits in this app.", riskCategory: .sendingOrPublishing))
        try expectEqual(SafetyGate.evaluateAction(.pressKey(keyName: "return", modifiers: []), targetNode: nil, riskCategoryConfirmedForThisItem: nil,
                                                  riskCategoriesAllowedForRestOfTask: [.sendingOrPublishing],
                                                  targetApplicationBundleIdentifier: "com.apple.Safari"), .allow)
        try expectEqual(ungrantedVerdict(.pressKey(keyName: "s", modifiers: [.command])), .allow)
        try expectEqual(ungrantedVerdict(.pressKey(keyName: "tab", modifiers: [])), .allow)
    },
    CoreTestCase(name: "⌘Delete variants ask as deleting; ⌘Q and ⌘W run but stay risky") {
        let deletingShortcuts: [(String, [AgentKeyModifier])] = [
            ("delete", [.command]), ("backspace", [.command]), ("delete", [.option, .shift, .command]), ("forward_delete", [.command]),
        ]
        for (keyName, modifiers) in deletingShortcuts {
            try expectEqual(riskCategory(of: ungrantedVerdict(.pressKey(keyName: keyName, modifiers: modifiers))), .deleting,
                            "\(modifiers)+\(keyName)")
        }
        let quittingOrClosingShortcuts: [(String, [AgentKeyModifier])] = [("q", [.command]), ("Q", [.command]), ("w", [.command]), ("w", [.shift, .command])]
        for (keyName, modifiers) in quittingOrClosingShortcuts {
            try expectRunsWithoutAskingButStaysRisky(.pressKey(keyName: keyName, modifiers: modifiers), "\(modifiers)+\(keyName)")
        }
        try expectEqual(ungrantedVerdict(.pressKey(keyName: "backspace", modifiers: [])), .allow)
        try expectEqual(ungrantedVerdict(.pressKey(keyName: "q", modifiers: [])), .allow)
    },
    CoreTestCase(name: "an allowed category skips only that category") {
        let sendingOnly: Set<SafetyRiskCategory> = [.sendingOrPublishing]
        try expectEqual(SafetyGate.evaluateAction(clickOnE7, targetNode: makeButtonNode(title: "Send"), riskCategoryConfirmedForThisItem: nil,
                                                  riskCategoriesAllowedForRestOfTask: sendingOnly), .allow)
        try expectEqual(riskCategory(of: SafetyGate.evaluateAction(clickOnE7, targetNode: makeButtonNode(title: "Delete"), riskCategoryConfirmedForThisItem: nil,
                                                                   riskCategoriesAllowedForRestOfTask: sendingOnly)), .deleting)
        try expectEqual(riskCategory(of: SafetyGate.evaluateAction(clickOnE7, targetNode: makeButtonNode(title: "Buy now"), riskCategoryConfirmedForThisItem: nil,
                                                                   riskCategoriesAllowedForRestOfTask: sendingOnly)), .payingOrBuying)
        try expectEqual(riskCategory(of: SafetyGate.evaluateAction(clickOnE7, targetNode: makeButtonNode(title: "Send"), riskCategoryConfirmedForThisItem: .deleting,
                                                                   riskCategoriesAllowedForRestOfTask: [.payingOrBuying, .uploadingFiles])),
                        .sendingOrPublishing)
    },
    CoreTestCase(name: "an item confirmed only as irreversible does not cover a Send click (no blanket pass)") {
        let sendButton = makeButtonNode(title: "Send")
        try expectEqual(riskCategory(of: SafetyGate.evaluateAction(clickOnE7, targetNode: sendButton,
                                                                   riskCategoryConfirmedForThisItem: .irreversibleItem)), .sendingOrPublishing)
        try expectEqual(riskCategory(of: SafetyGate.evaluateAction(clickOnE7, targetNode: makeButtonNode(title: "Delete"),
                                                                   riskCategoryConfirmedForThisItem: .sendingOrPublishing,
                                                                   riskCategoriesAllowedForRestOfTask: [.irreversibleItem])), .deleting)
    },
    CoreTestCase(name: "an item plan built from a routine asks under the routine step's category") {
        var routineItem = ChecklistItem(itemIdentifier: "item-1", label: "Handle a.txt", actionSummary: "Handle a.txt.",
                                        parameters: [ChecklistItemParameter(name: "file_name", value: "a.txt")], isIrreversible: true)
        routineItem.confirmationRiskCategoriesFromRoutine = [.deleting, .sendingOrPublishing]
        try expectEqual(riskCategory(of: SafetyGate.evaluateChecklistItem(routineItem)), .deleting)
        routineItem.confirmationRiskCategoriesFromRoutine = [.pressingReturn, .payingOrBuying]
        try expectEqual(riskCategory(of: SafetyGate.evaluateChecklistItem(routineItem)), .payingOrBuying)
        routineItem.confirmationRiskCategoriesFromRoutine = [.pressingReturn, .unverifiableClick]
        try expectEqual(SafetyGate.evaluateChecklistItem(routineItem), .allow)
        routineItem.confirmationRiskCategoriesFromRoutine = []
        try expectEqual(SafetyGate.evaluateChecklistItem(routineItem), .allow)
    },
    CoreTestCase(name: "Control-M, Control-J and Control-O count as pressing Return") {
        for keyName in ["m", "j", "o", "M"] {
            let controlKeyPress = AgentAction.pressKey(keyName: keyName, modifiers: [.control])
            try expectRunsWithoutAskingButStaysRisky(controlKeyPress, targetApplicationBundleIdentifier: "com.apple.TextEdit", keyName)
            try expectEqual(categoryIn("com.apple.Safari", controlKeyPress), .sendingOrPublishing, keyName)
            try expectEqual(categoryIn("net.whatsapp.WhatsApp", controlKeyPress), .sendingOrPublishing, keyName)
        }
        try expectEqual(ungrantedVerdict(.pressKey(keyName: "a", modifiers: [.control])), .allow)
        try expectEqual(ungrantedVerdict(.pressKey(keyName: "m", modifiers: [])), .allow)
    },
    CoreTestCase(name: "Space or Return on a focused button is judged as a click on that button") {
        var focusedSendButton = makeButtonNode(title: "Send")
        focusedSendButton.isFocused = true
        for keyName in ["space", " ", "return"] {
            try expectEqual(riskCategory(of: SafetyGate.evaluateAction(.pressKey(keyName: keyName, modifiers: []), targetNode: nil,
                                                                       riskCategoryConfirmedForThisItem: nil, focusedNode: focusedSendButton)),
                            .sendingOrPublishing, keyName)
        }
        try expectRunsWithoutAskingButStaysRisky(.pressKey(keyName: "space", modifiers: []), focusedNode: makeButtonNode(title: nil))
        // Where Return sends, Return on a focused control whose own category doesn't ask still asks as a send.
        for focusedButtonTitle in [nil, "Submit"] {
            try expectEqual(categoryIn("com.apple.Safari", .pressKey(keyName: "return", modifiers: []), focusedNode: makeButtonNode(title: focusedButtonTitle)),
                            .sendingOrPublishing, focusedButtonTitle ?? "unlabeled")
            try expectRunsWithoutAskingButStaysRisky(.pressKey(keyName: "return", modifiers: []), focusedNode: makeButtonNode(title: focusedButtonTitle),
                                                     targetApplicationBundleIdentifier: "com.apple.TextEdit")
        }
        try expectEqual(categoryIn("com.apple.TextEdit", .pressKey(keyName: "return", modifiers: []), focusedNode: makeButtonNode(title: "Delete")), .deleting)
        try expectEqual(SafetyGate.evaluateAction(.pressKey(keyName: "space", modifiers: []), targetNode: nil, riskCategoryConfirmedForThisItem: nil,
                                                  focusedNode: makeButtonNode(title: "Rename")), .allow)
        var focusedTextField = makeButtonNode(title: "Name")
        focusedTextField.role = "AXTextField"
        try expectEqual(SafetyGate.evaluateAction(.pressKey(keyName: "space", modifiers: []), targetNode: nil, riskCategoryConfirmedForThisItem: nil,
                                                  focusedNode: focusedTextField), .allow)
    },
    CoreTestCase(name: "per-app send shortcuts count as sending") {
        func category(_ keyName: String, _ modifiers: [AgentKeyModifier], _ bundleIdentifier: String) -> SafetyRiskCategory? {
            riskCategory(of: SafetyGate.evaluateAction(.pressKey(keyName: keyName, modifiers: modifiers), targetNode: nil,
                                                       riskCategoryConfirmedForThisItem: nil, targetApplicationBundleIdentifier: bundleIdentifier))
        }
        try expectEqual(category("d", [.command, .shift], "com.apple.mail"), .sendingOrPublishing)
        try expectEqual(category("d", [.command, .shift], "com.apple.finder"), nil)
        try expectEqual(category("return", [], "com.apple.MobileSMS"), .sendingOrPublishing)
        try expectEqual(category("enter", [], "com.tinyspeck.slackmacgap"), .sendingOrPublishing)
        try expectEqual(category("return", [], "com.hnc.Discord"), .sendingOrPublishing)
        try expectEqual(category("return", [.command], "com.microsoft.Outlook"), .sendingOrPublishing)
        try expectEqual(category("return", [], "com.apple.finder"), nil)
        try expectRunsWithoutAskingButStaysRisky(.pressKey(keyName: "return", modifiers: []), targetApplicationBundleIdentifier: "com.apple.finder")
        let typeAndSend = AgentAction.typeText(elementIdentifier: nil, text: "hi", replaceExistingText: false, pressReturnAfter: true)
        try expectEqual(riskCategory(of: SafetyGate.evaluateAction(typeAndSend, targetNode: nil, riskCategoryConfirmedForThisItem: nil,
                                                                   targetApplicationBundleIdentifier: "com.apple.MobileSMS")), .sendingOrPublishing)
        try expectEqual(SafetyGate.actionIsRiskyWithoutAnyGrant(.pressKey(keyName: "d", modifiers: [.command, .shift]), targetNode: nil,
                                                                targetApplicationBundleIdentifier: "com.apple.mail"), true)
    },
    CoreTestCase(name: "typing into a focused password field is denied when no target is named") {
        let secureField = makeButtonNode(title: "Password", isSecureTextField: true)
        let typeIntoFocus = AgentAction.typeText(elementIdentifier: nil, text: "x", replaceExistingText: false, pressReturnAfter: false)
        try expectEqual(SafetyGate.evaluateAction(typeIntoFocus, targetNode: nil, riskCategoryConfirmedForThisItem: nil, focusedNode: secureField),
                        .deny(reasonForModel: "Typing into password fields is not allowed."))
    },
    CoreTestCase(name: "scroll is allowed") {
        try expectEqual(ungrantedVerdict(.scroll(elementIdentifier: nil, direction: .down, pages: 2)), .allow)
    },
    CoreTestCase(name: "standard limits match the plan") {
        try expectEqual(SafetyLimits.standard, SafetyLimits(maximumActionsPerItem: 25, maximumActionsPerTask: 500, maximumModelTurnsPerItem: 40,
                                                            maximumModelTurnsForPlanning: 12, maximumConsecutiveFailedItems: 3,
                                                            maximumTaskWallClockSeconds: 1800, maximumModelTurnsPerTask: 600,
                                                            maximumInputTokensPerTask: 6_000_000,
                                                            maximumRetainedScreenshotsPerConversation: 8))
    },
    CoreTestCase(name: "uploads need the uploading-files confirmation, naming files by basename only") {
        let uploadAction = AgentAction.uploadFiles(elementIdentifier: "e7", filePaths: (1...7).map { "/Users/me/Private Folder/scan\($0).pdf" })
        let allowlist = UploadFileAllowlist(grants: [UploadFileGrant.userPicked(canonicalPath: "/Users/me/Private Folder", isDirectory: true)],
                                            homeDirectoryPath: "/Users/me")
        let verdict = SafetyGate.evaluateAction(uploadAction, targetNode: makeButtonNode(title: "Choose File"),
                                                riskCategoryConfirmedForThisItem: nil, uploadFileAllowlist: allowlist)
        guard case .requireUserConfirmation(let reason, let uploadRiskCategory) = verdict else { throw CoreTestFailure(description: "\(verdict)") }
        try expectEqual(uploadRiskCategory, .uploadingFiles)
        try expectTrue(reason.hasPrefix("This step opens the file dialog and attaches “scan1.pdf”, “scan2.pdf”, “scan3.pdf”, “scan4.pdf”, “scan5.pdf” and 2 more."), reason)
        try expectTrue(reason.hasSuffix("covers only what you attached: files in the folder “Private Folder”."), reason)
        try expectTrue(!reason.contains("/Users"), reason)
        // An upload grant covers later uploads; an unrelated grant doesn't.
        try expectEqual(SafetyGate.evaluateAction(uploadAction, targetNode: nil, riskCategoryConfirmedForThisItem: nil,
                                                  riskCategoriesAllowedForRestOfTask: [.uploadingFiles]), .allow)
        try expectEqual(riskCategory(of: SafetyGate.evaluateAction(uploadAction, targetNode: nil, riskCategoryConfirmedForThisItem: .irreversibleItem,
                                                                   riskCategoriesAllowedForRestOfTask: [.bringingAppForward])), .uploadingFiles)
    },
    CoreTestCase(name: "bringing an app forward is covered only by its own category, in both directions") {
        func assistVerdict(confirmed: SafetyRiskCategory?, grants: Set<SafetyRiskCategory>) -> SafetyVerdict {
            SafetyGate.evaluateForegroundAssist(failedActionDescription: "click", targetApplicationName: "Arc",
                                                riskCategoryConfirmedForThisItem: confirmed, riskCategoriesAllowedForRestOfTask: grants)
        }
        try expectEqual(assistVerdict(confirmed: nil, grants: [.bringingAppForward]), .allow)
        try expectEqual(assistVerdict(confirmed: .bringingAppForward, grants: []), .allow)
        for otherCategory in SafetyRiskCategory.allCases where otherCategory != .bringingAppForward {
            try expectEqual(riskCategory(of: assistVerdict(confirmed: otherCategory, grants: [otherCategory])), .bringingAppForward,
                            otherCategory.rawValue)
        }
        guard case .requireUserConfirmation(let reason, _) = assistVerdict(confirmed: nil, grants: []) else {
            throw CoreTestFailure(description: "expected a confirmation")
        }
        try expectEqual(reason, "Dotto's click didn't reach Arc while it stayed in the background. Bring Arc forward for a moment to retry it? "
                        + "Dotto switches back to where you were right after.")
        let uploadAction = AgentAction.uploadFiles(elementIdentifier: "e7", filePaths: ["/Users/me/a.pdf"])
        try expectEqual(riskCategory(of: SafetyGate.evaluateAction(uploadAction, targetNode: nil, riskCategoryConfirmedForThisItem: .bringingAppForward,
                                                                   riskCategoriesAllowedForRestOfTask: [.bringingAppForward])), .uploadingFiles)
    },
])
