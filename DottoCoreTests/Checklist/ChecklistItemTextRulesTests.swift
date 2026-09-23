import Foundation
import CoreGraphics

// The planner's second turn in task 20260923-033546-09af79 wrote 23 items in 3,937 output tokens (113 s) with
// step-by-step action summaries. These pin down the item rules that keep a checklist short to write.

private let stepByStepSummary = "In the pruebita folder select “Captura 2026-09-17 11.41.22 p.m.png”, press ⌘I to open Get Info, "
    + "read the dimensions under More Info, then click the Name & Extension field and type the new name. Press Return and close the window with ⌘W."

private func submitPlanInput(label: String, actionSummary: String) -> String {
    let itemObject = JSONValue.object(["label": .string(label), "action_summary": .string(actionSummary),
                                       "parameters": .array([]), "is_irreversible": .bool(false)])
    let inputObject = JSONValue.object(["task_title": .string("Add dimensions"), "message_to_user": .null, "items": .array([itemObject])])
    return String(decoding: try! JSONEncoder().encode(inputObject), as: UTF8.self)
}

let checklistItemTextRulesTestSuite = CoreTestSuite(name: "ChecklistItemTextRules", testCases: [
    CoreTestCase(name: "labels with menu paths, shortcuts or clicks are rejected") {
        try expectEqual(ChecklistItemTextRules.labelViolation("Choose File > Get Info for “a.png”"), .menuPath)
        try expectEqual(ChecklistItemTextRules.labelViolation("Archivo › Obtener información"), .menuPath)
        try expectEqual(ChecklistItemTextRules.labelViolation("Press ⌘I on “a.png”"), .keystroke)
        try expectEqual(ChecklistItemTextRules.labelViolation("Open Get Info with Cmd+I"), .keystroke)
        try expectEqual(ChecklistItemTextRules.labelViolation("Double-click “a.png” and rename it"), .clickInstruction)
    },
    CoreTestCase(name: "good labels pass, including quoted names that look like instructions and arrows") {
        try expectEqual(ChecklistItemTextRules.labelViolation("Add dimensions to “Captura 2026-09-17 11.41.22 p.m.”"), nil)
        try expectEqual(ChecklistItemTextRules.labelViolation("Rename “Save > Export ⌘.txt” to “export.txt”"), nil)
        try expectEqual(ChecklistItemTextRules.labelViolation("Rename “a.png” → “635x1331 a.png”"), nil)
    },
    CoreTestCase(name: "a label far over 60 characters is rejected; a little over is shortened at a word") {
        let farTooLongLabel = String(repeating: "Rename the screenshot ", count: 6)
        try expectEqual(ChecklistItemTextRules.labelViolation(farTooLongLabel),
                        .tooLong(characterCount: farTooLongLabel.trimmingCharacters(in: .whitespaces).count))
        let slightlyLongLabel = "Add image dimensions to the name of “Captura 2026-09-17 11.41.22”"
        try expectEqual(ChecklistItemTextRules.labelViolation(slightlyLongLabel), nil)
        let normalizedLabel = ChecklistItemTextRules.normalizedLabel(slightlyLongLabel)
        try expectTrue(normalizedLabel.count <= ChecklistItemTextRules.maximumLabelLength, normalizedLabel)
        try expectTrue(normalizedLabel.hasSuffix("…"), normalizedLabel)
    },
    CoreTestCase(name: "an action summary keeps its first sentence only, file-name dots included, at most 140 characters") {
        let normalizedSummary = ChecklistItemTextRules.normalizedActionSummary(
            "Put the width x height in front of “IMG_0412.jpg”. Then press Return and close Get Info.")
        try expectEqual(normalizedSummary, "Put the width x height in front of “IMG_0412.jpg”.")
        let shortenedSummary = ChecklistItemTextRules.normalizedActionSummary(stepByStepSummary)
        try expectTrue(shortenedSummary.count <= ChecklistItemTextRules.maximumActionSummaryLength, shortenedSummary)
        try expectEqual(ChecklistItemTextRules.normalizedActionSummary("Rename  it\nnow."), "Rename it now.")
    },
    CoreTestCase(name: "the risk check reads the whole summary before it is shortened") {
        let submittedChecklist = SubmittedChecklistDraft(taskTitle: "Tidy", messageToUser: nil, items: [
            SubmittedChecklistDraftItem(label: "Tidy “a.png”", actionSummary: "Rename “a.png” to “b.png”. Then delete the original copy.",
                                        parameters: [], isIrreversible: false)])
        let checklist = Checklist.fromPlannerSubmission(submittedChecklist, originalCommand: "tidy", targetApplication: fixtureTargetApplication,
                                                        taskIdentifier: "t", createdAt: Date(timeIntervalSince1970: 0))
        try expectEqual(checklist.items[0].actionSummary, "Rename “a.png” to “b.png”.")
        try expectTrue(checklist.items[0].isIrreversible, "the dropped sentence still counted")
    },
    CoreTestCase(name: "submit_plan with an instruction label goes back to the planner; the fixed plan is accepted") {
        let transport = ScriptedClaudeTransport(replies: [
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse(
                "toolu_bad", "submit_plan", submitPlanInput(label: "Press ⌘I on “a.png” and rename it", actionSummary: stepByStepSummary))),
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse(
                "toolu_good", "submit_plan", submitPlanInput(label: "Add dimensions to “a.png”", actionSummary: stepByStepSummary))),
        ])
        let checklistPlanner = ChecklistPlanner(transport: transport,
                                                actionBackend: FakeActionBackend(snapshotRootNodes: ConversationFixtures.windowRootNodes()),
                                                auditLogWriter: try ConversationFixtures.makeAuditLogWriter(),
                                                taskResourceBudget: TaskResourceBudget(safetyLimits: .standard))
        let planningResult = try await checklistPlanner.produceChecklist(
            command: "rename these by file dimensions", targetApplication: fixtureTargetApplication, taskIdentifier: "t",
            abortSignal: TaskAbortSignal(), onProgress: { _ in })
        guard case .checklist(let checklist) = planningResult else { throw CoreTestFailure(description: "expected a plan, got \(planningResult)") }
        try expectEqual(checklist.items.map(\.label), ["Add dimensions to “a.png”"])
        try expectTrue(checklist.items[0].actionSummary.count <= ChecklistItemTextRules.maximumActionSummaryLength)
        let rejection = ConversationFixtures.toolResults(inLastMessageOf: transport.recordedRequests[1])
        try expectEqual(rejection.map(\.isError), [true])
    },
])

