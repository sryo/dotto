import Foundation

private func typingStep(_ textTemplate: String) -> RoutineStep {
    RoutineStep(stepDescription: "Type", action: .typeText(textTemplate: textTemplate, replaceExistingText: true, pressReturnAfter: false),
                targetLocator: nil, expectation: nil, requiresConfirmationEachItem: false)
}

private func routine(typing textTemplates: [String]) -> Routine {
    Routine(formatVersion: Routine.currentFormatVersion, routineIdentifier: "routine-test", name: "Test", originalCommand: "",
            targetApplicationName: "Finder", targetApplicationBundleIdentifier: "com.apple.finder", parameterNames: ["name"],
            itemLabelTemplate: "{{name}}", itemActionSummaryTemplate: "", steps: textTemplates.map(typingStep),
            completionEvidence: nil, source: .userDemonstration, modelCallsUsedWhenLearned: nil,
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0), patchCount: 0)
}

let routineLiteralInspectorTestSuite = CoreTestSuite(name: "RoutineLiteralInspector", testCases: [
    CoreTestCase(name: "a six-digit one-time code is flagged") {
        try expectTrue(RoutineLiteralInspector.literalLooksLikeSecret("Code 482913"))
        try expectTrue(!RoutineLiteralInspector.literalLooksLikeSecret("Code 48291"))
        try expectTrue(!RoutineLiteralInspector.literalLooksLikeSecret("Code 4829131"))
    },
    CoreTestCase(name: "random-looking tokens with three character classes are flagged") {
        try expectTrue(RoutineLiteralInspector.literalLooksLikeSecret("sk_live_9fKq2XwP7zLm4RtY8vBn"))
        try expectTrue(RoutineLiteralInspector.literalLooksLikeSecret("Password: Tr0ub4dor&3xK9#mPq2zW!"))
    },
    CoreTestCase(name: "hex keys are flagged only once they are key-length") {
        try expectTrue(RoutineLiteralInspector.literalLooksLikeSecret("3f9a1c7e5b2d8046af19c3e7b5d20a84"))
        try expectTrue(!RoutineLiteralInspector.literalLooksLikeSecret("3f9a1c7e5b2d8046af19"))
    },
    CoreTestCase(name: "URLs, paths, file names and ordinary words are not flagged") {
        try expectTrue(!RoutineLiteralInspector.literalLooksLikeSecret("https://example.com/a8Kf3/q?id=9XkP2mZ7"))
        try expectTrue(!RoutineLiteralInspector.literalLooksLikeSecret("/Users/ana/Documents/Report2024Q3Final7.pdf"))
        try expectTrue(!RoutineLiteralInspector.literalLooksLikeSecret("~/Desktop/Screenshot2024x09x22at10x41x07"))
        try expectTrue(!RoutineLiteralInspector.literalLooksLikeSecret("Quarterly_Report_2024_Final_v7.docx"))
        try expectTrue(!RoutineLiteralInspector.literalLooksLikeSecret("Thanks for your order, see you soon"))
    },
    CoreTestCase(name: "text inside parameter slots is never inspected") {
        try expectTrue(!RoutineLiteralInspector.literalLooksLikeSecret("{{sk_live_9fKq2XwP7zLm4RtY8vBn}}"))
        try expectTrue(!RoutineLiteralInspector.literalLooksLikeSecret("Code {{code}}"))
    },
    CoreTestCase(name: "only typed text counts as a step's literal") {
        try expectTrue(RoutineLiteralInspector.typedLiteralLooksLikeSecret(in: .typeText(textTemplate: "482913", replaceExistingText: false,
                                                                                         pressReturnAfter: true)))
        try expectTrue(!RoutineLiteralInspector.typedLiteralLooksLikeSecret(in: .waitForText(textTemplate: "482913", timeoutSeconds: 5)))
    },
    CoreTestCase(name: "a routine is flagged when any of its steps types a secret-looking literal") {
        try expectTrue(RoutineLiteralInspector.routineHasSecretLookingLiteral(routine(typing: ["{{name}}", "482913"])))
        try expectTrue(!RoutineLiteralInspector.routineHasSecretLookingLiteral(routine(typing: ["{{name}}", "Hello"])))
    },
])
