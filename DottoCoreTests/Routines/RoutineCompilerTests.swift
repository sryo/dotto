import Foundation
import CoreGraphics

private let compileDate = Date(timeIntervalSince1970: 1_790_000_500)

private func recordedContext(_ elementIdentifier: String, in snapshot: AccessibilityTreeSnapshot = routineFixtureFinderSnapshot) throws -> RecordedElementContext {
    try unwrapOrFail(snapshot.recordedElementContext(forNodeWithIdentifier: elementIdentifier))
}

private func agentStep(_ toolCall: AgentToolCall, target elementIdentifier: String? = nil, expectation: StepExpectation? = nil,
                       wasConfirmedByUser: Bool = false, confirmedRiskCategory: SafetyRiskCategory? = nil) throws -> RecordedAgentStep {
    RecordedAgentStep(toolCall: toolCall, targetContext: try elementIdentifier.map { try recordedContext($0) }, expectation: expectation,
                      wasConfirmedByUser: wasConfirmedByUser, confirmedRiskCategory: confirmedRiskCategory)
}

/// Item 1 of the fixture: double-click the name field, scroll, type the new name with Return, wait, then share.
private func item1AgentTrace() throws -> [RecordedAgentStep] {
    [
        try agentStep(.action(.clickElement(elementIdentifier: "e11", clickType: .double)), target: "e11"),
        try agentStep(.action(.scroll(elementIdentifier: nil, direction: .down, pages: 1))),
        try agentStep(.action(.typeText(elementIdentifier: "e11", text: "beach-01.jpg", replaceExistingText: true, pressReturnAfter: true)),
                      target: "e11", expectation: StepExpectation(kind: .fieldValueEquals, text: "beach-01.jpg")),
        try agentStep(.waitFor(text: "beach-01.jpg", timeoutSeconds: 3)),
        try agentStep(.action(.clickElement(elementIdentifier: "e3", clickType: .single)), target: "e3", wasConfirmedByUser: true,
                      confirmedRiskCategory: .sendingOrPublishing),
    ]
}

private func compileItem1(_ recordedSteps: [RecordedAgentStep], item: ChecklistItem = makeRoutineFixtureItem(itemNumber: 1)) -> Routine? {
    RoutineCompiler.compileFromAgentRun(recordedSteps: recordedSteps, completionEvidence: StepExpectation(kind: .textAppears, text: "beach-01.jpg"),
                                        checklist: makeRoutineFixtureChecklist(), item: item, modelCallsUsed: 7,
                                        routineIdentifier: "routine-20260922-153012-ab12cd", now: compileDate)
}

private let demonstrationRecording: () throws -> DemonstrationRecording = {
    DemonstrationRecording(application: fixtureTargetApplication, events: [
        .click(target: try recordedContext("e11"), clickType: .single),
        .textEntered(target: try recordedContext("e11"), finalValue: "beach-01.jpg"),
        .keyChord(keyName: "return", modifiers: []),
        .click(target: try recordedContext("e3"), clickType: .single),
    ], finalWindowTitle: "Screenshots", finalWindowDocument: nil)
}

private func draftStep(_ eventIndex: Int, textTemplate: String? = nil, targetTextTemplate: String? = nil) -> SubmittedRoutineDraftStep {
    SubmittedRoutineDraftStep(eventIndex: eventIndex, textTemplate: textTemplate, targetTextTemplate: targetTextTemplate,
                              expectation: nil, stepDescription: "")
}

private func compileDemonstration(_ draftSteps: [SubmittedRoutineDraftStep], itemLabelTemplate: String = "Rename {{old_name}}",
                                  recording: DemonstrationRecording? = nil, item: ChecklistItem = makeRoutineFixtureItem(itemNumber: 1),
                                  completionEvidenceText: String = "{{new_name}}") throws -> Result<Routine, RoutineTemplateError> {
    let draft = SubmittedRoutineDraft(routineName: "Rename screenshots", itemLabelTemplate: itemLabelTemplate, steps: draftSteps,
                                      completionEvidence: StepExpectation(kind: .textAppears, text: completionEvidenceText))
    return RoutineCompiler.compileFromDemonstration(recording: try recording ?? demonstrationRecording(), draft: draft,
                                                    checklist: makeRoutineFixtureChecklist(), item: item,
                                                    routineIdentifier: "routine-demo", now: compileDate)
}

