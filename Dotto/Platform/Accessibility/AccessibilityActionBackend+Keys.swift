import AppKit
import ApplicationServices

struct PressedMenuItem {
    var title: String
    /// The press call timed out or failed generically, so it may have acted (see AccessibilityActionAttemptResult).
    var applicationDidNotAnswer: Bool
}

private enum MenuItemPressInterruption: Error {
    case noMenuItemAcceptedThePress
    case applicationDidNotAnswer
}

extension AccessibilityActionBackend {
    func pressKey(_ keyName: String, modifiers: [AgentKeyModifier], context: ActionRunContext) async throws -> ActionOutcome {
        try await pressKeyReportingChange(keyName, modifiers: modifiers, changeFingerprintElement: nil, context: context).outcome
    }

    /// The change note is empty when a change was seen (or the tier confirms itself), and says why otherwise.
    func pressKeyReportingChange(_ keyName: String, modifiers: [AgentKeyModifier], changeFingerprintElement: AXUIElement?,
                                 context: ActionRunContext) async throws -> (outcome: ActionOutcome, changeNote: String) {
        let shortcutDescription = (modifiers.map(\.rawValue) + [keyName]).joined(separator: "+")
        guard let keyStroke = inputSynthesizer.resolveKeyStroke(forKeyName: keyName) else {
            throw ActionBackendError.unknownKeyName(keyName)
        }
        let effectiveModifiers = modifiers + keyStroke.requiredModifiers.filter { !modifiers.contains($0) }
        // Before any tier, so a blocked chord is never even looked up in the menu.
        if TargetApplicationPolicy.isBlockedSystemShortcut(keyName: keyName, modifiers: effectiveModifiers) {
            throw ActionBackendError.elementNotActionable(
                "\(shortcutDescription) switches apps, hides/quits apps or controls the system, so Dotto never sends it. "
                    + "Stay inside \(context.targetApplication.applicationName).")
        }
        let pressKeyActionKind = InputActionKind.pressKey(hasCommandModifier: effectiveModifiers.contains(.command))
        let deliveryTiers = planTiers(for: pressKeyActionKind, elementTraits: nil, context: context)
        for deliveryTier in deliveryTiers {
            try await ensureReadyForInput(context)
            switch deliveryTier {
            case .accessibilityAction:
                guard hasMatchingMenuItem(keyName: keyName, modifiers: effectiveModifiers, context: context) else { continue }
                var pressedMenuItem: PressedMenuItem?
                let menuPressConfirmation = InputTierPlanner.deliveryConfirmation(
                    for: .accessibilityAction, actionKind: pressKeyActionKind, targetIsFrontmost: context.targetIsFrontmost)
                let changeNote: String
                do {
                    changeNote = try await performConfirmingChange(targetElement: changeFingerprintElement,
                                                                   confirmation: menuPressConfirmation, context: context) {
                        pressedMenuItem = try self.pressMatchingMenuItem(keyName: keyName, modifiers: effectiveModifiers, context: context)
                        // Nothing was pressed, so the next tier may try; an unanswered press may have acted, so it may not.
                        guard let pressedMenuItem else { throw MenuItemPressInterruption.noMenuItemAcceptedThePress }
                        if pressedMenuItem.applicationDidNotAnswer { throw MenuItemPressInterruption.applicationDidNotAnswer }
                    }
                } catch MenuItemPressInterruption.noMenuItemAcceptedThePress {
                    continue
                } catch MenuItemPressInterruption.applicationDidNotAnswer {
                    let unansweredNote = Self.mayHaveActedNoteForModel(applicationName: context.targetApplication.applicationName)
                    return (Self.menuItemPressOutcome(shortcutDescription: shortcutDescription, menuItemTitle: pressedMenuItem?.title ?? keyName,
                                                      changeNote: unansweredNote), unansweredNote)
                }
                return (Self.menuItemPressOutcome(shortcutDescription: shortcutDescription, menuItemTitle: pressedMenuItem?.title ?? keyName,
                                                  changeNote: changeNote), changeNote)
            case .processKeyboardEvents, .windowServerKeyboardEvents:
                guard let keyboardRoute = InputTierPlanner.keyboardRoute(for: deliveryTier) else { continue }
                if Self.secureKeyboardEntryBlocksTyping(into: context.targetApplication.processIdentifier)
                    || elementReader.applicationFocusedElement(of: context.targetApplication).map(elementReader.isSecureTextField) == true {
                    throw ActionBackendError.secureFieldTypingDenied
                }
                let targetProcessPin = try makeTargetProcessPin(context)
                let keyPressConfirmation = InputTierPlanner.deliveryConfirmation(
                    for: deliveryTier, actionKind: pressKeyActionKind, targetIsFrontmost: context.targetIsFrontmost)
                let changeNote = try await performConfirmingChange(targetElement: changeFingerprintElement,
                                                                   confirmation: keyPressConfirmation, context: context) {
                    try self.inputSynthesizer.postKeyPress(virtualKeyCode: keyStroke.virtualKeyCode, modifiers: effectiveModifiers,
                                                           to: targetProcessPin, route: keyboardRoute, abortSignal: context.abortSignal)
                }
                return (ActionOutcome(descriptionForModel: "pressed \(shortcutDescription)\(changeNote)", deliveryTier: deliveryTier,
                                      noVisibleChangeWasSeen: changeNote == ActionOutcome.noVisibleChangeNote),
                        changeNote)
            case .accessibilityValue, .processPointerEvents:
                continue
            }
        }
        throw ActionBackendError.inputNotDelivered(
            "\(shortcutDescription) has no menu item in \(context.targetApplication.applicationName) and only works with the app in front.",
            foregroundAssistMayHelp: !context.targetIsFrontmost)
    }

