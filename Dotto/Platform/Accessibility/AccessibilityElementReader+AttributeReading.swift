import AppKit
import ApplicationServices

/// Single-attribute reads and the small walks every Accessibility caller shares. A failed read is nil (or empty),
/// never an error: apps leave attributes out all the time.
extension AccessibilityElementReader {
    private static let maximumSubtreeSearchNodeCount = 400

    // MARK: - Attributes

    static func rawAttribute(_ attributeName: String, of accessibilityElement: AXUIElement) -> CFTypeRef? {
        var attributeReference: CFTypeRef?
        guard AXUIElementCopyAttributeValue(accessibilityElement, attributeName as CFString, &attributeReference) == .success else {
            return nil
        }
        return attributeReference
    }

    /// Capped at the outline's text length; see `untruncatedStringValue` for comparisons.
    static func stringAttribute(_ attributeName: String, of accessibilityElement: AXUIElement) -> String? {
        stringified(rawAttribute(attributeName, of: accessibilityElement))
    }

    static func boolAttribute(_ attributeName: String, of accessibilityElement: AXUIElement) -> Bool? {
        boolValue(rawAttribute(attributeName, of: accessibilityElement))
    }

    static func numberAttribute(_ attributeName: String, of accessibilityElement: AXUIElement) -> NSNumber? {
        rawAttribute(attributeName, of: accessibilityElement) as? NSNumber
    }

    static func elementAttribute(_ attributeName: String, of accessibilityElement: AXUIElement) -> AXUIElement? {
        guard let attributeReference = rawAttribute(attributeName, of: accessibilityElement),
              CFGetTypeID(attributeReference) == AXUIElementGetTypeID() else { return nil }
        return (attributeReference as! AXUIElement)
    }

    static func elementArrayAttribute(_ attributeName: String, of accessibilityElement: AXUIElement) -> [AXUIElement] {
        elements(from: rawAttribute(attributeName, of: accessibilityElement))
    }

    static func role(of accessibilityElement: AXUIElement) -> String? {
        stringAttribute(kAXRoleAttribute, of: accessibilityElement)
    }

    static func frameInTopLeftGlobalPoints(of accessibilityElement: AXUIElement) -> CGRect? {
        guard let position = pointValue(rawAttribute(kAXPositionAttribute, of: accessibilityElement)),
              let size = sizeValue(rawAttribute(kAXSizeAttribute, of: accessibilityElement)) else { return nil }
        return CGRect(origin: position, size: size)
    }

    static func processIdentifier(of accessibilityElement: AXUIElement) -> pid_t? {
        var owningProcessIdentifier: pid_t = 0
        guard AXUIElementGetPid(accessibilityElement, &owningProcessIdentifier) == .success else { return nil }
        return owningProcessIdentifier
    }

    static func actionNames(of accessibilityElement: AXUIElement) -> [String] {
        var actionNamesReference: CFArray?
        guard AXUIElementCopyActionNames(accessibilityElement, &actionNamesReference) == .success else { return [] }
        return (actionNamesReference as? [String]) ?? []
    }

    /// The value, title and description texts an element shows, in that order.
    static func displayedTexts(of accessibilityElement: AXUIElement) -> [String] {
        [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute].compactMap { attributeName in
            stringAttribute(attributeName, of: accessibilityElement)
        }
    }

    /// The complete AXValue text, without the outline's length cap, for length and before/after comparisons.
    func untruncatedStringValue(of accessibilityElement: AXUIElement) -> String? {
        let valueReference = Self.rawAttribute(kAXValueAttribute, of: accessibilityElement)
        if let stringValue = valueReference as? String { return stringValue }
        if let attributedStringValue = valueReference as? NSAttributedString { return attributedStringValue.string }
        return nil
    }

    func isValueSettable(on accessibilityElement: AXUIElement) -> Bool {
        var isSettable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(accessibilityElement, kAXValueAttribute as CFString, &isSettable) == .success
            && isSettable.boolValue
    }

    func isSecureTextField(_ accessibilityElement: AXUIElement) -> Bool {
        Self.role(of: accessibilityElement) == Self.secureTextFieldSubrole
            || Self.stringAttribute(kAXSubroleAttribute, of: accessibilityElement) == Self.secureTextFieldSubrole
    }

    // MARK: - Walks

    /// The topmost accessible element at a point, as `containerElement` (an app, or the system-wide element) answers
    /// the hit test; nil when it doesn't answer (some apps don't).
    static func element(atTopLeftGlobalPoint topLeftGlobalPoint: CGPoint, in containerElement: AXUIElement) -> AXUIElement? {
        var elementAtPoint: AXUIElement?
        guard AXUIElementCopyElementAtPosition(containerElement, Float(topLeftGlobalPoint.x), Float(topLeftGlobalPoint.y),
                                               &elementAtPoint) == .success else { return nil }
        return elementAtPoint
    }

    /// The element itself or its nearest ancestor that matches, looking at most `maximumDepth` levels up.
    static func firstAncestorOrSelf(of accessibilityElement: AXUIElement, maximumDepth: Int = maximumAncestorWalkDepth,
                                    where matches: (AXUIElement) -> Bool) -> AXUIElement? {
        var currentElement: AXUIElement? = accessibilityElement
        for _ in 0..<maximumDepth {
            guard let element = currentElement else { return nil }
            if matches(element) { return element }
            currentElement = elementAttribute(kAXParentAttribute, of: element)
        }
        return nil
    }

    /// Breadth-first from the root itself, stopping at the first match. Capped, because a web window can hold tens of
    /// thousands of nodes.
    static func firstElementInSubtree(of rootElement: AXUIElement,
                                      maximumVisitedNodeCount: Int = maximumSubtreeSearchNodeCount,
                                      where matches: (AXUIElement) -> Bool) -> AXUIElement? {
        var pendingElements = [rootElement]
        var visitedNodeCount = 0
        while !pendingElements.isEmpty, visitedNodeCount < maximumVisitedNodeCount {
            let element = pendingElements.removeFirst()
            visitedNodeCount += 1
            if matches(element) { return element }
            pendingElements.append(contentsOf: elementArrayAttribute(kAXChildrenAttribute, of: element))
        }
        return nil
    }
}
