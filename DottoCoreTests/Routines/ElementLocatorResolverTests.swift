import Foundation
import CoreGraphics

private func locator(forNodeWithIdentifier elementIdentifier: String, in snapshot: AccessibilityTreeSnapshot = routineFixtureFinderSnapshot,
                     parameters: [ChecklistItemParameter] = routineFixtureParameters(itemNumber: 1)) throws -> ElementLocator {
    let recordedContext = try unwrapOrFail(snapshot.recordedElementContext(forNodeWithIdentifier: elementIdentifier))
    return ElementLocatorBuilding.makeLocator(from: recordedContext, parameters: parameters, targetTextTemplateOverride: nil)
}

private func resolvedIdentifier(_ resolution: ElementLocatorResolution) -> String? {
    if case .resolved(let node, _) = resolution { return node.elementIdentifier }
    return nil
}

private func window(_ children: [AccessibilityElementNode]) -> AccessibilityElementNode {
    makeFixtureNode("w", "AXWindow", title: "Dialogs", frame: routineFixtureWindowFrame, children: children)
}

let elementLocatorResolverTestSuite = CoreTestSuite(name: "ElementLocatorResolver", testCases: [
    CoreTestCase(name: "recordedElementContext returns ancestors nearest first, descendant text and the window frame") {
        let recordedContext = try unwrapOrFail(routineFixtureFinderSnapshot.recordedElementContext(forNodeWithIdentifier: "e10"))
        try expectEqual(recordedContext.element.role, "AXRow")
        try expectEqual(recordedContext.element.children, [])
        try expectEqual(recordedContext.ancestorsNearestFirst.map(\.role), ["AXOutline", "AXWindow"])
        try expectEqual(recordedContext.descendantText, "IMG_0412.jpg")
        try expectEqual(recordedContext.windowFrameInTopLeftGlobalPoints, routineFixtureWindowFrame)
        try expectEqual(recordedContext.readScope, .focusedWindow)
        try expectEqual(routineFixtureFinderSnapshot.recordedElementContext(forNodeWithIdentifier: "e99"), nil)
    },
    CoreTestCase(name: "a field located on item 1 with {{old_name}} resolves item 2's field") {
        let fieldLocator = try locator(forNodeWithIdentifier: "e11")
        try expectEqual(fieldLocator.valueTemplate, "{{old_name}}")
        try expectEqual(fieldLocator.ancestorsNearestFirst.map(\.role), ["AXRow", "AXOutline"])
        let resolution = try ElementLocatorResolver.resolve(fieldLocator, parameters: routineFixtureParameters(itemNumber: 2),
                                                            in: routineFixtureFinderSnapshot)
        try expectEqual(resolvedIdentifier(resolution), "e13")
    },
    CoreTestCase(name: "a template mismatch is not found even when the position matches perfectly") {
        let fieldLocator = try locator(forNodeWithIdentifier: "e11")
        let unknownFileParameters = [ChecklistItemParameter(name: "old_name", value: "IMG_9999.jpg"),
                                     ChecklistItemParameter(name: "new_name", value: "x.jpg")]
        try expectEqual(try ElementLocatorResolver.resolve(fieldLocator, parameters: unknownFileParameters, in: routineFixtureFinderSnapshot),
                        .notFound)
    },
    CoreTestCase(name: "an untitled row resolves by its descendant text") {
        let rowLocator = try locator(forNodeWithIdentifier: "e10")
        try expectEqual(rowLocator.titleTemplate, nil)
        try expectEqual(rowLocator.descendantTextTemplate, "{{old_name}}")
        let resolution = try ElementLocatorResolver.resolve(rowLocator, parameters: routineFixtureParameters(itemNumber: 3),
                                                            in: routineFixtureFinderSnapshot)
        try expectEqual(resolvedIdentifier(resolution), "e14")
    },
    CoreTestCase(name: "two OK buttons resolve by their ancestors' titles") {
        func okButtonInSheet(_ sheetTitle: String, identifierSuffix: String) -> AccessibilityElementNode {
            makeFixtureNode("s\(identifierSuffix)", "AXSheet", title: sheetTitle, children: [
                makeFixtureNode("g\(identifierSuffix)", "AXGroup", title: "\(sheetTitle) options", children: [
                    makeFixtureNode("b\(identifierSuffix)", "AXButton", title: "OK"),
                ]),
            ])
        }
        let snapshot = makeFixtureSnapshot([window([okButtonInSheet("Rename", identifierSuffix: "1"),
                                                           okButtonInSheet("Delete", identifierSuffix: "2")])])
        let okLocator = try locator(forNodeWithIdentifier: "b2", in: snapshot)
        try expectEqual(resolvedIdentifier(try ElementLocatorResolver.resolve(okLocator, parameters: [], in: snapshot)), "b2")
    },
    CoreTestCase(name: "identical siblings are ambiguous") {
        let snapshot = makeFixtureSnapshot([window([makeFixtureNode("b1", "AXButton", title: "Add"),
                                                           makeFixtureNode("b2", "AXButton", title: "Add")])])
        let addLocator = try locator(forNodeWithIdentifier: "b1", in: snapshot)
        guard case .ambiguous(let candidateCount, _) = try ElementLocatorResolver.resolve(addLocator, parameters: [], in: snapshot) else {
            throw CoreTestFailure(description: "expected ambiguous")
        }
        try expectEqual(candidateCount, 2)
    },
    CoreTestCase(name: "an identifier match beats a moved position") {
        let recordedSnapshot = makeFixtureSnapshot([window([
            makeFixtureNode("b1", "AXButton", title: "Export", identifier: "exportButton", frame: CGRect(x: 120, y: 120, width: 60, height: 20)),
            makeFixtureNode("b2", "AXButton", title: "Export", identifier: "exportAllButton", frame: CGRect(x: 800, y: 600, width: 60, height: 20)),
        ])])
        let exportLocator = try locator(forNodeWithIdentifier: "b1", in: recordedSnapshot)
        let movedSnapshot = makeFixtureSnapshot([window([
            makeFixtureNode("m1", "AXButton", title: "Export", identifier: "exportAllButton", frame: CGRect(x: 120, y: 120, width: 60, height: 20)),
            makeFixtureNode("m2", "AXButton", title: "Export", identifier: "exportButton", frame: CGRect(x: 800, y: 600, width: 60, height: 20)),
        ])])
        try expectEqual(resolvedIdentifier(try ElementLocatorResolver.resolve(exportLocator, parameters: [], in: movedSnapshot)), "m2")
    },
    CoreTestCase(name: "a role mismatch is excluded") {
        let shareLocator = try locator(forNodeWithIdentifier: "e3")
        let snapshotWithShareAsText = makeFixtureSnapshot([window([makeFixtureNode("t1", "AXStaticText", title: "Share")])])
        try expectEqual(try ElementLocatorResolver.resolve(shareLocator, parameters: [], in: snapshotWithShareAsText), .notFound)
        try expectEqual(resolvedIdentifier(try ElementLocatorResolver.resolve(shareLocator, parameters: [], in: routineFixtureFinderSnapshot)), "e3")
    },
    CoreTestCase(name: "a menu item locator reads the menu bar") {
        let menuSnapshot = makeFixtureSnapshot([makeFixtureNode("m1", "AXMenuBar", children: [
            makeFixtureNode("m2", "AXMenuBarItem", title: "File", children: [
                makeFixtureNode("m3", "AXMenuItem", title: "Rename…"),
            ]),
        ])], scope: .allWindows)
        try expectEqual(try locator(forNodeWithIdentifier: "m3", in: menuSnapshot).readScope, .menuBar)
        try expectEqual(try locator(forNodeWithIdentifier: "e3").readScope, .focusedWindow)
    },
    CoreTestCase(name: "an unknown placeholder in a locator throws") {
        var brokenLocator = try locator(forNodeWithIdentifier: "e11")
        brokenLocator.valueTemplate = "{{caption}}"
        _ = try expectThrowsError { _ = try ElementLocatorResolver.resolve(brokenLocator, parameters: [], in: routineFixtureFinderSnapshot) }
    },
    CoreTestCase(name: "a mail row picked by its sender never replays onto item 1's row when the subject is the parameter") {
        let subjectOfItem1 = [ChecklistItemParameter(name: "subject", value: "Invoice March")]
        let subjectOfItem2 = [ChecklistItemParameter(name: "subject", value: "Invoice April")]
        let rowLocator = try locator(forNodeWithIdentifier: "r1", in: routineFixtureMailInboxSnapshot, parameters: subjectOfItem1)
        try expectEqual(rowLocator.descendantTextTemplate, "Alice")
        try expectTrue(ElementLocatorBuilding.identifiesListElementWithoutParameter(rowLocator))
        try expectEqual(try ElementLocatorResolver.resolve(rowLocator, parameters: subjectOfItem2, in: routineFixtureMailInboxSnapshot),
                        .listElementWithoutParameter)

        let rowContext = try unwrapOrFail(routineFixtureMailInboxSnapshot.recordedElementContext(forNodeWithIdentifier: "r1"))
        var mailItem = makeRoutineFixtureItem(itemNumber: 1)
        mailItem.parameters = subjectOfItem1
        let compiledRoutine = RoutineCompiler.compileFromAgentRun(
            recordedSteps: [RecordedAgentStep(toolCall: .action(.clickElement(elementIdentifier: "r1", clickType: .single)),
                                              targetContext: rowContext, expectation: nil, wasConfirmedByUser: false),
                            RecordedAgentStep(toolCall: .action(.typeText(elementIdentifier: nil, text: "Invoice March paid", replaceExistingText: false,
                                                                          pressReturnAfter: false)),
                                              targetContext: nil, expectation: nil, wasConfirmedByUser: false)],
            completionEvidence: nil, checklist: makeRoutineFixtureChecklist(), item: mailItem, modelCallsUsed: 4,
            routineIdentifier: "routine-mail", now: Date())
        try expectEqual(compiledRoutine, nil, "a literal list row must not compile")
    },
    CoreTestCase(name: "a row whose text holds the parameter as whole words is templatized and follows the item") {
        let snapshot = makeFixtureSnapshot([window([makeFixtureNode("tbl", "AXTable", children: [
            makeFixtureNode("r1", "AXRow", children: [makeFixtureNode("t1", "AXStaticText", value: "Re: Invoice March")]),
            makeFixtureNode("r2", "AXRow", children: [makeFixtureNode("t2", "AXStaticText", value: "Re: Invoice April")]),
        ])])])
        let rowLocator = try locator(forNodeWithIdentifier: "r1", in: snapshot, parameters: [ChecklistItemParameter(name: "subject", value: "Invoice March")])
        try expectEqual(rowLocator.descendantTextTemplate, "Re: {{subject}}")
        try expectEqual(resolvedIdentifier(try ElementLocatorResolver.resolve(
            rowLocator, parameters: [ChecklistItemParameter(name: "subject", value: "Invoice April")], in: snapshot)), "r2")
    },
    CoreTestCase(name: "a parameter that is one word of a button title leaves the title fixed") {
        let buttonSnapshot = makeFixtureSnapshot([window([
            makeFixtureNode("b", "AXButton", title: "New Folder", frame: CGRect(x: 120, y: 120, width: 80, height: 20)),
        ])])
        let buttonLocator = try locator(forNodeWithIdentifier: "b", in: buttonSnapshot, parameters: [ChecklistItemParameter(name: "folder_name", value: "New")])
        try expectEqual(buttonLocator.titleTemplate, "New Folder")
        try expectEqual(resolvedIdentifier(try ElementLocatorResolver.resolve(
            buttonLocator, parameters: [ChecklistItemParameter(name: "folder_name", value: "Archive")], in: buttonSnapshot)), "b")
        let wholeTitleLocator = try locator(forNodeWithIdentifier: "b", in: buttonSnapshot,
                                            parameters: [ChecklistItemParameter(name: "folder_name", value: "New Folder")])
        try expectEqual(wholeTitleLocator.titleTemplate, "{{folder_name}}")
        try expectEqual(RoutineTemplating.templatizeLocatorText("Newsletter New", parameters: [ChecklistItemParameter(name: "p", value: "New")],
                                                                allowsWholeTokenMatches: true), "Newsletter {{p}}")
    },
    CoreTestCase(name: "a context menu item is read where it was recorded, not in the menu bar") {
        let contextMenuSnapshot = makeFixtureSnapshot([window([
            makeFixtureNode("m", "AXMenu", children: [makeFixtureNode("mi", "AXMenuItem", title: "Rename")]),
        ])])
        try expectEqual(try locator(forNodeWithIdentifier: "mi", in: contextMenuSnapshot, parameters: []).readScope, .focusedWindow)
    },
])
