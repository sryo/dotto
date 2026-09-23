import Foundation

private let targetProcessIdentifier: Int32 = 500
private let openPanelServiceProcessIdentifier: Int32 = 700
private let userApplicationProcessIdentifier: Int32 = 600

private func safeConditions() -> FocusedKeyboardInputConditions {
    FocusedKeyboardInputConditions(foregroundAssistIsActive: true, runIsAborted: false,
                                   targetProcessIdentifier: targetProcessIdentifier,
                                   frontmostProcessIdentifier: targetProcessIdentifier,
                                   openPanelServiceProcessIdentifiers: [openPanelServiceProcessIdentifier],
                                   openPanelIsKeyWindow: true,
                                   realUserInputCountAtAssistStart: 12, realUserInputCountNow: 12)
}

let focusedKeyboardInputGuardTestSuite = CoreTestSuite(name: "FocusedKeyboardInputGuard", testCases: [
    CoreTestCase(name: "posts only inside the assist, with the target and its key open panel in front and no user input") {
        try expectEqual(FocusedKeyboardInputGuard.decision(for: safeConditions()), .post)
        var servicePanelConditions = safeConditions()
        servicePanelConditions.frontmostProcessIdentifier = openPanelServiceProcessIdentifier
        try expectEqual(FocusedKeyboardInputGuard.decision(for: servicePanelConditions), .post, "the sandboxed panel service may be in front")
    },
    CoreTestCase(name: "never outside the approved assist, even with everything else in place") {
        var conditions = safeConditions()
        conditions.foregroundAssistIsActive = false
        try expectEqual(FocusedKeyboardInputGuard.decision(for: conditions), .refuse(.outsideForegroundAssist))
    },
    CoreTestCase(name: "a stopped run refuses") {
        var conditions = safeConditions()
        conditions.runIsAborted = true
        try expectEqual(FocusedKeyboardInputGuard.decision(for: conditions), .refuse(.runStopped))
    },
    CoreTestCase(name: "any real user input since the assist began refuses; not observing at all refuses too") {
        var touchedConditions = safeConditions()
        touchedConditions.realUserInputCountNow = 13
        try expectEqual(FocusedKeyboardInputGuard.decision(for: touchedConditions), .refuse(.userInputObserved))
        var unobservedConditions = safeConditions()
        unobservedConditions.realUserInputCountNow = nil
        try expectEqual(FocusedKeyboardInputGuard.decision(for: unobservedConditions), .refuse(.userInputNotObservable))
        unobservedConditions = safeConditions()
        unobservedConditions.realUserInputCountAtAssistStart = nil
        try expectEqual(FocusedKeyboardInputGuard.decision(for: unobservedConditions), .refuse(.userInputNotObservable))
    },
    CoreTestCase(name: "another app in front, or no frontmost app, refuses") {
        var conditions = safeConditions()
        conditions.frontmostProcessIdentifier = userApplicationProcessIdentifier
        try expectEqual(FocusedKeyboardInputGuard.decision(for: conditions), .refuse(.targetNotFrontmost))
        conditions.frontmostProcessIdentifier = nil
        try expectEqual(FocusedKeyboardInputGuard.decision(for: conditions), .refuse(.targetNotFrontmost))
    },
    CoreTestCase(name: "the open panel no longer being the key window refuses") {
        var conditions = safeConditions()
        conditions.openPanelIsKeyWindow = false
        try expectEqual(FocusedKeyboardInputGuard.decision(for: conditions), .refuse(.openPanelNotKey))
    },
    CoreTestCase(name: "every refusal has a plain reason for the model") {
        let allRefusals: [FocusedKeyboardInputRefusal] = [.outsideForegroundAssist, .runStopped, .userInputNotObservable,
                                                          .userInputObserved, .targetNotFrontmost, .openPanelNotKey]
        for refusal in allRefusals {
            try expectTrue(!refusal.reasonForModel.isEmpty, refusal.rawValue)
        }
    },
])
