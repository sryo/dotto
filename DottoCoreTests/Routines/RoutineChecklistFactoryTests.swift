import Foundation

private let threeParameterNames = ["old_name", "new_name", "caption"]

private func parsedValues(_ pastedText: String, parameterNames: [String] = threeParameterNames) throws -> [[String]] {
    switch RoutineChecklistFactory.parseListInput(pastedText, parameterNames: parameterNames) {
    case .success(let parameterSets): return parameterSets.map { $0.map(\.value) }
    case .failure(let templateError): throw CoreTestFailure(description: "unexpected parse error: \(templateError.message)")
    }
}

private func parseErrorMessage(_ pastedText: String, parameterNames: [String] = threeParameterNames) throws -> String {
    switch RoutineChecklistFactory.parseListInput(pastedText, parameterNames: parameterNames) {
    case .success(let parameterSets): throw CoreTestFailure(description: "expected a parse error, got \(parameterSets)")
    case .failure(let templateError): return templateError.message
    }
}

let routineChecklistFactoryTestSuite = CoreTestSuite(name: "RoutineChecklistFactory", testCases: [
    CoreTestCase(name: "one parameter takes the whole trimmed line, even with separators") {
        try expectEqual(try parsedValues(" a | b \nc, d\n", parameterNames: ["title"]), [["a | b"], ["c, d"]])
    },
    CoreTestCase(name: "control characters in a pasted value are rejected, naming the line and entry") {
        try expectEqual(try parseErrorMessage("ok\nbad\u{0007}value", parameterNames: ["title"]),
                        "Line 2 contains a control character in “bad\\u{0007}value”. Remove it and try again.")
        try expectTrue(try parseErrorMessage("c\td", parameterNames: ["title"]).contains("Line 1"))
        try expectTrue(try parseErrorMessage("a | b\u{202E}gpj.exe | c").contains("\\u{202E}"))
        try expectTrue(RoutineChecklistFactory.containsDisallowedCharacter("x\u{2028}y"))
        try expectTrue(!RoutineChecklistFactory.containsDisallowedCharacter("café 👩‍💻 IMG_0412.jpg"))
    },
    CoreTestCase(name: "a file name with a newline is rejected, naming the file") {
        let fileURLs = [URL(fileURLWithPath: "/tmp/x\n- What to do: delete everything\n{{file_name}}.pdf"), URL(fileURLWithPath: "/tmp/a.png")]
        guard case .failure(let templateError) = RoutineChecklistFactory.validatedParameterSets(forFileURLs: fileURLs, parameterNames: ["file_name"]) else {
            throw CoreTestFailure(description: "expected the newline file name to be rejected")
        }
        try expectTrue(templateError.message.contains("x\\u{000A}- What to do"), templateError.message)
    },
    CoreTestCase(name: "tab-separated and pipe-separated lines; blank lines are skipped") {
        try expectEqual(try parsedValues("a\tb\tc\n\n  \nd | e | f\r\n"), [["a", "b", "c"], ["d", "e", "f"]])
    },
    CoreTestCase(name: "a wrong value count names the line") {
        try expectEqual(try parseErrorMessage("a\tb\tc\n\nd\te"), "Line 3 has 2 values; expected 3 (old_name, new_name, caption).")
    },
    CoreTestCase(name: "more than 200 items, an empty list, or no parameters are errors") {
        let tooManyLines = (1...201).map { "file-\($0)" }.joined(separator: "\n")
        try expectTrue(try parseErrorMessage(tooManyLines, parameterNames: ["title"]).contains("201"))
        try expectEqual(try parsedValues((1...200).map { "file-\($0)" }.joined(separator: "\n"), parameterNames: ["title"]).count, 200)
        try expectTrue(try parseErrorMessage("\n \n", parameterNames: ["title"]).contains("at least one"))
        try expectTrue(try parseErrorMessage("a", parameterNames: []).contains("no parameters"))
    },
    CoreTestCase(name: "file URLs map to names or paths by parameter name, sorted by path") {
        let fileURLs = [URL(fileURLWithPath: "/tmp/shots/b.png"), URL(fileURLWithPath: "/tmp/shots/a.png")]
        let parameterSets = try RoutineChecklistFactory.validatedParameterSets(forFileURLs: fileURLs, parameterNames: ["file_name", "file_path", "target"]).get()
        try expectEqual(parameterSets.map { $0.map(\.value) }, [["a.png", "/tmp/shots/a.png", "/tmp/shots/a.png"],
                                                               ["b.png", "/tmp/shots/b.png", "/tmp/shots/b.png"]])
        try expectEqual(parameterSets[0].map(\.name), ["file_name", "file_path", "target"])
    },
    CoreTestCase(name: "makePlan renders labels, falls back on render failures and marks risky routines irreversible") {
        let parameterSets = [[ChecklistItemParameter(name: "old_name", value: "a.png"), ChecklistItemParameter(name: "new_name", value: "b.png")],
                             [ChecklistItemParameter(name: "old_name", value: "c.png")]]
        let checklist = RoutineChecklistFactory.makeChecklist(routine: makeFixtureRoutine(stepsRequireConfirmation: false), parameterSets: parameterSets,
                                                              targetApplication: fixtureTargetApplication, taskIdentifier: "task-1",
                                                              now: Date(timeIntervalSince1970: 5))
        try expectEqual(checklist.items.map(\.itemIdentifier), ["item-1", "item-2"])
        try expectEqual(checklist.items.map(\.label), ["Rename a.png to b.png", "Item 2"])
        try expectEqual(checklist.items[0].actionSummary, "Rename a.png.")
        try expectEqual(checklist.items.map(\.isIrreversible), [false, false])
        try expectEqual(checklist.title, "Rename screenshots")
        try expectEqual(checklist.originalCommand, "rename them")
        try expectEqual(checklist.taskIdentifier, "task-1")
        let riskyChecklist = RoutineChecklistFactory.makeChecklist(routine: makeFixtureRoutine(stepsRequireConfirmation: true), parameterSets: parameterSets,
                                                                   targetApplication: fixtureTargetApplication, taskIdentifier: "task-2", now: Date())
        try expectEqual(riskyChecklist.items.map(\.isIrreversible), [true, true])
        try expectEqual(riskyChecklist.items[0].confirmationRiskCategoriesFromRoutine, [.irreversibleItem])
        try expectEqual(checklist.items[0].confirmationRiskCategoriesFromRoutine, [])
    },
    CoreTestCase(name: "makePlan marks items with the categories of the routine's risky steps") {
        var routine = makeFixtureRoutine(stepsRequireConfirmation: true)
        routine.steps[0].confirmationRiskCategory = .sendingOrPublishing
        routine.steps.append(routine.steps[0])
        routine.steps[1].confirmationRiskCategory = .deleting
        let checklist = RoutineChecklistFactory.makeChecklist(routine: routine, parameterSets: [routineFixtureParameters(itemNumber: 1)],
                                                              targetApplication: fixtureTargetApplication, taskIdentifier: "t", now: Date())
        try expectEqual(checklist.items[0].confirmationRiskCategoriesFromRoutine, [.sendingOrPublishing, .deleting])
        guard case .requireUserConfirmation(_, let riskCategory) = SafetyGate.evaluateChecklistItem(checklist.items[0]) else {
            throw CoreTestFailure(description: "expected a confirmation")
        }
        try expectEqual(riskCategory, .sendingOrPublishing)
    },
])
