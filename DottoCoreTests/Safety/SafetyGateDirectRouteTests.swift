import Foundation

let safetyGateDirectRouteTestSuite = CoreTestSuite(name: "SafetyGate direct routes", testCases: [
    CoreTestCase(name: "script precedence: a denial beats a verb that asks; other risky verbs and modifies_data run") {
        let deniedAndRisky = makeScriptPlan(source: "tell application \"Mail\" to delete every message\ndo shell script \"ls\"", modifiesData: true)
        guard case .deny = SafetyGate.evaluateScriptPlan(deniedAndRisky) else { throw CoreTestFailure(description: "expected a denial") }

        let askingVerbScripts: [(String, SafetyRiskCategory)] = [
            ("tell application \"Mail\" to delete every message of mailbox \"Old\"", .deleting),
            ("tell application \"Mail\" to send (make new outgoing message)", .sendingOrPublishing),
            ("tell application \"Mail\" to forward message 1 of inbox", .sendingOrPublishing),
            ("tell application \"Mail\" to buy stamps", .payingOrBuying),
            // A verb that asks wins over an earlier one that doesn't.
            ("tell application \"Mail\" to set confirmed to true\ntell application \"Mail\" to delete message 1 of inbox", .deleting),
        ]
        for (source, expectedCategory) in askingVerbScripts {
            try expectEqual(riskCategory(of: SafetyGate.evaluateScriptPlan(makeScriptPlan(source: source, modifiesData: true))), expectedCategory, source)
        }

        // The user read the script verbatim and clicked Run: modifies_data and non-asking verbs don't ask again.
        let modifying = makeScriptPlan(source: "tell application \"Mail\" to make new mailbox with properties {name:\"Receipts\"}", modifiesData: true)
        try expectEqual(SafetyGate.evaluateScriptPlan(modifying), .allow)
        let approving = makeScriptPlan(source: "tell application \"Mail\" to set approve of message 1 to true", modifiesData: true)
        try expectEqual(ScriptSourceInspector.riskMatch(inSource: approving.source)?.riskCategory, .submittingOrApproving)
        try expectEqual(SafetyGate.evaluateScriptPlan(approving), .allow)

        let readOnly = makeScriptPlan(source: "tell application \"Mail\" to count mailboxes", modifiesData: false)
        try expectEqual(SafetyGate.evaluateScriptPlan(readOnly), .allow)
    },
    CoreTestCase(name: "a shortcut always asks under its own category") {
        let shortcutPlan = ShortcutPlan(shortcutName: "Resize for web", input: .none, oneSentenceSummary: "Resizes.", timeoutSeconds: 30)
        guard case .requireUserConfirmation(let reason, let riskCategory) = SafetyGate.evaluateShortcutPlan(shortcutPlan) else {
            throw CoreTestFailure(description: "expected a confirmation")
        }
        try expectEqual(riskCategory, .runningShortcut)
        try expectTrue(reason.contains("“Resize for web”"), reason)
    },
    CoreTestCase(name: "a plan that trashes asks under deleting, naming five items and the rest as a count") {
        let trashOperations = (1...7).map { fileNumber in
            makePlannedOperation(.moveToTrash, from: "/Users/me/Desktop/Shots/f\(fileNumber).png")
        }
        guard case .requireUserConfirmation(let reason, let riskCategory) = SafetyGate.evaluateFileOperationsPlan(makeFileOperationsPlan(trashOperations)) else {
            throw CoreTestFailure(description: "expected a confirmation")
        }
        try expectEqual(riskCategory, .deleting)
        try expectTrue(reason.contains("7 items") && reason.contains("“f5.png”") && !reason.contains("“f6.png”") && reason.contains("and 2 more"), reason)
        try expectEqual(SafetyGate.evaluateFileOperationsPlan(makeFileOperationsPlan(sortShotsOperations)), .allow)
    },
    CoreTestCase(name: "a script grant never covers deletes, and a shortcut answer never becomes a rest-of-task grant") {
        var grants: Set<SafetyRiskCategory> = []
        let auditLogWriter = try ConversationFixtures.makeAuditLogWriter()
        _ = await SafetyConfirmationFlow.askUser(
            SafetyConfirmationRequest(itemIdentifier: "item-1", itemLabel: "Tidy Mail", reason: "r", isActionLevel: false, riskCategory: .runningScript),
            confirmationRequester: ScriptedConfirmationRequester(scriptedAnswers: [.allowForAllRemainingItems]),
            auditLogWriter: auditLogWriter, riskCategoriesAllowedForRestOfTask: &grants, abortSignal: TaskAbortSignal())
        try expectEqual(grants, [.runningScript])
        try expectTrue(!grants.contains(.deleting))

        let shortcutOutcome = await SafetyConfirmationFlow.askUser(
            SafetyConfirmationRequest(itemIdentifier: "item-1", itemLabel: "Resize", reason: "r", isActionLevel: false, riskCategory: .runningShortcut),
            confirmationRequester: ScriptedConfirmationRequester(scriptedAnswers: [.allowForAllRemainingItems]),
            auditLogWriter: auditLogWriter, riskCategoriesAllowedForRestOfTask: &grants, abortSignal: TaskAbortSignal())
        try expectEqual(shortcutOutcome, .allowed(.runningShortcut))
        try expectEqual(grants, [.runningScript])
    },
    CoreTestCase(name: "every risk category has a scope description, and only shortcuts refuse the rest-of-task grant") {
        for riskCategory in SafetyRiskCategory.allCases {
            try expectTrue(!riskCategory.userFacingScopeDescription.isEmpty, riskCategory.rawValue)
            try expectEqual(riskCategory.offersRestOfTaskGrant, riskCategory != .runningShortcut, riskCategory.rawValue)
        }
    },
])