let submittedChecklistItemStreamCounterTestSuite = CoreTestSuite(name: "SubmittedChecklistItemStreamCounter", testCases: [
    CoreTestCase(name: "counts each item's label key, also when a fragment boundary splits it") {
        var itemCounter = SubmittedChecklistItemStreamCounter()
        try expectEqual(itemCounter.consume(partialJSON: #"{"task_title":"Add","items":[{"lab"#), false)
        try expectEqual(itemCounter.consume(partialJSON: #"el":"Add dimensions to “a”","action_summary":"x"},{"label""#), true)
        try expectEqual(itemCounter.itemsWrittenSoFar, 2)
        try expectEqual(itemCounter.consume(partialJSON: #":"b","#), false)
        try expectEqual(itemCounter.itemsWrittenSoFar, 2)
    },
    CoreTestCase(name: "an escaped \"label\" inside a string value is not an item") {
        var itemCounter = SubmittedChecklistItemStreamCounter()
        _ = itemCounter.consume(partialJSON: #"{"items":[{"action_summary":"Set the \"label\" field","#)
        try expectEqual(itemCounter.itemsWrittenSoFar, 0)
    },
    CoreTestCase(name: "the pill says how many items are written while the plan streams in") {
        let writingState = CursorPresentationStateMapper.nextState(
            from: CursorPresentationStateMapper.nextState(from: .hidden, on: .planningStarted(targetApplicationName: "Finder")),
            on: .planningProgressed(.writingChecklist(itemsWrittenSoFar: 12)))
        try expectEqual(writingState.activity, .thinking)
        try expectEqual(writingState.statusText, "Planning… (12 items written)")
        try expectEqual(ChecklistPlanningProgress.writingChecklist(itemsWrittenSoFar: 1).statusLineText, "Planning… (1 item written)")
    },
])
