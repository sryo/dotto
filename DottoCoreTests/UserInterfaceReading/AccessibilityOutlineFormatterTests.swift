import Foundation
import CoreGraphics

/// Formatter nodes default to a small visible frame and no press action, so visibility and actions are explicit.
private func makeNode(_ elementIdentifier: String, _ role: String, subrole: String? = nil, title: String? = nil, value: String? = nil,
                      description: String? = nil, placeholder: String? = nil, frame: CGRect? = CGRect(x: 0, y: 0, width: 50, height: 20),
                      isEnabled: Bool = true, isFocused: Bool = false, isSelected: Bool = false, isSecureTextField: Bool = false,
                      supportsPressAction: Bool = false, children: [AccessibilityElementNode] = []) -> AccessibilityElementNode {
    makeFixtureNode(elementIdentifier, role, subrole: subrole, title: title, value: value, description: description,
                    placeholder: placeholder, frame: frame, isEnabled: isEnabled, isFocused: isFocused, isSelected: isSelected,
                    isSecure: isSecureTextField, supportsPressAction: supportsPressAction, children: children)
}

private func makeSnapshot(_ rootNodes: [AccessibilityElementNode], rawNodeCount: Int, generation: Int = 3,
                          wasTruncatedDuringRead: Bool = false) -> AccessibilityTreeSnapshot {
    makeFixtureSnapshot(rootNodes, generation: generation, rawNodeCount: rawNodeCount, wasTruncatedDuringRead: wasTruncatedDuringRead)
}

private let finderWindowNode = makeNode("e1", "AXWindow", title: "Screenshots", children: [
    makeNode("e2", "AXGroup", children: [
        makeNode("e3", "AXToolbar", children: [
            makeNode("e4", "AXButton", title: "Back", isEnabled: false, supportsPressAction: true),
            makeNode("e5", "AXTextField", subrole: "AXSearchField", placeholder: "Search"),
            makeNode("e6", "AXStaticText", value: ""),
        ]),
    ]),
    makeNode("e7", "AXButton", title: "Invisible", frame: CGRect(x: 0, y: 0, width: 0, height: 20), supportsPressAction: true),
    makeNode("e8", "AXOutline", description: "list view", children: [
        makeNode("e9", "AXRow", isSelected: true, children: [makeNode("e10", "AXTextField", value: "Screenshot 1.png")]),
        makeNode("e11", "AXRow", children: [makeNode("e12", "AXTextField", value: "Screenshot 2.png")]),
    ]),
    makeNode("e13", "AXTextField", subrole: "AXSecureTextField", title: "Password", isSecureTextField: true),
    makeNode("e14", "AXGroup", title: "Actions", supportsPressAction: true),
    makeNode("e15", "AXStaticText", value: "Screenshots"),
    makeNode("e16", "AXImage"),
])
private let finderSnapshot = makeSnapshot([finderWindowNode], rawNodeCount: 16)

