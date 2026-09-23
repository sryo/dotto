import Foundation

private func askOnce(_ answer: SafetyConfirmationAnswer, riskCategory: SafetyRiskCategory = .deleting,
                     grants: inout Set<SafetyRiskCategory>, abortSignal: TaskAbortSignal) async throws -> SafetyConfirmationOutcome {
    await SafetyConfirmationFlow.askUser(
        SafetyConfirmationRequest(itemIdentifier: "item-1", itemLabel: "Tidy", reason: "This step will click “Delete”.",
                                  isActionLevel: true, riskCategory: riskCategory),
        confirmationRequester: ScriptedConfirmationRequester(scriptedAnswers: [answer]),
        auditLogWriter: try ConversationFixtures.makeAuditLogWriter(),
        riskCategoriesAllowedForRestOfTask: &grants, abortSignal: abortSignal)
}

let safetyConfirmationFlowTestSuite = CoreTestSuite(name: "SafetyConfirmationFlow", testCases: [
    CoreTestCase(name: "allow once covers the answered category without granting it for the rest of the task") {
        var grants: Set<SafetyRiskCategory> = [.sendingOrPublishing]
        let abortSignal = TaskAbortSignal()
        try expectEqual(try await askOnce(.allowOnce, grants: &grants, abortSignal: abortSignal), .allowed(.deleting))
        try expectEqual(grants, [.sendingOrPublishing])
        try expectTrue(!abortSignal.isAborted)
    },
    CoreTestCase(name: "allow for the rest of the task grants exactly the answered category") {
        var grants: Set<SafetyRiskCategory> = []
        try expectEqual(try await askOnce(.allowForAllRemainingItems, riskCategory: .bringingAppForward, grants: &grants,
                                          abortSignal: TaskAbortSignal()), .allowed(.bringingAppForward))
        try expectEqual(grants, [.bringingAppForward])
    },
    CoreTestCase(name: "skip declines without stopping; stop aborts the task") {
        var grants: Set<SafetyRiskCategory> = []
        let declinedSignal = TaskAbortSignal()
        try expectEqual(try await askOnce(.skipItem, grants: &grants, abortSignal: declinedSignal), .declined)
        try expectTrue(!declinedSignal.isAborted)
        let stoppedSignal = TaskAbortSignal()
        try expectEqual(try await askOnce(.stopTask, grants: &grants, abortSignal: stoppedSignal), .stopped)
        try expectTrue(stoppedSignal.isAborted)
        try expectEqual(grants, [])
    },
])
