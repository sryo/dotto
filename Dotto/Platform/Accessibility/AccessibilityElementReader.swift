import AppKit
import ApplicationServices

/// Walks an app's Accessibility tree into plain `AccessibilityElementNode` values and hands back the
/// live `AXUIElement` for every id so the action backend can act on exactly what the model saw.
final class AccessibilityElementReader {
    static let maximumAncestorWalkDepth = 40
    static let maximumRecordedAncestorCount = 12
    static let secureTextFieldSubrole = "AXSecureTextField"
    static let webAreaRole = "AXWebArea"
    static let webAreaAddressAttribute = "AXURL"
    private static let maximumStoredTextLength = 1000
    private static let wallClockCheckIntervalInNodes = 50
    /// Unresponsive apps would otherwise stall every AX call for the 6 s system default.
    private static let messagingTimeoutSeconds: Float = 1.5

    // AXValue is deliberately absent: it is read separately, and never for secure text fields.
    private static let batchedAttributeNames: [String] = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
        kAXPlaceholderValueAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXEnabledAttribute,
        kAXFocusedAttribute, kAXSelectedAttribute, kAXChildrenAttribute, kAXHelpAttribute, kAXIdentifierAttribute,
    ]

    struct TreeWalkProgress {
        var budget = ReadUserInterfaceBudget.budget(for: .cocoa)
        var windowFrameForPruning: CGRect?
        var walkStartUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        var rawNodeCount = 0
        var wallClockBudgetWasSpent = false
        var wasTruncated = false
        var elementReferencesByIdentifier: [String: AXUIElement] = [:]
        var applicationStoppedResponding = false
        var walkWasAborted = false
        var firstWebAreaElement: AXUIElement?
    }

    let systemWideElement = AXUIElementCreateSystemWide()

    init() {
        // Setting the timeout on the system-wide element changes the default for every element this process creates.
        AXUIElementSetMessagingTimeout(systemWideElement, Self.messagingTimeoutSeconds)
    }

    /// The one way Dotto makes an app element, so every one of them carries the short messaging timeout.
    static func makeApplicationElement(for processIdentifier: pid_t) -> AXUIElement {
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(applicationElement, messagingTimeoutSeconds)
        return applicationElement
    }

    /// The budget caps nodes, depth and wall-clock time. For web content, `windowFrameForPruning` lets the walk skip
    /// subtrees that sit far above or below the window (a 5,000-row page would otherwise take seconds).
    func readSnapshot(of application: TargetApplicationReference, scope: ReadUserInterfaceScope,
                      snapshotGeneration: Int, nextElementNumber: inout Int,
                      budget: ReadUserInterfaceBudget = .budget(for: .cocoa), windowFrameForPruning: CGRect? = nil,
                      shouldAbortWalk: () -> Bool)
        throws -> (snapshot: AccessibilityTreeSnapshot, elementReferencesByIdentifier: [String: AXUIElement]) {
        guard AXIsProcessTrusted() else { throw ActionBackendError.accessibilityPermissionMissing }
        let applicationElement = Self.makeApplicationElement(for: application.processIdentifier)

        let rootElements: [AXUIElement]
        switch scope {
        case .focusedWindow:
            guard let focusedWindow = Self.focusedWindowElement(ofApplicationElement: applicationElement) else {
                throw ActionBackendError.accessibilityCallFailed("\(application.applicationName) has no open window.")
            }
            rootElements = [focusedWindow]
        case .allWindows:
            rootElements = Self.elementArrayAttribute(kAXWindowsAttribute, of: applicationElement)
        case .menuBar:
            guard let menuBarElement = Self.elementAttribute(kAXMenuBarAttribute, of: applicationElement) else {
                throw ActionBackendError.accessibilityCallFailed("\(application.applicationName) has no menu bar.")
            }
            rootElements = [menuBarElement]
        }

        var treeWalkProgress = TreeWalkProgress()
        treeWalkProgress.budget = budget
        treeWalkProgress.windowFrameForPruning = budget.prunesWebContentFarOutsideWindow ? windowFrameForPruning : nil
        var rootNodes = rootElements.compactMap { rootElement in
            buildNode(from: rootElement, depth: 0, isInsideWebContent: false, nextElementNumber: &nextElementNumber,
                      treeWalkProgress: &treeWalkProgress, shouldAbortWalk: shouldAbortWalk)
        }
        if treeWalkProgress.walkWasAborted { throw ActionBackendError.aborted }
        if let focusedElement = Self.elementAttribute(kAXFocusedUIElementAttribute, of: applicationElement) {
            rootNodes = Self.markingKeyboardFocus(focusedElement, in: rootNodes,
                                                  elementReferencesByIdentifier: treeWalkProgress.elementReferencesByIdentifier)
        }
        if rootNodes.isEmpty && treeWalkProgress.applicationStoppedResponding {
            throw ActionBackendError.accessibilityCallFailed("\(application.applicationName) is not responding to Accessibility requests.")
        }
        let windowTitle = scope == .menuBar ? nil : rootNodes.first?.title
        var snapshot = AccessibilityTreeSnapshot(
            snapshotGeneration: snapshotGeneration, application: application, windowTitle: windowTitle, scope: scope,
            rootNodes: rootNodes, rawNodeCount: treeWalkProgress.rawNodeCount,
            wasTruncatedDuringRead: treeWalkProgress.wasTruncated)
        if scope == .focusedWindow, let focusedWindow = rootElements.first {
            snapshot.windowIsMinimized = Self.boolAttribute(kAXMinimizedAttribute, of: focusedWindow) == true
        }
        if scope != .menuBar {
            // Browsers leave AXDocument empty; their page URL lives on the web area instead.
            snapshot.focusedWindowDocument = rootElements.first.flatMap { Self.stringAttribute(kAXDocumentAttribute, of: $0) }
                ?? treeWalkProgress.firstWebAreaElement.flatMap { Self.stringAttribute(Self.webAreaAddressAttribute, of: $0) }
        }
        return (snapshot, treeWalkProgress.elementReferencesByIdentifier)
    }

    /// SafetyGate reads the snapshot's focused node to tell what Space or Return will activate. Per-element AXFocused
    /// is unreliable (stale in background windows, missing in some toolkits), so the app's AXFocusedUIElement decides:
    /// when it is in the outline it becomes the only focused node. Otherwise the per-element flags are left as read.
    private static func markingKeyboardFocus(_ focusedElement: AXUIElement, in rootNodes: [AccessibilityElementNode],
                                             elementReferencesByIdentifier: [String: AXUIElement]) -> [AccessibilityElementNode] {
        guard let focusedElementIdentifier = elementReferencesByIdentifier.first(where: { _, outlinedElement in
            CFEqual(outlinedElement, focusedElement)
        })?.key else { return rootNodes }
        func marking(_ node: AccessibilityElementNode) -> AccessibilityElementNode {
            var markedNode = node
            markedNode.isFocused = node.elementIdentifier == focusedElementIdentifier
            markedNode.children = node.children.map(marking)
            return markedNode
        }
        return rootNodes.map(marking)
    }

    // MARK: - Applications and windows

    /// The target app's own keyboard focus. Unlike the system-wide focused element, this is meaningful while the app
    /// is in the background, which is where Dotto types.
    func applicationFocusedElement(of application: TargetApplicationReference) -> AXUIElement? {
        Self.elementAttribute(kAXFocusedUIElementAttribute, of: Self.makeApplicationElement(for: application.processIdentifier))
    }

    func runningApplication(named applicationName: String) -> TargetApplicationReference? {
        let matchingApplication = NSWorkspace.shared.runningApplications.first { runningApplication in
            runningApplication.localizedName?.caseInsensitiveCompare(applicationName) == .orderedSame
        }
        guard let matchingApplication, let localizedName = matchingApplication.localizedName else { return nil }
        return TargetApplicationReference(processIdentifier: matchingApplication.processIdentifier,
                                          applicationName: localizedName,
                                          bundleIdentifier: matchingApplication.bundleIdentifier)
    }

    /// The window Dotto works in: AXFocusedWindow, then AXMainWindow, then the first window.
    func focusedWindowElement(of application: TargetApplicationReference) -> AXUIElement? {
        Self.focusedWindowElement(ofApplicationElement: Self.makeApplicationElement(for: application.processIdentifier))
    }

    func focusedWindowFrameInTopLeftGlobalPoints(of application: TargetApplicationReference) -> CGRect? {
        focusedWindowElement(of: application).flatMap(Self.frameInTopLeftGlobalPoints)
    }

    static func focusedWindowElement(ofApplicationElement applicationElement: AXUIElement) -> AXUIElement? {
        elementAttribute(kAXFocusedWindowAttribute, of: applicationElement)
            ?? elementAttribute(kAXMainWindowAttribute, of: applicationElement)
            ?? elementArrayAttribute(kAXWindowsAttribute, of: applicationElement).first
    }

    // MARK: - Tree walk

    func buildNode(from accessibilityElement: AXUIElement, depth: Int, isInsideWebContent: Bool, nextElementNumber: inout Int,
                   treeWalkProgress: inout TreeWalkProgress, shouldAbortWalk: () -> Bool) -> AccessibilityElementNode? {
        guard !treeWalkProgress.walkWasAborted, !treeWalkProgress.applicationStoppedResponding else { return nil }
        if shouldAbortWalk() {
            treeWalkProgress.walkWasAborted = true
            return nil
        }
        if treeWalkProgress.rawNodeCount % Self.wallClockCheckIntervalInNodes == 0 {
            let elapsedWalkSeconds = Double(DispatchTime.now().uptimeNanoseconds - treeWalkProgress.walkStartUptimeNanoseconds)
                / 1_000_000_000
            if elapsedWalkSeconds > treeWalkProgress.budget.maximumWalkSeconds { treeWalkProgress.wallClockBudgetWasSpent = true }
        }
        guard !treeWalkProgress.wallClockBudgetWasSpent,
              treeWalkProgress.rawNodeCount < treeWalkProgress.budget.maximumNodeCount else {
            treeWalkProgress.wasTruncated = true
            return nil
        }
        treeWalkProgress.rawNodeCount += 1

        var batchedValuesReference: CFArray?
        let batchReadResult = AXUIElementCopyMultipleAttributeValues(
            accessibilityElement, Self.batchedAttributeNames as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0),
            &batchedValuesReference)
        // One timeout means the app is busy or hung; every further call would wait the full timeout again.
        if batchReadResult == .cannotComplete {
            treeWalkProgress.applicationStoppedResponding = true
            treeWalkProgress.wasTruncated = true
            return nil
        }
        guard batchReadResult == .success, let batchedValues = batchedValuesReference as? [AnyObject],
              batchedValues.count == Self.batchedAttributeNames.count else { return nil }
        func batchedValue(_ attributeName: String) -> AnyObject? {
            guard let attributeIndex = Self.batchedAttributeNames.firstIndex(of: attributeName) else { return nil }
            return batchedValues[attributeIndex]
        }

        let role = Self.stringified(batchedValue(kAXRoleAttribute)) ?? "AXUnknown"
        let subrole = Self.stringified(batchedValue(kAXSubroleAttribute))
        // Some toolkits report the secure field as the role rather than the subrole (as isSecureTextField(_:) checks).
        let isSecureTextField = subrole == Self.secureTextFieldSubrole || role == Self.secureTextFieldSubrole
        let elementIdentifier = "e\(nextElementNumber)"
        nextElementNumber += 1
        treeWalkProgress.elementReferencesByIdentifier[elementIdentifier] = accessibilityElement
        if role == Self.webAreaRole, treeWalkProgress.firstWebAreaElement == nil {
            treeWalkProgress.firstWebAreaElement = accessibilityElement
        }

        var frameInTopLeftGlobalPoints: CGRect?
        if let position = Self.pointValue(batchedValue(kAXPositionAttribute)), let size = Self.sizeValue(batchedValue(kAXSizeAttribute)) {
            frameInTopLeftGlobalPoints = CGRect(origin: position, size: size)
        }

        let childrenAreInsideWebContent = isInsideWebContent || role == Self.webAreaRole
        var isPrunedAsFarOutsideWindow = false
        if isInsideWebContent, let windowFrameForPruning = treeWalkProgress.windowFrameForPruning, let frameInTopLeftGlobalPoints {
            isPrunedAsFarOutsideWindow = ReadUserInterfaceBudget.isFrameFarOutsideWindow(frameInTopLeftGlobalPoints,
                                                                                          windowFrame: windowFrameForPruning)
        }
        var childNodes: [AccessibilityElementNode] = []
        if isPrunedAsFarOutsideWindow {
            treeWalkProgress.wasTruncated = true
        } else if depth < treeWalkProgress.budget.maximumDepth {
            for childElement in Self.elements(from: batchedValue(kAXChildrenAttribute)) {
                if let childNode = buildNode(from: childElement, depth: depth + 1, isInsideWebContent: childrenAreInsideWebContent,
                                             nextElementNumber: &nextElementNumber, treeWalkProgress: &treeWalkProgress,
                                             shouldAbortWalk: shouldAbortWalk) {
                    childNodes.append(childNode)
                }
            }
        } else {
            treeWalkProgress.wasTruncated = true
        }

        return AccessibilityElementNode(
            elementIdentifier: elementIdentifier, role: role, subrole: subrole,
            title: Self.stringified(batchedValue(kAXTitleAttribute)),
            value: isSecureTextField ? nil : Self.stringAttribute(kAXValueAttribute, of: accessibilityElement),
            elementDescription: Self.stringified(batchedValue(kAXDescriptionAttribute)),
            placeholder: Self.stringified(batchedValue(kAXPlaceholderValueAttribute)),
            frameInTopLeftGlobalPoints: frameInTopLeftGlobalPoints,
            isEnabled: Self.boolValue(batchedValue(kAXEnabledAttribute)) ?? true,
            isFocused: Self.boolValue(batchedValue(kAXFocusedAttribute)) ?? false,
            isSelected: Self.boolValue(batchedValue(kAXSelectedAttribute)) ?? false,
            isSecureTextField: isSecureTextField,
            supportsPressAction: Self.actionNames(of: accessibilityElement).contains(kAXPressAction),
            children: childNodes,
            helpText: Self.stringified(batchedValue(kAXHelpAttribute)),
            accessibilityIdentifier: Self.stringified(batchedValue(kAXIdentifierAttribute)))
    }

    // MARK: - CF value conversion

    /// Text of a string, attributed string, URL or number, capped at the outline's length; nil for anything else.
    static func stringified(_ attributeValue: CFTypeRef?) -> String? {
        guard let attributeValue else { return nil }
        let text: String?
        if let stringValue = attributeValue as? String {
            text = stringValue
        } else if let attributedStringValue = attributeValue as? NSAttributedString {
            text = attributedStringValue.string
        } else if let urlValue = attributeValue as? URL {
            text = urlValue.absoluteString
        } else if CFGetTypeID(attributeValue) == CFBooleanGetTypeID() {
            text = nil
        } else if let numberValue = attributeValue as? NSNumber {
            text = "\(numberValue)"
        } else {
            // AXValue structs (points, ranges) and missing-attribute error markers carry no readable text.
            text = nil
        }
        guard let text, !text.isEmpty else { return nil }
        return String(text.prefix(maximumStoredTextLength))
    }

    static func elements(from attributeValue: CFTypeRef?) -> [AXUIElement] {
        guard let attributeValue, let candidateObjects = attributeValue as? [AnyObject] else { return [] }
        return candidateObjects.compactMap { candidateObject in
            CFGetTypeID(candidateObject) == AXUIElementGetTypeID() ? (candidateObject as! AXUIElement) : nil
        }
    }

    static func boolValue(_ attributeValue: CFTypeRef?) -> Bool? {
        guard let attributeValue, CFGetTypeID(attributeValue) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue((attributeValue as! CFBoolean))
    }

    static func pointValue(_ attributeValue: CFTypeRef?) -> CGPoint? {
        guard let attributeValue, CFGetTypeID(attributeValue) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(attributeValue as! AXValue, .cgPoint, &point) ? point : nil
    }

    static func rangeValue(_ attributeValue: CFTypeRef?) -> CFRange? {
        guard let attributeValue, CFGetTypeID(attributeValue) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(attributeValue as! AXValue, .cfRange, &range) ? range : nil
    }

    static func sizeValue(_ attributeValue: CFTypeRef?) -> CGSize? {
        guard let attributeValue, CFGetTypeID(attributeValue) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(attributeValue as! AXValue, .cgSize, &size) ? size : nil
    }
}
