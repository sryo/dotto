import Foundation

private func followUp(_ runStatus: ChecklistItemRunStatus, retriesUsed: Int = 0, irreversible: Bool = false,
                      confirmedAction: Bool = false, canAskUser: Bool = true) -> ChecklistItemAttemptFollowUp {
    ChecklistItemRetryPolicy.followUp(afterAttemptWith: runStatus, automaticRetriesUsed: retriesUsed, itemIsIrreversible: irreversible,
                                      itemPerformedUserConfirmedAction: confirmedAction, canAskUser: canAskUser)
}

let checklistItemRetryPolicyTestSuite = CoreTestSuite(name: "ChecklistItemRetryPolicy", testCases: [
    CoreTestCase(name: "completed, skipped, pending and running are accepted") {
        for runStatus in [ChecklistItemRunStatus.completed, .skipped, .pending, .running] {
            try expectEqual(followUp(runStatus), .acceptResult, "\(runStatus)")
        }
    },
    CoreTestCase(name: "needsUser asks the user when possible") {
        try expectEqual(followUp(.needsUser), .askUser)
        try expectEqual(followUp(.needsUser, canAskUser: false), .acceptResult)
    },
    CoreTestCase(name: "failed irreversible or confirmed items are never retried automatically") {
        try expectEqual(followUp(.failed, irreversible: true), .askUser)
        try expectEqual(followUp(.failed, confirmedAction: true), .askUser)
        try expectEqual(followUp(.failed, irreversible: true, canAskUser: false), .acceptResult)
    },
    CoreTestCase(name: "failed items retry twice, then ask") {
        try expectEqual(followUp(.failed, retriesUsed: 0), .retryAutomatically)
        try expectEqual(followUp(.failed, retriesUsed: 1), .retryAutomatically)
        try expectEqual(followUp(.failed, retriesUsed: ChecklistItemRetryPolicy.maximumAutomaticRetries), .askUser)
        try expectEqual(followUp(.failed, retriesUsed: 2, canAskUser: false), .acceptResult)
    },
    CoreTestCase(name: "deterministic failures are never retried automatically") {
        try expectEqual(ChecklistItemRetryPolicy.followUp(afterAttemptWith: .failed, automaticRetriesUsed: 0, itemIsIrreversible: false,
                                                          itemPerformedUserConfirmedAction: false, canAskUser: true,
                                                          attemptFailedDeterministically: true), .askUser)
    },
    CoreTestCase(name: "after a side-effecting action only one automatic retry is allowed") {
        func followUpAfterSideEffects(retriesUsed: Int) -> ChecklistItemAttemptFollowUp {
            ChecklistItemRetryPolicy.followUp(afterAttemptWith: .failed, automaticRetriesUsed: retriesUsed, itemIsIrreversible: false,
                                              itemPerformedUserConfirmedAction: false, canAskUser: true, itemPerformedSideEffectingAction: true)
        }
        try expectEqual(followUpAfterSideEffects(retriesUsed: 0), .retryAutomatically)
        try expectEqual(followUpAfterSideEffects(retriesUsed: 1), .askUser)
    },
    CoreTestCase(name: "typing and pressing controls have side effects; selecting rows, scrolling and navigation keys don't") {
        let row = makeFixtureNode("r", "AXRow")
        let button = makeFixtureNode("b", "AXButton", title: "Rename")
        try expectEqual(ChecklistItemRetryPolicy.actionHasSideEffects(.clickElement(elementIdentifier: "r", clickType: .single), targetNode: row), false)
        try expectEqual(ChecklistItemRetryPolicy.actionHasSideEffects(.clickElement(elementIdentifier: "b", clickType: .single), targetNode: button), true)
        try expectEqual(ChecklistItemRetryPolicy.actionHasSideEffects(.clickElement(elementIdentifier: "b", clickType: .right), targetNode: button), false)
        try expectEqual(ChecklistItemRetryPolicy.actionHasSideEffects(.typeText(elementIdentifier: nil, text: "x", replaceExistingText: false,
                                                                                pressReturnAfter: false), targetNode: nil), true)
        try expectEqual(ChecklistItemRetryPolicy.actionHasSideEffects(.scroll(elementIdentifier: nil, direction: .down, pages: 1), targetNode: nil), false)
        try expectEqual(ChecklistItemRetryPolicy.actionHasSideEffects(.pressKey(keyName: "tab", modifiers: [.shift]), targetNode: nil), false)
        try expectEqual(ChecklistItemRetryPolicy.actionHasSideEffects(.pressKey(keyName: "down", modifiers: []), targetNode: nil), false)
        try expectEqual(ChecklistItemRetryPolicy.actionHasSideEffects(.pressKey(keyName: "v", modifiers: [.command]), targetNode: nil), true)
    },
])
