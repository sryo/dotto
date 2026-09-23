import Foundation

private func plannedOperation(_ operationNumber: Int, _ kind: FileOperationKind, from sourcePath: String?, to destinationPath: String?,
                              group groupIdentifier: String) -> PlannedFileOperation {
    PlannedFileOperation(operationIdentifier: "op-\(operationNumber)", kind: kind, sourcePath: sourcePath, destinationPath: destinationPath,
                         tags: nil, reason: "r", groupIdentifier: groupIdentifier)
}

let checklistDirectRouteModelsTestSuite = CoreTestSuite(name: "Checklist direct-route models", testCases: [
    CoreTestCase(name: "a file operations plan becomes one included item per group, in group order") {
        let fileOperationsPlan = FileOperationsPlan(
            scope: DirectRouteScope(roots: [DirectRouteScopeRoot(canonicalPath: "/Users/me/Shots", source: .attachedByUser)]),
            groups: [FileOperationGroup(groupIdentifier: "folders", title: "Create 1 folder"),
                     FileOperationGroup(groupIdentifier: "moves", title: "Move 2 screenshots")],
            operations: [
                plannedOperation(1, .createFolder, from: nil, to: "/Users/me/Shots/2026-09 Septiembre", group: "folders"),
                plannedOperation(2, .move, from: "/Users/me/Shots/IMG_2041.png", to: "/Users/me/Shots/2026-09 Septiembre/IMG_2041.png", group: "moves"),
                plannedOperation(3, .move, from: "/Users/me/Shots/IMG_2042.png", to: "/Users/me/Shots/2026-09 Septiembre/IMG_2042.png", group: "moves"),
            ],
            collisionAdjustments: [])
        let checklist = Checklist.fromDirectRoutePlan(.fileOperations(fileOperationsPlan), title: "Sort screenshots",
                                                      originalCommand: "sort these", targetApplication: fixtureTargetApplication,
                                                      taskIdentifier: "task-1", createdAt: Date(timeIntervalSince1970: 0))
        try expectEqual(checklist.items.map(\.itemIdentifier), ["item-1", "item-2"])
        try expectEqual(checklist.items.map(\.label), ["Create 1 folder", "Move 2 screenshots"])
        try expectEqual(checklist.items.map(\.actionSummary), ["e.g. “2026-09 Septiembre”", "e.g. IMG_2041.png → 2026-09 Septiembre/"])
        try expectEqual(checklist.items[1].parameters, [ChecklistItemParameter(name: "operation_count", value: "2")])
        try expectTrue(checklist.items.allSatisfy { $0.isIncludedByUser && !$0.isIrreversible })
        try expectEqual(checklist.directRoutePlan, .fileOperations(fileOperationsPlan))
    },
    CoreTestCase(name: "scripts and shortcuts are one item each") {
        let scriptPlan = ScriptPlan(targetBundleIdentifier: "com.apple.mail", targetApplicationName: "Mail", language: .appleScript,
                                    source: "tell application \"Mail\" to return \"ok\"", oneSentenceSummary: "Creates 4 mailboxes.",
                                    expectedEffects: [], modifiesData: true, timeoutSeconds: 30,
                                    inspection: ScriptSourceInspection(referencedApplicationSpecifiers: ["Mail"], deniedConstructs: [], riskMatch: nil))
        let scriptChecklist = Checklist.fromDirectRoutePlan(.script(scriptPlan), title: "Mailboxes", originalCommand: "c",
                                                            targetApplication: fixtureTargetApplication, taskIdentifier: "t", createdAt: Date())
        try expectEqual(scriptChecklist.items.map(\.label), ["Run script in Mail"])
        try expectEqual(scriptChecklist.items.map(\.actionSummary), ["Creates 4 mailboxes."])
        let shortcutPlan = ShortcutPlan(shortcutName: "Resize for web", input: .none, oneSentenceSummary: "Resizes.", timeoutSeconds: 60)
        let shortcutChecklist = Checklist.fromDirectRoutePlan(.shortcut(shortcutPlan), title: "Resize", originalCommand: "c",
                                                              targetApplication: fixtureTargetApplication, taskIdentifier: "t", createdAt: Date())
        try expectEqual(shortcutChecklist.items.map(\.label), ["Run shortcut “Resize for web”"])
    },
    CoreTestCase(name: "a checklist saved before direct routes still decodes, with no plan") {
        let olderChecklistJSON = #"{"taskIdentifier":"t","originalCommand":"c","title":"T","targetApplication":{"processIdentifier":1,"applicationName":"Finder","bundleIdentifier":"com.apple.finder"},"items":[],"createdAt":0}"#
        let decodedChecklist = try JSONDecoder().decode(Checklist.self, from: Data(olderChecklistJSON.utf8))
        try expectEqual(decodedChecklist.directRoutePlan, nil)
        let roundTrippedChecklist = try JSONDecoder().decode(Checklist.self, from: try JSONEncoder().encode(
            Checklist.fromDirectRoutePlan(.shortcut(ShortcutPlan(shortcutName: "S", input: .text("hi"), oneSentenceSummary: "s", timeoutSeconds: 5)),
                                          title: "T", originalCommand: "c", targetApplication: fixtureTargetApplication,
                                          taskIdentifier: "t", createdAt: Date(timeIntervalSince1970: 0))))
        try expectEqual(roundTrippedChecklist.directRoutePlan,
                        .shortcut(ShortcutPlan(shortcutName: "S", input: .text("hi"), oneSentenceSummary: "s", timeoutSeconds: 5)))
    },
])
