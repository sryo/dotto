import Foundation
import CoreGraphics

// Shared fixtures for the routine suites: a Finder-like window with a toolbar and a list of three files.

let routineFixtureFileNames = ["IMG_0412.jpg", "IMG_0413.jpg", "IMG_0414.jpg"]
let routineFixtureWindowFrame = CGRect(x: 100, y: 100, width: 800, height: 600)

func routineFixtureParameters(itemNumber: Int) -> [ChecklistItemParameter] {
    [ChecklistItemParameter(name: "old_name", value: routineFixtureFileNames[itemNumber - 1]),
     ChecklistItemParameter(name: "new_name", value: "beach-0\(itemNumber).jpg")]
}

func makeRoutineFixtureItem(itemNumber: Int) -> ChecklistItem {
    let parameters = routineFixtureParameters(itemNumber: itemNumber)
    return ChecklistItem(itemIdentifier: "item-\(itemNumber)", label: "Rename “\(parameters[0].value)” to “\(parameters[1].value)”",
                         actionSummary: "Rename \(parameters[0].value) to \(parameters[1].value) in the list.",
                         parameters: parameters, isIrreversible: false)
}

func makeRoutineFixtureChecklist() -> Checklist {
    makeFixtureChecklist(items: (1...3).map(makeRoutineFixtureItem), originalCommand: "rename the screenshots to beach-01…")
}

let routineFixtureFinderWindow = makeFixtureNode("e1", "AXWindow", title: "Screenshots", frame: routineFixtureWindowFrame, children: [
    makeFixtureNode("e2", "AXToolbar", children: [
        makeFixtureNode("e3", "AXButton", title: "Share", frame: CGRect(x: 700, y: 110, width: 30, height: 20)),
    ]),
    makeFixtureNode("e4", "AXOutline", description: "list view", frame: CGRect(x: 100, y: 150, width: 800, height: 500),
                    children: makeFinderFileRows(fileNames: routineFixtureFileNames,
                                                 rowFrame: { rowOffset in CGRect(x: 100, y: 160 + CGFloat(rowOffset) * 30, width: 800, height: 30) },
                                                 fieldFrame: { rowFrame in rowFrame.insetBy(dx: 20, dy: 5) })),
])

let routineFixtureFinderSnapshot = makeFixtureSnapshot([routineFixtureFinderWindow])

/// A Mail-like inbox: each row has a sender cell and a subject cell, so a row's descendant text is its sender.
func makeMailInboxRow(_ elementIdentifier: String, sender: String, subject: String, y: CGFloat) -> AccessibilityElementNode {
    makeFixtureNode(elementIdentifier, "AXRow", frame: CGRect(x: 110, y: y, width: 780, height: 20), children: [
        makeFixtureNode(elementIdentifier + "c1", "AXCell", children: [makeFixtureNode(elementIdentifier + "t1", "AXStaticText", value: sender)]),
        makeFixtureNode(elementIdentifier + "c2", "AXCell", children: [makeFixtureNode(elementIdentifier + "t2", "AXStaticText", value: subject)]),
    ])
}

let routineFixtureMailInboxSnapshot = makeFixtureSnapshot([
    makeFixtureNode("w", "AXWindow", title: "Inbox", frame: routineFixtureWindowFrame, children: [
        makeFixtureNode("tbl", "AXTable", children: [
            makeMailInboxRow("r1", sender: "Alice", subject: "Invoice March", y: 200),
            makeMailInboxRow("r2", sender: "Bob", subject: "Invoice April", y: 220),
            makeMailInboxRow("r3", sender: "Carol", subject: "Invoice May", y: 240),
        ]),
    ]),
])
