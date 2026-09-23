import AppKit
import ApplicationServices

/// Finds the panel, its buttons, its Go to Folder field and its file rows through Accessibility.
extension NativeOpenPanelDriver {
    private static let openPanelIdentifier = "open-panel"
    private static let maximumRowTextDepth = 4
    private static let pathFieldRoles: Set<String> = [kAXTextFieldRole, kAXComboBoxRole]
    private static let rowContainerRoles: Set<String> = [kAXOutlineRole, kAXTableRole]

    static func firstPanelElement(in openPanel: AXUIElement, where matches: (AXUIElement) -> Bool) -> AXUIElement? {
        AccessibilityElementReader.firstElementInSubtree(of: openPanel, maximumVisitedNodeCount: maximumPanelSearchNodeCount,
                                                         where: matches)
    }

    static func looksLikeOpenPanel(_ candidatePanel: AXUIElement) -> Bool {
        if AccessibilityElementReader.stringAttribute(kAXIdentifierAttribute, of: candidatePanel) == openPanelIdentifier { return true }
        let candidateRole = AccessibilityElementReader.role(of: candidatePanel)
        let candidateSubrole = AccessibilityElementReader.stringAttribute(kAXSubroleAttribute, of: candidatePanel)
        guard candidateRole == kAXSheetRole || candidateSubrole == kAXDialogSubrole else { return false }
        return button(kAXDefaultButtonAttribute, identifier: confirmButtonIdentifier, of: candidatePanel) != nil
            && button(kAXCancelButtonAttribute, identifier: cancelButtonIdentifier, of: candidatePanel) != nil
    }

    /// The panel's own attribute when it answers, else the button AppKit tags with this identifier (the attributes
    /// are listed but empty on some panels).
    static func button(_ buttonAttribute: String, identifier buttonIdentifier: String, of openPanel: AXUIElement) -> AXUIElement? {
        if let attributedButton = AccessibilityElementReader.elementAttribute(buttonAttribute, of: openPanel) { return attributedButton }
        return firstPanelElement(in: openPanel) { candidateElement in
            AccessibilityElementReader.role(of: candidateElement) == kAXButtonRole
                && AccessibilityElementReader.stringAttribute(kAXIdentifierAttribute, of: candidateElement) == buttonIdentifier
        }
    }

    /// The Go to Folder field opens as a sheet or popover inside the panel, and is recognised there by its path-like
    /// value. Only the panel is searched: a browser's address bar also holds a path, and typing there would navigate
    /// the user's tab.
    static func goToFolderField(in openPanel: AXUIElement) -> AXUIElement? {
        firstPanelElement(in: openPanel) { candidateElement in
            guard let candidateRole = AccessibilityElementReader.role(of: candidateElement), pathFieldRoles.contains(candidateRole),
                  AccessibilityElementReader.stringAttribute(kAXSubroleAttribute, of: candidateElement) != kAXSearchFieldSubrole,
                  let fieldValue = AccessibilityElementReader.stringAttribute(kAXValueAttribute, of: candidateElement) else {
                return false
            }
            return fieldValue.hasPrefix("/") || fieldValue.hasPrefix("~")
        }
    }

    /// For each selected row of the panel's file list, the texts inside it (file names show up as cell values).
    static func selectedRowTexts(in openPanel: AXUIElement) -> [[String]] {
        var selectedRows: [AXUIElement] = []
        // Visits the whole capped panel tree: the search never matches, it only collects every list's selection.
        _ = firstPanelElement(in: openPanel) { candidateElement in
            guard let candidateRole = AccessibilityElementReader.role(of: candidateElement) else { return false }
            if rowContainerRoles.contains(candidateRole) {
                selectedRows += AccessibilityElementReader.elementArrayAttribute(kAXSelectedRowsAttribute, of: candidateElement)
            } else if candidateRole == kAXListRole {
                selectedRows += AccessibilityElementReader.elementArrayAttribute(kAXSelectedChildrenAttribute, of: candidateElement)
            }
            return false
        }
        return selectedRows.map(texts(inside:))
    }

    /// Several files need AXSelectedRows set on the file list, which only list and column views expose. The first
    /// file list that holds a row for every file is the one selected in.
    static func selectRows(named fileBasenames: Set<String>, in openPanel: AXUIElement) -> Bool {
        var matchingRowsOfFileList: [AXUIElement] = []
        let fileList = firstPanelElement(in: openPanel) { rowContainer in
            guard let containerRole = AccessibilityElementReader.role(of: rowContainer), rowContainerRoles.contains(containerRole) else {
                return false
            }
            matchingRowsOfFileList = AccessibilityElementReader.elementArrayAttribute(kAXRowsAttribute, of: rowContainer).filter { row in
                texts(inside: row).contains(where: fileBasenames.contains)
            }
            return matchingRowsOfFileList.count == fileBasenames.count
        }
        guard let fileList else { return false }
        return AXUIElementSetAttributeValue(fileList, kAXSelectedRowsAttribute as CFString, matchingRowsOfFileList as CFArray) == .success
    }

    private static func texts(inside element: AXUIElement) -> [String] {
        var collectedTexts: [String] = []
        func collect(from currentElement: AXUIElement, depth: Int) {
            collectedTexts += AccessibilityElementReader.displayedTexts(of: currentElement)
            guard depth < maximumRowTextDepth else { return }
            for childElement in AccessibilityElementReader.elementArrayAttribute(kAXChildrenAttribute, of: currentElement) {
                collect(from: childElement, depth: depth + 1)
            }
        }
        collect(from: element, depth: 0)
        return collectedTexts
    }
}
