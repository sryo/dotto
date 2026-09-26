import Foundation
import CoreGraphics

/// What an Accessibility role says about an element, shared by the outline and the screenshot marks so both call the
/// same elements interactive.
enum AccessibilityRoleTraits {
    static let interactiveRoles: Set<String> = ["AXButton", "AXCheckBox", "AXRadioButton", "AXTextField", "AXTextArea",
        "AXComboBox", "AXPopUpButton", "AXMenuButton", "AXLink", "AXSlider", "AXIncrementor", "AXMenuItem", "AXMenuBarItem",
        "AXRow", "AXCell", "AXDisclosureTriangle", "AXTab", "AXColorWell", "AXDateField"]

    /// Ancestors whose frame bounds what of their content is on screen: a row scrolled out of its scroll area keeps
    /// its frame, but nothing of it is visible.
    static let visibleAreaClippingRoles: Set<String> = ["AXWindow", "AXScrollArea", "AXWebArea", "AXSheet", "AXPopover"]

    /// A sheet covers the window it is attached to, so while one is open only its own elements can be clicked.
    static let modalContainerRoles: Set<String> = ["AXSheet"]

    static func isInteractive(_ node: AccessibilityElementNode) -> Bool {
        node.supportsPressAction || interactiveRoles.contains(node.role)
    }

    /// Lower ranks win when two marks would cover the same spot: the control the user would aim at comes before the
    /// row or cell around it.
    static func markPriorityRank(of node: AccessibilityElementNode) -> Int {
        switch node.role {
        case "AXTextField", "AXTextArea", "AXComboBox", "AXDateField": return 0
        case "AXButton", "AXLink", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXTab",
             "AXDisclosureTriangle", "AXSlider", "AXIncrementor", "AXColorWell": return 1
        case "AXMenuItem", "AXMenuBarItem": return 2
        case "AXRow": return 3
        case "AXCell": return 4
        default: return 5
        }
    }
}
