import Foundation
import CoreGraphics

// The one Accessibility node and snapshot builder every suite uses, and the Finder-like file list the routine
// suites share.

let fixtureTargetApplication = TargetApplicationReference(processIdentifier: 4242, applicationName: "Finder",
                                                          bundleIdentifier: "com.apple.finder")

func makeFixtureNode(_ elementIdentifier: String, _ role: String, subrole: String? = nil, title: String? = nil,
                     value: String? = nil, description: String? = nil, placeholder: String? = nil, identifier: String? = nil,
                     helpText: String? = nil, frame: CGRect? = nil, isEnabled: Bool = true, isFocused: Bool = false,
                     isSelected: Bool = false, isSecure: Bool = false, supportsPressAction: Bool = true,
                     children: [AccessibilityElementNode] = []) -> AccessibilityElementNode {
    AccessibilityElementNode(elementIdentifier: elementIdentifier, role: role, subrole: subrole, title: title, value: value,
                             elementDescription: description, placeholder: placeholder, frameInTopLeftGlobalPoints: frame,
                             isEnabled: isEnabled, isFocused: isFocused, isSelected: isSelected, isSecureTextField: isSecure,
                             supportsPressAction: supportsPressAction, children: children, helpText: helpText,
                             accessibilityIdentifier: identifier)
}

func makeFixtureSnapshot(_ rootNodes: [AccessibilityElementNode], scope: ReadUserInterfaceScope = .focusedWindow,
                         windowTitle: String? = "Screenshots", document: String? = nil, generation: Int = 1,
                         rawNodeCount: Int = 20, wasTruncatedDuringRead: Bool = false) -> AccessibilityTreeSnapshot {
    AccessibilityTreeSnapshot(snapshotGeneration: generation, application: fixtureTargetApplication, windowTitle: windowTitle,
                              scope: scope, rootNodes: rootNodes, rawNodeCount: rawNodeCount,
                              wasTruncatedDuringRead: wasTruncatedDuringRead, focusedWindowDocument: document)
}

/// Finder's list view: one untitled row per file ("e10", "e12", …), each holding a text field whose value is the
/// file name ("e11", "e13", …).
func makeFinderFileRows(fileNames: [String], rowFrame: (_ rowOffset: Int) -> CGRect,
                        fieldFrame: (_ rowFrame: CGRect) -> CGRect = { $0 },
                        supportsPressAction: Bool = true) -> [AccessibilityElementNode] {
    fileNames.enumerated().map { rowOffset, fileName in
        let frameOfRow = rowFrame(rowOffset)
        return makeFixtureNode("e\(10 + rowOffset * 2)", "AXRow", frame: frameOfRow, supportsPressAction: supportsPressAction, children: [
            makeFixtureNode("e\(11 + rowOffset * 2)", "AXTextField", value: fileName, frame: fieldFrame(frameOfRow),
                            supportsPressAction: supportsPressAction),
        ])
    }
}

/// A window holding a single password field ("e5"), which SafetyGate and the backend always refuse to type into.
func makePasswordFieldWindowRootNodes() -> [AccessibilityElementNode] {
    [makeFixtureNode("e1", "AXWindow", title: "Documents", children: [
        makeFixtureNode("e5", "AXTextField", subrole: "AXSecureTextField", title: "Password", isSecure: true),
    ])]
}
