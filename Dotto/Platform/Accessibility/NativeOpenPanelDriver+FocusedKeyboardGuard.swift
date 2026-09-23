import AppKit
import ApplicationServices

/// Reads what Core's FocusedKeyboardInputGuard decides on, right before every focused key or chunk.
extension NativeOpenPanelDriver {
    /// Where the next focused keys must land, checked through Accessibility before each chunk.
    enum ExpectedKeyboardFocus {
        case fileListInsidePanel
        case goToFolderField(AXUIElement)
    }

    private static let openPanelServiceBundleIdentifier = "com.apple.appkit.xpc.openAndSavePanelService"

    func verifyFocusedKeyboardInputIsSafe(openPanel: AXUIElement, targetApplication: TargetApplicationReference,
                                          owningPanelServiceProcessIdentifiers: Set<pid_t>,
                                          expectedKeyboardFocus: ExpectedKeyboardFocus,
                                          realUserInputCountAtAssistStart: Int?, abortSignal: TaskAbortSignal) async throws {
        let (foregroundAssistIsActive, frontmostProcessIdentifier) = await MainActor.run {
            (ForegroundAssistSession.isRunning, NSWorkspace.shared.frontmostApplication?.processIdentifier)
        }
        let keyboardFocusIsExpected = Self.openPanelWindowIsFocused(openPanel, of: targetApplication)
            && Self.keyboardFocus(of: targetApplication, matches: expectedKeyboardFocus, openPanel: openPanel,
                                  owningPanelServiceProcessIdentifiers: owningPanelServiceProcessIdentifiers)
        let conditions = FocusedKeyboardInputConditions(
            foregroundAssistIsActive: foregroundAssistIsActive, runIsAborted: abortSignal.isAborted,
            targetProcessIdentifier: targetApplication.processIdentifier, frontmostProcessIdentifier: frontmostProcessIdentifier,
            openPanelServiceProcessIdentifiers: owningPanelServiceProcessIdentifiers,
            openPanelIsKeyWindow: keyboardFocusIsExpected,
            realUserInputCountAtAssistStart: realUserInputCountAtAssistStart, realUserInputCountNow: realUserInputCounter.currentCount)
        switch FocusedKeyboardInputGuard.decision(for: conditions) {
        case .post:
            return
        case .refuse(.runStopped):
            throw ActionBackendError.aborted
        case .refuse(let refusal):
            throw ActionBackendError.foregroundAssistFailed(refusal.reasonForModel)
        }
    }

    /// The panel still exists and its window (the panel itself, or the document window a sheet hangs on) is the
    /// app's focused window.
    private static func openPanelWindowIsFocused(_ openPanel: AXUIElement, of targetApplication: TargetApplicationReference) -> Bool {
        guard let openPanelRole = AccessibilityElementReader.role(of: openPanel) else { return false }
        let applicationElement = AccessibilityElementReader.makeApplicationElement(for: targetApplication.processIdentifier)
        guard let focusedWindow = AccessibilityElementReader.elementAttribute(kAXFocusedWindowAttribute, of: applicationElement),
              let openPanelWindow = openPanelRole == kAXWindowRole
                ? openPanel : AccessibilityElementReader.elementAttribute(kAXWindowAttribute, of: openPanel)
                    ?? AccessibilityElementReader.elementAttribute(kAXParentAttribute, of: openPanel) else { return false }
        return CFEqual(focusedWindow, openPanelWindow)
    }

    /// A focus Accessibility can't report refuses. Focus held by another process counts only when it is the panel
    /// service drawing this panel, which shows nothing but the panel.
    private static func keyboardFocus(of targetApplication: TargetApplicationReference, matches expectedKeyboardFocus: ExpectedKeyboardFocus,
                                      openPanel: AXUIElement, owningPanelServiceProcessIdentifiers: Set<pid_t>) -> Bool {
        let applicationElement = AccessibilityElementReader.makeApplicationElement(for: targetApplication.processIdentifier)
        guard let focusedElement = AccessibilityElementReader.elementAttribute(kAXFocusedUIElementAttribute, of: applicationElement),
              let focusedElementProcessIdentifier = AccessibilityElementReader.processIdentifier(of: focusedElement) else {
            return false
        }
        let focusIsInTargetOrItsPanelService = focusedElementProcessIdentifier == targetApplication.processIdentifier
            || owningPanelServiceProcessIdentifiers.contains(focusedElementProcessIdentifier)
        guard focusIsInTargetOrItsPanelService else { return false }
        switch expectedKeyboardFocus {
        case .fileListInsidePanel:
            let focusedRole = AccessibilityElementReader.role(of: focusedElement) ?? ""
            guard !textEntryRoles.contains(focusedRole) else { return false }
            return owningPanelServiceProcessIdentifiers.contains(focusedElementProcessIdentifier)
                || isInside(focusedElement, openPanel: openPanel)
        case .goToFolderField(let goToFolderField):
            return CFEqual(focusedElement, goToFolderField)
                || (goToFolderFieldHasKeyboardFocus(goToFolderField) && textEntryRoles.contains(AccessibilityElementReader.role(of: focusedElement) ?? ""))
        }
    }

    static func keyboardFocus(of targetApplication: TargetApplicationReference, isOnFileListOf openPanel: AXUIElement) -> Bool {
        let applicationElement = AccessibilityElementReader.makeApplicationElement(for: targetApplication.processIdentifier)
        guard let focusedElement = AccessibilityElementReader.elementAttribute(kAXFocusedUIElementAttribute, of: applicationElement),
              let focusedRole = AccessibilityElementReader.role(of: focusedElement), !textEntryRoles.contains(focusedRole) else {
            return false
        }
        return isInside(focusedElement, openPanel: openPanel)
    }

    static func goToFolderFieldHasKeyboardFocus(_ goToFolderField: AXUIElement) -> Bool {
        AccessibilityElementReader.boolAttribute(kAXFocusedAttribute, of: goToFolderField) == true
    }

    private static func isInside(_ element: AXUIElement, openPanel: AXUIElement) -> Bool {
        AccessibilityElementReader.firstAncestorOrSelf(of: element) { CFEqual($0, openPanel) } != nil
    }

    /// A sandboxed app's panel content is served by the open-and-save panel service; its elements report that
    /// service's pid. Only a service process whose elements sit inside this panel is accepted.
    static func panelServiceProcessIdentifiers(drawing openPanel: AXUIElement,
                                               targetApplication: TargetApplicationReference) -> Set<pid_t> {
        let runningPanelServiceProcessIdentifiers = Set(
            NSRunningApplication.runningApplications(withBundleIdentifier: openPanelServiceBundleIdentifier).map(\.processIdentifier))
        guard !runningPanelServiceProcessIdentifiers.isEmpty else { return [] }
        let panelServiceElement = firstPanelElement(in: openPanel) { panelElement in
            guard let elementProcessIdentifier = AccessibilityElementReader.processIdentifier(of: panelElement) else { return false }
            return elementProcessIdentifier != targetApplication.processIdentifier
                && runningPanelServiceProcessIdentifiers.contains(elementProcessIdentifier)
        }
        guard let panelServiceElement,
              let panelServiceProcessIdentifier = AccessibilityElementReader.processIdentifier(of: panelServiceElement) else { return [] }
        return [panelServiceProcessIdentifier]
    }
}
