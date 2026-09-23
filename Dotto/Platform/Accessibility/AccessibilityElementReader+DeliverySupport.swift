import AppKit
import ApplicationServices

typealias MenuItemWithCommandCharacter = (commandCharacter: String?, commandModifierMask: Int?, element: AXUIElement)

/// What the action backend reads to plan and confirm background delivery.
extension AccessibilityElementReader {
    static let menuOpeningRoles: Set<String> = [kAXPopUpButtonRole, kAXMenuButtonRole]
    private static let singleLineTextInputRoles: Set<String> = [kAXTextFieldRole, kAXComboBoxRole]
    private static let searchFieldSubrole = "AXSearchField"
    private static let maximumMenuWalkDepth = 5

    func elementInputTraits(of accessibilityElement: AXUIElement) -> ElementInputTraits {
        let elementActionNames = Self.actionNames(of: accessibilityElement)
        let elementRole = Self.role(of: accessibilityElement)
        let elementSubrole = Self.stringAttribute(kAXSubroleAttribute, of: accessibilityElement)
        let isSingleLineTextInput = elementRole.map(Self.singleLineTextInputRoles.contains) == true
            || elementSubrole == Self.searchFieldSubrole
        return ElementInputTraits(
            supportsPressAction: elementActionNames.contains(kAXPressAction),
            supportsShowMenuAction: elementActionNames.contains(kAXShowMenuAction),
            isInsideWebArea: isInsideWebArea(accessibilityElement),
            isSingleLineTextInput: isSingleLineTextInput && elementRole != kAXTextAreaRole,
            isValueSettable: isValueSettable(on: accessibilityElement),
            hasSettableScrollBar: settableScrollBar(forScrolling: accessibilityElement, isVertical: true) != nil
                || settableScrollBar(forScrolling: accessibilityElement, isVertical: false) != nil,
            opensMenuWhenPressed: elementRole.map(Self.menuOpeningRoles.contains) == true)
    }

    /// Web content is deep (a text field can sit 30+ levels below the window), so this walks further than the
    /// recorded ancestor chain does. The window or the application ends the search.
    func isInsideWebArea(_ accessibilityElement: AXUIElement) -> Bool {
        let webAreaOrTopLevelAncestor = Self.firstAncestorOrSelf(of: accessibilityElement) { element in
            let elementRole = Self.role(of: element)
            return elementRole == Self.webAreaRole || elementRole == kAXWindowRole || elementRole == kAXApplicationRole
        }
        return webAreaOrTopLevelAncestor.map(Self.role(of:)) == Self.webAreaRole
    }

    /// The nearest enclosing scroll area's scroll bar (or, for a window, the first scroll area inside it), when its
    /// value can be set. Setting it scrolls a background app without any pointer event.
    func settableScrollBar(forScrolling accessibilityElement: AXUIElement, isVertical: Bool)
        -> (scrollBar: AXUIElement, scrollArea: AXUIElement)? {
        let scrollAreaOrWindow = Self.firstAncestorOrSelf(of: accessibilityElement, maximumDepth: Self.maximumRecordedAncestorCount) {
            let elementRole = Self.role(of: $0)
            return elementRole == kAXScrollAreaRole || elementRole == kAXWindowRole
        }
        let scrollArea = scrollAreaOrWindow.flatMap { scrollAreaOrWindow in
            Self.role(of: scrollAreaOrWindow) == kAXWindowRole
                ? Self.firstElementInSubtree(of: scrollAreaOrWindow) { Self.role(of: $0) == kAXScrollAreaRole }
                : scrollAreaOrWindow
        }
        guard let scrollArea,
              let scrollBar = Self.elementAttribute(isVertical ? kAXVerticalScrollBarAttribute : kAXHorizontalScrollBarAttribute,
                                                    of: scrollArea),
              isValueSettable(on: scrollBar) else { return nil }
        return (scrollBar, scrollArea)
    }

