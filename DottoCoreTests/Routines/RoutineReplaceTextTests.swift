import Foundation

private let compileDate = Date(timeIntervalSince1970: 1_790_000_500)

private let notesSnapshot = makeFixtureSnapshot([makeFixtureNode("w", "AXWindow", title: "Notes", children: [
    makeFixtureNode("f", "AXTextArea", value: "Photo IMG_0412.jpg goes here"),
])])

private func compileReplaceTextStep(findText: String, replacementText: String) throws -> Routine? {
    let recordedStep = RecordedAgentStep(
        toolCall: .action(.replaceText(elementIdentifier: "f", findText: findText, replacementText: replacementText, occurrence: .all,
                                       insertionPosition: .atFind)),
        targetContext: try unwrapOrFail(notesSnapshot.recordedElementContext(forNodeWithIdentifier: "f")),
        expectation: nil, wasConfirmedByUser: false)
    return RoutineCompiler.compileFromAgentRun(recordedSteps: [recordedStep], completionEvidence: nil,
                                               checklist: makeRoutineFixtureChecklist(), item: makeRoutineFixtureItem(itemNumber: 1),
                                               modelCallsUsed: 3, routineIdentifier: "routine-20260923-101010-ab12cd", now: compileDate)
}

let routineReplaceTextTestSuite = CoreTestSuite(name: "Routine replace_text", testCases: [
    CoreTestCase(name: "a replace_text step compiles with its find and replacement templatized") {
        let routine = try unwrapOrFail(try compileReplaceTextStep(findText: "IMG_0412.jpg", replacementText: "beach-01.jpg"))
        try expectEqual(routine.steps.count, 1)
        try expectEqual(routine.steps[0].action, .replaceText(findTemplate: "{{old_name}}", replacementTemplate: "{{new_name}}",
                                                              occurrence: .all, insertionPosition: .atFind))
        try expectEqual(routine.steps[0].targetLocator?.role, "AXTextArea")
        try expectEqual(routine.steps[0].requiresConfirmationEachItem, false)
        try expectTrue(!BackgroundActionPolicy.requiresForeground(routine.steps[0]))
    },
    CoreTestCase(name: "a replace_text step without a recorded field can't be compiled") {
        let untargetedStep = RecordedAgentStep(
            toolCall: .action(.replaceText(elementIdentifier: "gone", findText: "IMG_0412.jpg", replacementText: "beach-01.jpg",
                                           occurrence: .first, insertionPosition: .atFind)),
            targetContext: nil, expectation: nil, wasConfirmedByUser: false)
        try expectEqual(RoutineCompiler.compileFromAgentRun(recordedSteps: [untargetedStep], completionEvidence: nil,
                                                            checklist: makeRoutineFixtureChecklist(), item: makeRoutineFixtureItem(itemNumber: 1),
                                                            modelCallsUsed: 3, routineIdentifier: "routine-20260923-101010-ab12cd",
                                                            now: compileDate), nil)
    },
    CoreTestCase(name: "secret-looking text in a replace_text step is flagged, in find or replacement") {
        let secretLookingToken = "sk9Qw3ErTy7UiOp2AsDf5GhJ"
        try expectTrue(RoutineLiteralInspector.typedLiteralLooksLikeSecret(
            in: .replaceText(findTemplate: "{{old_name}}", replacementTemplate: secretLookingToken, occurrence: .first, insertionPosition: .atFind)))
        try expectTrue(RoutineLiteralInspector.typedLiteralLooksLikeSecret(
            in: .replaceText(findTemplate: secretLookingToken, replacementTemplate: "{{new_name}}", occurrence: .first, insertionPosition: .atFind)))
        try expectTrue(!RoutineLiteralInspector.typedLiteralLooksLikeSecret(
            in: .replaceText(findTemplate: "{{old_name}}", replacementTemplate: "{{new_name}}", occurrence: .first, insertionPosition: .atFind)))
    },
])