private func elementLines(of outline: String) -> [Substring] {
    outline.split(separator: "\n").filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[e") }
}

let accessibilityOutlineFormatterTestSuite = CoreTestSuite(name: "AccessibilityOutlineFormatter", testCases: [
    CoreTestCase(name: "formats the pruned outline exactly") {
        let expectedOutline = """
        app="Finder" window="Screenshots" scope=focused_window snapshot=3 elements=16 shown=11
        [e1] window "Screenshots"
          [e3] toolbar
            [e4] button "Back" disabled
            [e5] searchfield placeholder="Search"
          [e8] outline desc="list view"
            [e9] row selected
              [e10] textfield value="Screenshot 1.png"
            [e11] row
              [e12] textfield value="Screenshot 2.png"
          [e13] textfield(secure) "Password" value=<hidden>
          [e14] group "Actions" clickable
        """
        try expectEqual(AccessibilityOutlineFormatter.formatOutline(finderSnapshot, query: nil, limits: .executor), expectedOutline)
    },
    CoreTestCase(name: "pruning: zero-size removed, empty containers hoisted, duplicate static text and empty leaves removed") {
        let prunedRoot = try unwrapOrFail(AccessibilityOutlineFormatter.prunedNodes([finderWindowNode]).first)
        try expectEqual(prunedRoot.children.map(\.elementIdentifier), ["e3", "e8", "e13", "e14"])
        try expectEqual(prunedRoot.children[0].children.map(\.elementIdentifier), ["e4", "e5"])
        let hoistedSiblings = AccessibilityOutlineFormatter.prunedNodes([makeNode("e1", "AXScrollArea", children: [
            makeNode("e2", "AXButton", title: "One"), makeNode("e3", "AXButton", title: "Two")])])
        try expectEqual(hoistedSiblings.map(\.elementIdentifier), ["e2", "e3"])
        let staticTextMatchingDescription = AccessibilityOutlineFormatter.prunedNodes([makeNode("e1", "AXButton", description: "Save", children: [
            makeNode("e2", "AXStaticText", title: "Save"), makeNode("e3", "AXStaticText", value: "Other")])])
        try expectEqual(staticTextMatchingDescription.first?.children.map(\.elementIdentifier), ["e3"])
        let unknownFrameIsKept = AccessibilityOutlineFormatter.prunedNodes([makeNode("e1", "AXButton", title: "No frame", frame: nil)])
        try expectEqual(unknownFrameIsKept.count, 1)
    },
    CoreTestCase(name: "strings: newlines become spaces, backslashes then quotes escaped, long text truncated, value equal to title hidden") {
        let longTitle = String(repeating: "a", count: 150)
        let outline = AccessibilityOutlineFormatter.formatOutline(makeSnapshot([
            makeNode("e1", "AXButton", title: "Line one\nline \"two\"", value: "Line one\nline \"two\"", supportsPressAction: true),
            makeNode("e2", "AXCheckBox", title: longTitle, isFocused: true),
            makeNode("e3", "AXButton", title: #"a\" [e9] "b"#),
        ], rawNodeCount: 3), query: nil, limits: .executor)
        let outlineLines = outline.split(separator: "\n")
        try expectEqual(String(outlineLines[1]), #"[e1] button "Line one line \"two\"""#)
        try expectEqual(String(outlineLines[2]), "[e2] checkbox \"\(String(repeating: "a", count: 100))…\" focused")
        // A backslash is escaped first, so a label can't close its own quotes and fake another element.
        try expectTrue(outline.contains(#""a\\\" [e9] \"b""#), outline)
    },
    CoreTestCase(name: "children beyond the per-node cap are summarized at the children's indentation") {
        let rows = (1...70).map { rowNumber in makeNode("e\(rowNumber + 1)", "AXRow", title: "Row \(rowNumber)") }
        let outline = AccessibilityOutlineFormatter.formatOutline(makeSnapshot([makeNode("e1", "AXTable", title: "Files", children: rows)],
                                                                               rawNodeCount: 71), query: nil, limits: .executor)
        try expectEqual(elementLines(of: outline).count, 61)
        try expectTrue(outline.hasSuffix("\n  … 10 more children of [e1] hidden — call read_ui with a query to find specific ones"), outline)
        try expectTrue(outline.contains("shown=61"))
    },
    CoreTestCase(name: "character cap stops at the last whole line and appends the truncation line") {
        let rows = (1...200).map { rowNumber in makeNode("e\(rowNumber + 1)", "AXRow", title: "Row number \(rowNumber)") }
        let tightLimits = AccessibilityOutlineLimits(maximumCharacterCount: 600, maximumChildrenShownPerNode: 250, maximumTextLength: 100)
        let outline = AccessibilityOutlineFormatter.formatOutline(makeSnapshot([makeNode("e1", "AXTable", title: "Files", children: rows)],
                                                                               rawNodeCount: 201), query: nil, limits: tightLimits)
        try expectTrue(outline.count <= 600, "length \(outline.count)")
        try expectTrue(outline.hasSuffix("\n… outline truncated at 600 characters — narrow it with a query or scope"))
        let shownElementCount = elementLines(of: outline).count
        try expectTrue(shownElementCount > 5 && shownElementCount < 201)
        try expectTrue(outline.hasPrefix("app=\"Finder\" window=\"Screenshots\" scope=focused_window snapshot=3 elements=201 shown=\(shownElementCount)\n"))
    },
    CoreTestCase(name: "query keeps matches, their ancestors and two levels of descendants") {
        let deepChain = makeNode("e20", "AXGroup", title: "Match here", children: [
            makeNode("e21", "AXGroup", title: "child", children: [
                makeNode("e22", "AXGroup", title: "grandchild", children: [makeNode("e23", "AXButton", title: "too deep")])])])
        let snapshot = makeSnapshot([makeNode("e1", "AXWindow", title: "Root", children: [
            deepChain, makeNode("e30", "AXButton", title: "Unrelated")])], rawNodeCount: 6)
        let outline = AccessibilityOutlineFormatter.formatOutline(snapshot, query: "match", limits: .executor)
        try expectEqual(elementLines(of: outline).map { $0.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? "" },
                        ["[e1]", "[e20]", "[e21]", "[e22]"])
        try expectTrue(outline.hasPrefix(#"app="Finder" window="Screenshots" scope=focused_window snapshot=3 elements=6 shown=4 query="match" matches=1"#), outline)

        let finderQueryOutline = AccessibilityOutlineFormatter.formatOutline(finderSnapshot, query: "screenshot 2", limits: .executor)
        try expectEqual(elementLines(of: finderQueryOutline).count, 4, finderQueryOutline)
        try expectTrue(finderQueryOutline.contains("[e12] textfield value=\"Screenshot 2.png\""))
        try expectTrue(!finderQueryOutline.contains("[e10]"))
    },
    CoreTestCase(name: "query with no matches prints the header and a notice") {
        try expectEqual(AccessibilityOutlineFormatter.formatOutline(finderSnapshot, query: "zzz", limits: .executor),
                        "app=\"Finder\" window=\"Screenshots\" scope=focused_window snapshot=3 elements=16 shown=0 query=\"zzz\" matches=0\n(no elements match \"zzz\")")
    },
    CoreTestCase(name: "empty query behaves like no query; read truncation is flagged in the header") {
        try expectEqual(AccessibilityOutlineFormatter.formatOutline(finderSnapshot, query: "  ", limits: .executor),
                        AccessibilityOutlineFormatter.formatOutline(finderSnapshot, query: nil, limits: .executor))
        let truncatedReadOutline = AccessibilityOutlineFormatter.formatOutline(makeSnapshot([finderWindowNode], rawNodeCount: 3000, wasTruncatedDuringRead: true),
                                                                               query: nil, limits: .planner)
        try expectTrue(truncatedReadOutline.split(separator: "\n")[0].contains("element limit"))
    },
    CoreTestCase(name: "only ids of the snapshot itself resolve; ids from an older snapshot are stale") {
        let olderSnapshot = makeSnapshot([makeNode("e1", "AXWindow", title: "Old", children: [makeNode("e2", "AXButton", title: "OK")])],
                                         rawNodeCount: 2, generation: 1)
        let newerSnapshot = makeSnapshot([makeNode("e3", "AXWindow", title: "New", children: [makeNode("e4", "AXButton", title: "OK")])],
                                         rawNodeCount: 2, generation: 2)
        try expectEqual(olderSnapshot.node(withIdentifier: "e2")?.title, "OK")
        try expectEqual(newerSnapshot.node(withIdentifier: "e4")?.elementIdentifier, "e4")
        try expectEqual(newerSnapshot.node(withIdentifier: "e2"), nil)
        try expectEqual(finderSnapshot.node(withIdentifier: "e7")?.title, "Invisible", "lookup uses the raw tree, not the pruned one")
    },
    CoreTestCase(name: "containsText searches titles, values, descriptions and placeholders case-insensitively") {
        try expectTrue(finderSnapshot.containsText("SCREENSHOT 2"))
        try expectTrue(finderSnapshot.containsText("list VIEW"))
        try expectTrue(finderSnapshot.containsText("search"))
        try expectTrue(!finderSnapshot.containsText("Trash"))
    },
    CoreTestCase(name: "short role names") {
        let expectedShortNames: [(String, String?, String)] = [
            ("AXStaticText", nil, "text"), ("AXPopUpButton", nil, "popup"), ("AXRadioButton", nil, "radio"),
            ("AXCheckBox", nil, "checkbox"), ("AXMenuItem", nil, "menuitem"), ("AXMenuBarItem", nil, "menubaritem"),
            ("AXComboBox", nil, "combobox"), ("AXTextArea", nil, "textarea"), ("AXDisclosureTriangle", nil, "disclosure"),
            ("AXWebArea", nil, "webarea"), ("AXButton", nil, "button"), ("AXTextField", "AXSearchField", "searchfield"),
            ("AXTextField", "AXSecureTextField", "textfield(secure)"), ("AXSplitGroup", nil, "splitgroup"),
        ]
        for (role, subrole, expectedShortName) in expectedShortNames {
            try expectEqual(AccessibilityOutlineFormatter.shortRoleName(role: role, subrole: subrole), expectedShortName)
        }
    },
])
