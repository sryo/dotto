import Foundation
import CoreGraphics

struct AccessibilityElementNode: Codable, Equatable, Sendable {
    var elementIdentifier: String
    var role: String
    var subrole: String?
    var title: String?
    var value: String?
    var elementDescription: String?
    var placeholder: String?
    var frameInTopLeftGlobalPoints: CGRect?
    var isEnabled: Bool
    var isFocused: Bool
    var isSelected: Bool
    var isSecureTextField: Bool
    var supportsPressAction: Bool
    var children: [AccessibilityElementNode]
    /// AXHelp (tooltip text). Not shown in outlines; SafetyGate reads it because an icon-only button's
    /// only name is often its tooltip.
    var helpText: String? = nil
    /// AXIdentifier. Routine locators match on it; outlines never print it.
    var accessibilityIdentifier: String? = nil
}

struct AccessibilityTreeSnapshot: Equatable, Sendable {
    var snapshotGeneration: Int
    var application: TargetApplicationReference
    var windowTitle: String?
    var scope: ReadUserInterfaceScope
    var rootNodes: [AccessibilityElementNode]
    var rawNodeCount: Int
    var wasTruncatedDuringRead: Bool
    /// The window's AXDocument, else the first web area's AXURL.
    var focusedWindowDocument: String? = nil
    /// The outlined window is minimized in the Dock: its elements still read, but nothing of it is on screen.
    var windowIsMinimized: Bool = false

    func node(withIdentifier elementIdentifier: String) -> AccessibilityElementNode? {
        func findNode(in candidateNodes: [AccessibilityElementNode]) -> AccessibilityElementNode? {
            for candidateNode in candidateNodes {
                if candidateNode.elementIdentifier == elementIdentifier { return candidateNode }
                if let matchingDescendant = findNode(in: candidateNode.children) { return matchingDescendant }
            }
            return nil
        }
        return findNode(in: rootNodes)
    }

    /// The first focused element in document order; SafetyGate uses it to tell what Space or Return will activate.
    var focusedNode: AccessibilityElementNode? {
        func findFocusedNode(in candidateNodes: [AccessibilityElementNode]) -> AccessibilityElementNode? {
            for candidateNode in candidateNodes {
                if candidateNode.isFocused { return candidateNode }
                if let focusedDescendant = findFocusedNode(in: candidateNode.children) { return focusedDescendant }
            }
            return nil
        }
        return findFocusedNode(in: rootNodes)
    }

    /// The texts of every element whose text contains `searchText`, sorted. Two snapshots with equal signatures
    /// show the text in the same places with the same surroundings, so nothing about it changed in between.
    func textMatchSignature(_ searchText: String) -> [String] {
        var matchingElementTexts: [String] = []
        func collect(_ candidateNodes: [AccessibilityElementNode]) {
            for candidateNode in candidateNodes {
                if AccessibilityOutlineFormatter.nodeTextMatches(candidateNode, query: searchText) {
                    matchingElementTexts.append([candidateNode.role, candidateNode.title ?? "", candidateNode.value ?? "",
                                                 candidateNode.elementDescription ?? "", candidateNode.placeholder ?? ""]
                                                    .joined(separator: "\u{1F}"))
                }
                collect(candidateNode.children)
            }
        }
        collect(rootNodes)
        return matchingElementTexts.sorted()
    }

    func containsText(_ searchText: String) -> Bool {
        func anyNodeMatches(_ candidateNodes: [AccessibilityElementNode]) -> Bool {
            candidateNodes.contains { candidateNode in
                AccessibilityOutlineFormatter.nodeTextMatches(candidateNode, query: searchText) || anyNodeMatches(candidateNode.children)
            }
        }
        return anyNodeMatches(rootNodes)
    }
}

struct AccessibilityOutlineLimits: Equatable, Sendable {
    var maximumCharacterCount: Int
    var maximumChildrenShownPerNode: Int
    var maximumTextLength: Int
    static let planner = AccessibilityOutlineLimits(maximumCharacterCount: 30000, maximumChildrenShownPerNode: 250, maximumTextLength: 100)
    static let executor = AccessibilityOutlineLimits(maximumCharacterCount: 10000, maximumChildrenShownPerNode: 60, maximumTextLength: 100)
}