    private static func menuItemPressOutcome(shortcutDescription: String, menuItemTitle: String, changeNote: String) -> ActionOutcome {
        ActionOutcome(descriptionForModel: "pressed \(shortcutDescription) (menu item “\(menuItemTitle.prefix(60))”)\(changeNote)",
                      deliveryTier: .accessibilityAction, noVisibleChangeWasSeen: changeNote == ActionOutcome.noVisibleChangeNote)
    }

    private func matchingMenuItems(keyName: String, modifiers: [AgentKeyModifier],
                                   context: ActionRunContext) -> [MenuItemWithCommandCharacter] {
        menuItemsWithCommandCharacters(of: context.targetApplication).filter { menuItem in
            MenuShortcutMatcher.menuItem(commandCharacter: menuItem.commandCharacter, commandModifierMask: menuItem.commandModifierMask,
                                         matchesKeyName: keyName, modifiers: modifiers)
        }
    }

    func hasMatchingMenuItem(keyName: String, modifiers: [AgentKeyModifier], context: ActionRunContext) -> Bool {
        !matchingMenuItems(keyName: keyName, modifiers: modifiers, context: context).isEmpty
    }

    /// Presses the first menu item whose key equivalent is exactly this chord. Returns it, or nil when no menu item
    /// matches (or every match refused the press). A press the app didn't answer stops the search: it may have acted.
    /// Callers confirm the effect: AXEnabled can't be trusted here, because validation may not have finished when it
    /// is read.
    func pressMatchingMenuItem(keyName: String, modifiers: [AgentKeyModifier], context: ActionRunContext) throws -> PressedMenuItem? {
        for matchingMenuItem in matchingMenuItems(keyName: keyName, modifiers: modifiers, context: context) {
            // A closed menu of a background app is never validated, and a press on an unvalidated item finds no
            // target. Reading the parent menu's children makes the app validate it, as opening the menu would.
            if let parentMenu = AccessibilityElementReader.elementAttribute(kAXParentAttribute, of: matchingMenuItem.element) {
                _ = AccessibilityElementReader.elementArrayAttribute(kAXChildrenAttribute, of: parentMenu)
            }
            try throwIfRunEnded(context)
            let menuItemTitle = AccessibilityElementReader.stringAttribute(kAXTitleAttribute, of: matchingMenuItem.element) ?? keyName
            switch try inputSynthesizer.attemptAccessibilityAction(kAXPressAction, on: matchingMenuItem.element,
                                                                   abortSignal: context.abortSignal) {
            case .performed:
                return PressedMenuItem(title: menuItemTitle, applicationDidNotAnswer: false)
            case .mayHaveActed:
                return PressedMenuItem(title: menuItemTitle, applicationDidNotAnswer: true)
            case .refused(let refusalError):
                // A menu item that no longer exists means the menus changed since they were read.
                if refusalError == .invalidUIElement { cachedMenuItems = nil }
                continue
            }
        }
        try context.abortSignal.throwIfAborted()
        return nil
    }
}
