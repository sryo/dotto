import Foundation

let checklistModelsTestSuite = CoreTestSuite(name: "ChecklistModels", testCases: [
    CoreTestCase(name: "planner submission becomes a plan with app-assigned item ids") {
        let submittedChecklist = SubmittedChecklistDraft(taskTitle: "Rename", messageToUser: nil, items: [
            SubmittedChecklistDraftItem(label: "A", actionSummary: "Do A", parameters: [ChecklistItemParameter(name: "n", value: "1")], isIrreversible: false),
            SubmittedChecklistDraftItem(label: "B", actionSummary: "Do B", parameters: [], isIrreversible: true),
        ])
        let createdAt = Date(timeIntervalSince1970: 1_790_000_000)
        let checklist = Checklist.fromPlannerSubmission(submittedChecklist, originalCommand: "rename", targetApplication: fixtureTargetApplication,
                                                  taskIdentifier: "task-1", createdAt: createdAt)
        try expectEqual(checklist.items.map(\.itemIdentifier), ["item-1", "item-2"])
        try expectEqual(checklist.title, "Rename")
        try expectEqual(checklist.createdAt, createdAt)
        try expectEqual(checklist.items[1].isIrreversible, true)
        try expectEqual(checklist.items[0].runStatus, .pending)
        try expectTrue(checklist.items.allSatisfy { $0.isIncludedByUser && !$0.wasLabelEditedByUser && $0.resultSummary == nil })
        try expectEqual(checklist.items[0].id, "item-1")
    },
    CoreTestCase(name: "planner submission is truncated to 200 items") {
        let manyItems = (1...250).map { itemNumber in
            SubmittedChecklistDraftItem(label: "Item \(itemNumber)", actionSummary: "", parameters: [], isIrreversible: false)
        }
        let checklist = Checklist.fromPlannerSubmission(SubmittedChecklistDraft(taskTitle: "Many", messageToUser: "big", items: manyItems),
                                                  originalCommand: "c", targetApplication: fixtureTargetApplication,
                                                  taskIdentifier: "task-2", createdAt: Date())
        try expectEqual(checklist.items.count, Checklist.maximumItemCount)
        try expectEqual(checklist.items.last?.itemIdentifier, "item-200")
    },
    CoreTestCase(name: "includedItems and updatingItem") {
        let checklist = makeFixtureChecklist(itemCount: 3).updatingItem(withIdentifier: "item-2") { $0.isIncludedByUser = false }
        try expectEqual(checklist.includedItems.map(\.itemIdentifier), ["item-1", "item-3"])
        let unchangedChecklist = checklist.updatingItem(withIdentifier: "item-99") { $0.label = "nope" }
        try expectEqual(unchangedChecklist, checklist)
    },
    CoreTestCase(name: "run summary counts statuses across all items") {
        var checklist = makeFixtureChecklist(itemCount: 6)
        let statuses: [ChecklistItemRunStatus] = [.completed, .completed, .failed, .needsUser, .skipped, .pending]
        for (itemIndex, runStatus) in statuses.enumerated() { checklist.items[itemIndex].runStatus = runStatus }
        try expectEqual(TaskRunSummary.summarize(checklist: checklist, stopReason: .userAborted),
                        TaskRunSummary(completedItemCount: 2, failedItemCount: 1, needsUserItemCount: 1, skippedItemCount: 1, stopReason: .userAborted))
    },
    CoreTestCase(name: "task identifier is a sortable timestamp plus a filesystem-safe suffix") {
        let fixedDate = Date(timeIntervalSince1970: 1_790_000_000)
        let taskIdentifier = TaskIdentifierFactory.makeTaskIdentifier(now: fixedDate, randomSuffix: "AB12cd")
        let dateComponents = Calendar(identifier: .gregorian).dateComponents(in: TimeZone.current, from: fixedDate)
        let expectedPrefix = String(format: "%04d%02d%02d-%02d%02d%02d", dateComponents.year!, dateComponents.month!, dateComponents.day!,
                                    dateComponents.hour!, dateComponents.minute!, dateComponents.second!)
        try expectEqual(taskIdentifier, expectedPrefix + "-ab12cd")
        try expectEqual(TaskIdentifierFactory.makeTaskIdentifier(now: fixedDate, randomSuffix: "a/b c"), expectedPrefix + "-abc")
    },
    CoreTestCase(name: "plan survives a Codable round trip") {
        let checklist = makeFixtureChecklist(itemCount: 2)
        let decodedChecklist = try JSONDecoder().decode(Checklist.self, from: try JSONEncoder().encode(checklist))
        try expectEqual(decodedChecklist, checklist)
    },
])
