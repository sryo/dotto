import Foundation

/// A 32-byte key (0, 1, 2, …, 31), so signatures in tests are stable.
final class FixedRoutineSigningKeyProvider: RoutineSigningKeyProviding {
    let signingKey: Data
    init(signingKey: Data = Data((0..<32).map { UInt8($0) })) { self.signingKey = signingKey }
    func routineSigningKey() throws -> Data { signingKey }
}

/// A one-step rename routine for Finder; confirmation per item makes its step press Return.
func makeFixtureRoutine(stepsRequireConfirmation: Bool = false, identifier: String = "routine-x",
                        updatedAt: Date = Date(timeIntervalSince1970: 0)) -> Routine {
    Routine(formatVersion: Routine.currentFormatVersion, routineIdentifier: identifier, name: "Rename screenshots",
            originalCommand: "rename them", targetApplicationName: "Finder", targetApplicationBundleIdentifier: "com.apple.finder",
            parameterNames: ["old_name", "new_name"], itemLabelTemplate: "Rename {{old_name}} to {{new_name}}",
            itemActionSummaryTemplate: "Rename {{old_name}}.",
            steps: [RoutineStep(stepDescription: "Type", action: .typeText(textTemplate: "{{new_name}}", replaceExistingText: true,
                                                                           pressReturnAfter: stepsRequireConfirmation),
                                targetLocator: nil, expectation: nil, requiresConfirmationEachItem: stepsRequireConfirmation)],
            completionEvidence: nil, source: .agentRun, modelCallsUsedWhenLearned: 6,
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: updatedAt, patchCount: 0)
}
