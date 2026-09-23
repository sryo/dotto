import Foundation

private let checkerSnapshot = makeFixtureSnapshot([
    makeFixtureNode("e1", "AXWindow", title: "Screenshots", children: [
        makeFixtureNode("e2", "AXTextField", value: " beach-01.jpg "),
        makeFixtureNode("e3", "AXTextField", subrole: "AXSecureTextField", value: "hunter22", isSecure: true),
        makeFixtureNode("e4", "AXStaticText", value: "Saved"),
    ]),
], windowTitle: "Screenshots — Local", document: "file:///Users/me/My%20Screenshots/")

private func verdict(_ kind: StepExpectationKind, _ text: String) -> StepExpectationVerdict {
    StepExpectationChecker.evaluate(StepExpectation(kind: kind, text: text), in: checkerSnapshot)
}

private func expectUnsatisfied(_ checkVerdict: StepExpectationVerdict, mentioning expectedFragment: String,
                               file: StaticString = #fileID, line: UInt = #line) throws {
    guard case .unsatisfied(let reasonForModel) = checkVerdict else {
        throw CoreTestFailure(description: "\(file):\(line) expected unsatisfied, got \(checkVerdict)")
    }
    try expectTrue(reasonForModel.contains(expectedFragment), reasonForModel, file: file, line: line)
}

let stepExpectationCheckerTestSuite = CoreTestSuite(name: "StepExpectationChecker", testCases: [
    CoreTestCase(name: "text appears and disappears, case-insensitive and trimmed") {
        try expectEqual(verdict(.textAppears, "  saved "), .satisfied)
        try expectUnsatisfied(verdict(.textAppears, "Renamed"), mentioning: "Expected “Renamed” to appear")
        try expectEqual(verdict(.textDisappears, "Renamed"), .satisfied)
        try expectUnsatisfied(verdict(.textDisappears, "SAVED"), mentioning: "still in the outline")
    },
    CoreTestCase(name: "field value equals is exact and never matches a secure field") {
        try expectEqual(verdict(.fieldValueEquals, "beach-01.jpg"), .satisfied)
        try expectUnsatisfied(verdict(.fieldValueEquals, "Beach-01.jpg"), mentioning: "no field does")
        try expectUnsatisfied(verdict(.fieldValueEquals, "hunter22"), mentioning: "hold exactly")
    },
    CoreTestCase(name: "window title contains") {
        try expectEqual(verdict(.windowTitleContains, "local"), .satisfied)
        try expectUnsatisfied(verdict(.windowTitleContains, "Downloads"), mentioning: "window title")
    },
    CoreTestCase(name: "document contains matches raw and percent-decoded forms") {
        try expectEqual(verdict(.documentContains, "My Screenshots"), .satisfied)
        try expectEqual(verdict(.documentContains, "my%20screenshots"), .satisfied)
        try expectUnsatisfied(verdict(.documentContains, "Desktop"), mentioning: "document")
        try expectUnsatisfied(StepExpectationChecker.evaluate(StepExpectation(kind: .documentContains, text: "x"),
                                                              in: makeFixtureSnapshot([])), mentioning: "“x”")
    },
    CoreTestCase(name: "kind none and empty text are satisfied; long texts are truncated in reasons") {
        try expectEqual(verdict(.none, "anything"), .satisfied)
        try expectEqual(verdict(.textAppears, "   "), .satisfied)
        try expectUnsatisfied(verdict(.textAppears, String(repeating: "z", count: 150)), mentioning: String(repeating: "z", count: 100) + "…”")
    },
    CoreTestCase(name: "renderingParameters fills placeholders and throws on unknown ones") {
        let parameters = routineFixtureParameters(itemNumber: 2)
        try expectEqual(try StepExpectation(kind: .textAppears, text: "{{new_name}}").renderingParameters(parameters),
                        StepExpectation(kind: .textAppears, text: "beach-02.jpg"))
        _ = try expectThrowsError { _ = try StepExpectation(kind: .textAppears, text: "{{caption}}").renderingParameters(parameters) }
    },
    CoreTestCase(name: "text_appears for text already on screen needs a change since the action") {
        let beforeSnapshot = checkerSnapshot
        try expectUnsatisfied(StepExpectationChecker.evaluate(StepExpectation(kind: .textAppears, text: "Saved"), in: checkerSnapshot,
                                                              preActionSnapshot: beforeSnapshot),
                              mentioning: "already in the focused window")
        var changedRootNodes = checkerSnapshot.rootNodes
        changedRootNodes[0].children.append(makeFixtureNode("e5", "AXStaticText", value: "Saved just now"))
        let afterSnapshot = makeFixtureSnapshot(changedRootNodes)
        try expectEqual(StepExpectationChecker.evaluate(StepExpectation(kind: .textAppears, text: "Saved"), in: afterSnapshot,
                                                        preActionSnapshot: beforeSnapshot), .satisfied)
        let emptyBeforeSnapshot = makeFixtureSnapshot([makeFixtureNode("e1", "AXWindow", title: "Screenshots")])
        try expectEqual(StepExpectationChecker.evaluate(StepExpectation(kind: .textAppears, text: "Saved"), in: checkerSnapshot,
                                                        preActionSnapshot: emptyBeforeSnapshot), .satisfied)
    },
])