private func expectCompileError(_ compileResult: Result<Routine, RoutineTemplateError>, mentioning expectedFragment: String,
                                file: StaticString = #fileID, line: UInt = #line) throws {
    guard case .failure(let templateError) = compileResult else {
        throw CoreTestFailure(description: "\(file):\(line) expected a compile error mentioning \(expectedFragment)")
    }
    try expectTrue(templateError.message.contains(expectedFragment), templateError.message, file: file, line: line)
}

let routineCompilerTestSuite = CoreTestSuite(name: "RoutineCompiler", testCases: [
    CoreTestCase(name: "an agent trace compiles: scroll dropped, text templatized, wait kept, steps that ask flagged") {
        let routine = try unwrapOrFail(compileItem1(try item1AgentTrace()))
        try expectEqual(routine.steps.map(\.action), [
            .click(clickType: .double),
            .typeText(textTemplate: "{{new_name}}", replaceExistingText: true, pressReturnAfter: true),
            .waitForText(textTemplate: "{{new_name}}", timeoutSeconds: 3),
            .click(clickType: .single),
        ])
        try expectEqual(routine.steps[0].targetLocator?.valueTemplate, "{{old_name}}")
        try expectEqual(routine.steps[0].requiresConfirmationEachItem, false)
        try expectEqual(routine.steps[1].expectation, StepExpectation(kind: .fieldValueEquals, text: "{{new_name}}"))
        // Return in this app doesn't ask, so the step isn't flagged; the live gate still judges it at replay.
        try expectEqual(routine.steps[1].requiresConfirmationEachItem, false)
        try expectEqual(routine.steps[1].confirmationRiskCategory, nil)
        try expectEqual(routine.steps[3].requiresConfirmationEachItem, true)
        try expectEqual(routine.steps[3].confirmationRiskCategory, .sendingOrPublishing)
        try expectEqual(routine.steps[0].stepDescription, "Click textfield “{{old_name}}”")
        try expectEqual(routine.completionEvidence, StepExpectation(kind: .textAppears, text: "{{new_name}}"))
        try expectEqual(routine.itemLabelTemplate, "Rename “{{old_name}}” to “{{new_name}}”")
        try expectEqual(routine.parameterNames, ["old_name", "new_name"])
        try expectEqual(routine.source, .agentRun)
        try expectEqual(routine.modelCallsUsedWhenLearned, 7)
        try expectEqual(routine.patchCount, 0)
    },
    CoreTestCase(name: "a user-confirmed step keeps its confirmation and category") {
        let confirmedTabStep = try agentStep(.action(.pressKey(keyName: "tab", modifiers: [])), wasConfirmedByUser: true,
                                             confirmedRiskCategory: .submittingOrApproving)
        let routine = try unwrapOrFail(compileItem1(Array(try item1AgentTrace().prefix(3)) + [confirmedTabStep]))
        try expectEqual(routine.steps.last?.requiresConfirmationEachItem, true)
        try expectEqual(routine.steps.last?.confirmationRiskCategory, .submittingOrApproving)
    },
    CoreTestCase(name: "a button titled by its child text is not flagged as unlabeled") {
        let snapshot = makeFixtureSnapshot([makeFixtureNode("w", "AXWindow", children: [
            makeFixtureNode("b", "AXButton", children: [makeFixtureNode("t", "AXStaticText", value: "Rename")]),
            makeFixtureNode("f", "AXTextField", value: "IMG_0412.jpg"),
        ])])
        let recordedSteps = [
            RecordedAgentStep(toolCall: .action(.clickElement(elementIdentifier: "b", clickType: .single)),
                              targetContext: snapshot.recordedElementContext(forNodeWithIdentifier: "b"), expectation: nil, wasConfirmedByUser: false),
            RecordedAgentStep(toolCall: .action(.typeText(elementIdentifier: "f", text: "beach-01.jpg", replaceExistingText: true, pressReturnAfter: false)),
                              targetContext: snapshot.recordedElementContext(forNodeWithIdentifier: "f"), expectation: nil, wasConfirmedByUser: false),
        ]
        let routine = try unwrapOrFail(compileItem1(recordedSteps))
        try expectEqual(routine.steps.map(\.requiresConfirmationEachItem), [false, false])
    },
    CoreTestCase(name: "click_point, a missing click target, a secure target or no parameters give nil") {
        let clickPointStep = try agentStep(.action(.clickScreenshotPoint(screenshotPixelPoint: CGPoint(x: 5, y: 5), clickType: .single)))
        try expectEqual(compileItem1(try item1AgentTrace() + [clickPointStep]), nil)
        try expectEqual(compileItem1([try agentStep(.action(.clickElement(elementIdentifier: "e11", clickType: .single)))]), nil)

        let secureSnapshot = makeFixtureSnapshot([makeFixtureNode("w", "AXWindow", children: [
            makeFixtureNode("p", "AXTextField", subrole: "AXSecureTextField", isSecure: true),
        ])])
        let secureStep = RecordedAgentStep(toolCall: .action(.typeText(elementIdentifier: "p", text: "beach-01.jpg", replaceExistingText: true,
                                                                       pressReturnAfter: false)),
                                           targetContext: secureSnapshot.recordedElementContext(forNodeWithIdentifier: "p"),
                                           expectation: nil, wasConfirmedByUser: false)
        try expectEqual(compileItem1([secureStep]), nil)

        var itemWithoutParameters = makeRoutineFixtureItem(itemNumber: 1)
        itemWithoutParameters.parameters = []
        try expectEqual(compileItem1(try item1AgentTrace(), item: itemWithoutParameters), nil)
    },
    CoreTestCase(name: "a trace whose actions never use a parameter gives nil (ADR-18)") {
        let shareOnly = [try agentStep(.action(.clickElement(elementIdentifier: "e3", clickType: .single)), target: "e3",
                                       expectation: StepExpectation(kind: .textAppears, text: "beach-01.jpg"))]
        try expectEqual(compileItem1(shareOnly), nil)
    },
    CoreTestCase(name: "a demonstration draft compiles from the selected events") {
        let compileResult = try compileDemonstration([draftStep(0), draftStep(1, textTemplate: "{{new_name}}"), draftStep(2)])
        guard case .success(let routine) = compileResult else { throw CoreTestFailure(description: "\(compileResult)") }
        try expectEqual(routine.steps.map(\.action), [
            .click(clickType: .single),
            .typeText(textTemplate: "{{new_name}}", replaceExistingText: true, pressReturnAfter: false),
            .pressKey(keyName: "return", modifiers: []),
        ])
        try expectEqual(routine.steps[0].targetLocator?.valueTemplate, "{{old_name}}")
        try expectEqual(routine.steps[1].targetLocator?.valueTemplate, "{{old_name}}")
        try expectEqual(routine.steps.map(\.requiresConfirmationEachItem), [false, false, false])
        try expectEqual(routine.source, .userDemonstration)
        try expectEqual(routine.modelCallsUsedWhenLearned, nil)
        try expectEqual(routine.name, "Rename screenshots")
        try expectEqual(routine.itemLabelTemplate, "Rename {{old_name}}")
    },
    CoreTestCase(name: "a typed event without a text template is templatized from its final value") {
        guard case .success(let routine) = try compileDemonstration([draftStep(1)]) else { throw CoreTestFailure(description: "compile failed") }
        try expectEqual(routine.steps[0].action, .typeText(textTemplate: "{{new_name}}", replaceExistingText: true, pressReturnAfter: false))
    },
    CoreTestCase(name: "bad drafts produce errors for the model") {
        try expectCompileError(try compileDemonstration([draftStep(7)]), mentioning: "out of range")
        try expectCompileError(try compileDemonstration([draftStep(0), draftStep(0)]), mentioning: "used twice")
        try expectCompileError(try compileDemonstration([draftStep(0)], itemLabelTemplate: "{{caption}}"), mentioning: "caption")
        try expectCompileError(try compileDemonstration([]), mentioning: "empty")
        try expectCompileError(try compileDemonstration([draftStep(3)]), mentioning: "varies per item")
        let secureSnapshot = makeFixtureSnapshot([makeFixtureNode("w", "AXWindow", children: [
            makeFixtureNode("p", "AXTextField", subrole: "AXSecureTextField", isSecure: true),
        ])])
        let secureRecording = DemonstrationRecording(application: fixtureTargetApplication, events: [
            .textEntered(target: try unwrapOrFail(secureSnapshot.recordedElementContext(forNodeWithIdentifier: "p")), finalValue: "beach-01.jpg"),
        ], finalWindowTitle: nil, finalWindowDocument: nil)
        try expectCompileError(try compileDemonstration([draftStep(0)], recording: secureRecording), mentioning: "password")
    },
    CoreTestCase(name: "target_text_template overrides a title only when it reproduces the recorded text") {
        let reportSnapshot = makeFixtureSnapshot([makeFixtureNode("w", "AXWindow", children: [
            makeFixtureNode("b", "AXButton", title: "REPORT"),
        ])])
        let reportRecording = DemonstrationRecording(application: fixtureTargetApplication, events: [
            .click(target: try unwrapOrFail(reportSnapshot.recordedElementContext(forNodeWithIdentifier: "b")), clickType: .single),
        ], finalWindowTitle: nil, finalWindowDocument: nil)
        var reportItem = makeRoutineFixtureItem(itemNumber: 1)
        reportItem.parameters = [ChecklistItemParameter(name: "section", value: "report")]
        let acceptedResult = try compileDemonstration([draftStep(0, targetTextTemplate: "{{section}}")], itemLabelTemplate: "Open {{section}}",
                                                      recording: reportRecording, item: reportItem, completionEvidenceText: "{{section}}")
        guard case .success(let routine) = acceptedResult else { throw CoreTestFailure(description: "\(acceptedResult)") }
        try expectEqual(routine.steps[0].targetLocator?.titleTemplate, "{{section}}")
        try expectCompileError(try compileDemonstration([draftStep(0, targetTextTemplate: "Delete {{section}}")], itemLabelTemplate: "Open {{section}}",
                                                        recording: reportRecording, item: reportItem, completionEvidenceText: "{{section}}"),
                               mentioning: "must reproduce")
    },
    CoreTestCase(name: "patch replaces the tail from the failed step and counts the patch") {
        let routine = try unwrapOrFail(compileItem1(try item1AgentTrace()))
        let item2 = makeRoutineFixtureItem(itemNumber: 2)
        let agentTail = [try agentStep(.action(.typeText(elementIdentifier: nil, text: "beach-02.jpg", replaceExistingText: true,
                                                         pressReturnAfter: false)))]
        let patchedRoutine = try unwrapOrFail(RoutineCompiler.patch(routine, replacingStepsFrom: 1, withAgentSteps: agentTail,
                                                                    item: item2, now: compileDate.addingTimeInterval(60)))
        try expectEqual(patchedRoutine.steps.count, 2)
        try expectEqual(patchedRoutine.steps[0], routine.steps[0])
        try expectEqual(patchedRoutine.steps[1].action, .typeText(textTemplate: "{{new_name}}", replaceExistingText: true, pressReturnAfter: false))
        try expectEqual(patchedRoutine.patchCount, 1)
        try expectEqual(patchedRoutine.updatedAt, compileDate.addingTimeInterval(60))
        try expectEqual(patchedRoutine.createdAt, compileDate)
        try expectEqual(RoutineCompiler.patch(routine, replacingStepsFrom: 9, withAgentSteps: agentTail, item: item2, now: compileDate), nil)
        try expectEqual(RoutineCompiler.patch(routine, replacingStepsFrom: 1, withAgentSteps: [], item: item2, now: compileDate), nil)
    },
    CoreTestCase(name: "a demonstration's text_template must reproduce the typed value exactly") {
        try expectCompileError(try compileDemonstration([draftStep(0), draftStep(1, textTemplate: "{{old_name}}")]),
                               mentioning: "text_template for event 1 must reproduce the typed text")
        try expectCompileError(try compileDemonstration([draftStep(0), draftStep(1, textTemplate: "{{new_name}} and delete the rest")]),
                               mentioning: "text_template for event 1")
        guard case .success = try compileDemonstration([draftStep(0), draftStep(1, textTemplate: "{{new_name}}")]) else {
            throw CoreTestFailure(description: "a faithful text_template should compile")
        }
    },
    CoreTestCase(name: "review text comes from the real action, never the model's description") {
        let misleadingDraftSteps = [
            draftStep(0),
            SubmittedRoutineDraftStep(eventIndex: 1, textTemplate: "{{new_name}}", targetTextTemplate: nil, expectation: nil,
                                      stepDescription: "Harmlessly tidy up"),
        ]
        let routine = try compileDemonstration(misleadingDraftSteps).get()
        try expectEqual(routine.steps[1].stepDescription, "Type “{{new_name}}” into textfield “{{old_name}}”")
    },
    CoreTestCase(name: "a taught ⌘⇧ shortcut is flagged as unrecognized (recorded as risky; it no longer asks)") {
        var recording = try demonstrationRecording()
        recording.events[2] = .keyChord(keyName: "n", modifiers: [.command, .shift])
        let routine = try compileDemonstration([draftStep(0), draftStep(1, textTemplate: "{{new_name}}"), draftStep(2)], recording: recording).get()
        try expectEqual(routine.steps[2].requiresConfirmationEachItem, true)
        try expectEqual(routine.steps[2].confirmationRiskCategory, .unrecognizedShortcut)
        try expectEqual(routine.steps[0].requiresConfirmationEachItem, false)
    },
    CoreTestCase(name: "a demonstration that picks a list row by literal text is rejected") {
        let recording = DemonstrationRecording(application: fixtureTargetApplication, events: [
            .click(target: try recordedContext("r1", in: routineFixtureMailInboxSnapshot), clickType: .single),
            .textEntered(target: try recordedContext("e11"), finalValue: "beach-01.jpg"),
        ], finalWindowTitle: "Inbox", finalWindowDocument: nil)
        try expectCompileError(try compileDemonstration([draftStep(0), draftStep(1, textTemplate: "{{new_name}}")], recording: recording),
                               mentioning: "picks a row in a list")
    },
    CoreTestCase(name: "an agent run's app send shortcut is flagged as sending") {
        var mailChecklist = makeRoutineFixtureChecklist()
        mailChecklist.targetApplication = TargetApplicationReference(processIdentifier: 7, applicationName: "Mail", bundleIdentifier: "com.apple.mail")
        let recordedSteps = [
            try agentStep(.action(.typeText(elementIdentifier: "e11", text: "beach-01.jpg", replaceExistingText: true, pressReturnAfter: false)),
                          target: "e11"),
            try agentStep(.action(.pressKey(keyName: "d", modifiers: [.command, .shift]))),
        ]
        let routine = try unwrapOrFail(RoutineCompiler.compileFromAgentRun(
            recordedSteps: recordedSteps, completionEvidence: nil, checklist: mailChecklist, item: makeRoutineFixtureItem(itemNumber: 1),
            modelCallsUsed: 3, routineIdentifier: "routine-mail", now: compileDate))
        try expectEqual(routine.steps.map(\.confirmationRiskCategory), [nil, .sendingOrPublishing])
    },
    CoreTestCase(name: "an upload step templatizes the file path parameter and asks on every item") {
        let uploadAction = AgentAction.uploadFiles(elementIdentifier: "e3", filePaths: ["/Users/me/Pictures/beach-01.jpg"])
        let routine = try unwrapOrFail(compileItem1([try agentStep(.action(uploadAction), target: "e3")]))
        let uploadStep = try unwrapOrFail(routine.steps.first)
        try expectEqual(uploadStep.action, .uploadFiles(filePathTemplates: ["/Users/me/Pictures/{{new_name}}"]))
        try expectTrue(uploadStep.stepDescription.hasPrefix("Upload 1 file"), uploadStep.stepDescription)
        try expectEqual(uploadStep.requiresConfirmationEachItem, true)
        try expectEqual(uploadStep.confirmationRiskCategory, .uploadingFiles)
        try expectEqual(compileItem1([try agentStep(.action(uploadAction))]), nil, "an upload without a recorded target can't be replayed")
    },
])