    /// AX-only parts of the fingerprint; the image hash is added by the backend only when these show no change.
    /// Values are hashed, never stored.
    func changeFingerprint(of application: TargetApplicationReference, targetElement: AXUIElement?) -> UserInterfaceChangeFingerprint {
        let applicationElement = Self.makeApplicationElement(for: application.processIdentifier)
        let focusedElement = Self.elementAttribute(kAXFocusedUIElementAttribute, of: applicationElement)
        let focusedWindow = Self.focusedWindowElement(ofApplicationElement: applicationElement)
        var targetElementStateToken: Int?
        if let targetElement {
            var targetElementState = Hasher()
            targetElementState.combine(untruncatedStringValue(of: targetElement))
            targetElementState.combine(Self.boolAttribute(kAXSelectedAttribute, of: targetElement))
            targetElementState.combine(Self.boolAttribute(kAXExpandedAttribute, of: targetElement))
            targetElementState.combine(Self.role(of: targetElement) != nil)
            targetElementStateToken = targetElementState.finalize()
        }
        // CFHash of an AXValue isn't based on its contents, so the decoded range is hashed instead.
        let selectedTextRangeToken = focusedElement.flatMap { Self.rangeValue(Self.rawAttribute(kAXSelectedTextRangeAttribute, of: $0)) }
            .map { selectedRange in
                var selectedRangeHasher = Hasher()
                selectedRangeHasher.combine(selectedRange.location)
                selectedRangeHasher.combine(selectedRange.length)
                return selectedRangeHasher.finalize()
            }
        let webArea = focusedWindow.flatMap { Self.firstElementInSubtree(of: $0) { Self.role(of: $0) == Self.webAreaRole } }
        return UserInterfaceChangeFingerprint(
            focusedElementToken: focusedElement.map { Int(bitPattern: CFHash($0)) },
            focusedElementValueToken: focusedElement.flatMap { untruncatedStringValue(of: $0) }.map { $0.hashValue },
            selectedTextRangeToken: selectedTextRangeToken,
            targetElementStateToken: targetElementStateToken,
            windowCount: Self.elementArrayAttribute(kAXWindowsAttribute, of: applicationElement).count,
            focusedWindowTitle: focusedWindow.flatMap { Self.stringAttribute(kAXTitleAttribute, of: $0) },
            webAreaAddress: webArea.flatMap { Self.stringAttribute(Self.webAreaAddressAttribute, of: $0) },
            focusedWindowChildCount: focusedWindow.map { Self.elementArrayAttribute(kAXChildrenAttribute, of: $0).count } ?? 0,
            windowImageThumbnail: nil)
    }

    /// Every menu item that has a key equivalent, so a ⌘ shortcut can be delivered by pressing its menu item in the
    /// background instead of as a key event (which would need the app to be focused).
    func menuItemsWithCommandCharacters(of application: TargetApplicationReference) -> [MenuItemWithCommandCharacter] {
        let applicationElement = Self.makeApplicationElement(for: application.processIdentifier)
        guard let menuBar = Self.elementAttribute(kAXMenuBarAttribute, of: applicationElement) else { return [] }
        var menuItems: [MenuItemWithCommandCharacter] = []
        func collectMenuItems(under menuElement: AXUIElement, depth: Int) {
            guard depth < Self.maximumMenuWalkDepth else { return }
            for childElement in Self.elementArrayAttribute(kAXChildrenAttribute, of: menuElement) {
                if Self.role(of: childElement) == kAXMenuItemRole,
                   let commandCharacter = Self.stringAttribute(kAXMenuItemCmdCharAttribute, of: childElement) {
                    let commandModifierMask = Self.numberAttribute(kAXMenuItemCmdModifiersAttribute, of: childElement)?.intValue
                    menuItems.append((commandCharacter, commandModifierMask, childElement))
                }
                collectMenuItems(under: childElement, depth: depth + 1)
            }
        }
        collectMenuItems(under: menuBar, depth: 0)
        return menuItems
    }
}
