import Foundation

enum InputActionKind: Equatable, Sendable {
    case click(AgentClickType), typeText, pressKey(hasCommandModifier: Bool), scroll, clickScreenshotPoint, uploadFiles
}

struct InputTierPlanningRequest: Equatable, Sendable {
    var actionKind: InputActionKind
    var applicationKind: TargetApplicationKind
    /// nil for focused-element typing, keys and click_point.
    var elementTraits: ElementInputTraits?
    var capabilities: PrivateWindowServerCapabilities
    var enhancedUserInterfaceIsActive: Bool
    var windowIdentifierIsKnown: Bool
    /// True only inside the bring-forward assist.
    var targetIsFrontmost: Bool
    /// The Chromium/Electron authenticated key path stays off until live checks show it leaves the user's front
    /// window focus alone.
    var windowServerKeyboardEventsAreApproved: Bool = false
    /// The app already dropped a value Dotto set directly when the field committed, so for the rest of the task its
    /// text goes in only as real keys: in the background when the app takes them, otherwise through the assist.
    var accessibilityValueTypingIsUnreliable: Bool = false
}

enum InputTierPlanner {
    /// Ordered tiers that never take focus (or, inside the assist, that rely on the target already being in front).
    /// An empty list means "the assist or nothing". Uploads always get an empty list: they have their own assist flow.
    static func backgroundTiers(for request: InputTierPlanningRequest) -> [InputDeliveryTier] {
        let isChromiumFamily = request.applicationKind == .chromiumBrowser || request.applicationKind == .electron
        let targetIsFrontmost = request.targetIsFrontmost
        let windowServerKeyboardIsUsable = request.windowServerKeyboardEventsAreApproved
            && request.capabilities.canPostEventsThroughWindowServer && request.capabilities.canAuthenticateKeyboardEvents
        // Chromium and Electron drop plain per-process keys while in the background.
        let keyboardTiers: [InputDeliveryTier] = isChromiumFamily
            ? (windowServerKeyboardIsUsable ? [.windowServerKeyboardEvents] : []) + (targetIsFrontmost ? [.processKeyboardEvents] : [])
            : [.processKeyboardEvents]
        let pointerTiers: [InputDeliveryTier] = targetIsFrontmost && request.windowIdentifierIsKnown ? [.processPointerEvents] : []
        let elementTraits = request.elementTraits

        var plannedTiers: [InputDeliveryTier]
        switch request.actionKind {
        case .uploadFiles:
            return []
        case .clickScreenshotPoint:
            plannedTiers = pointerTiers
        case .click(let clickType):
            let elementOffersMatchingAction = switch clickType {
            case .single: elementTraits?.supportsPressAction == true
            case .right: elementTraits?.supportsShowMenuAction == true
            case .double: false
            }
            // Chromium ignores AXPress until AXEnhancedUserInterface is on; in front, the pointer tier backs it up.
            let accessibilityActionIsReliable = request.applicationKind != .chromiumBrowser
                || request.enhancedUserInterfaceIsActive || targetIsFrontmost
            // A context menu (AXShowMenu), pop-up button or menu button opens its menu over the user's own work and
            // takes the keyboard from it (LIVE L-F2, L-F3), so it only opens with the target in front: the assist.
            let actionOpensMenu = clickType == .right || elementTraits?.opensMenuWhenPressed == true
            let accessibilityActionMayRunNow = !actionOpensMenu || targetIsFrontmost
            let usesAccessibilityAction = elementOffersMatchingAction && accessibilityActionIsReliable && accessibilityActionMayRunNow
            plannedTiers = (usesAccessibilityAction ? [.accessibilityAction] : []) + pointerTiers
        case .scroll:
            let scrollBarCanBeSet = elementTraits?.hasSettableScrollBar == true && !isChromiumFamily
            plannedTiers = (scrollBarCanBeSet ? [.accessibilityValue] : []) + pointerTiers
        case .pressKey(let hasCommandModifier):
            // A ⌘ shortcut runs through its menu item: posting the chord would need focus. In front, plain keys work,
            // and menu shortcuts go without the authentication envelope.
            plannedTiers = hasCommandModifier
                ? [.accessibilityAction] + (targetIsFrontmost ? [.processKeyboardEvents] : [])
                : keyboardTiers
        case .typeText:
            guard let elementTraits else {
                plannedTiers = keyboardTiers
                break
            }
            let valueTiers: [InputDeliveryTier] = elementTraits.isValueSettable && !request.accessibilityValueTypingIsUnreliable
                ? [.accessibilityValue] : []
            if elementTraits.isInsideWebArea && elementTraits.isSingleLineTextInput {
                plannedTiers = valueTiers + keyboardTiers   // setting AXValue fires input and change events
            } else if !elementTraits.isInsideWebArea {
                plannedTiers = keyboardTiers + valueTiers
            } else {
                plannedTiers = keyboardTiers                // textarea and contenteditable need key events
            }
        }
        var uniqueTiers: [InputDeliveryTier] = []
        for plannedTier in plannedTiers where !uniqueTiers.contains(plannedTier) { uniqueTiers.append(plannedTier) }
        return uniqueTiers
    }

    /// Posted events and menu presses can report success without arriving: a background app has no key window,
    /// so menu items that act on the focused view (Select All, Bold, Copy) do nothing (LIVE L-T3). Those count only
    /// once a visible change is seen. AX actions and values on the element itself, and typing (which is read back),
    /// confirm themselves.
    static func deliveryConfirmation(for tier: InputDeliveryTier, actionKind: InputActionKind,
                                     targetIsFrontmost: Bool) -> DeliveryConfirmation {
        let needsVisibleChange: Bool
        switch tier {
        case .accessibilityValue:
            needsVisibleChange = false
        case .accessibilityAction:
            if case .pressKey = actionKind { needsVisibleChange = true } else { needsVisibleChange = false }
        case .processKeyboardEvents, .windowServerKeyboardEvents:
            needsVisibleChange = actionKind != .typeText
        case .processPointerEvents:
            needsVisibleChange = true
        }
        guard needsVisibleChange else { return .tierConfirmsItself }
        return targetIsFrontmost ? .visibleChangeNoted : .visibleChangeRequired
    }

    static func keyboardRoute(for tier: InputDeliveryTier) -> KeyboardEventRoute? {
        switch tier {
        case .processKeyboardEvents: return .processEvents
        case .windowServerKeyboardEvents: return .windowServerAuthenticated
        case .accessibilityAction, .accessibilityValue, .processPointerEvents: return nil
        }
    }
}

enum MenuShortcutMatcher {
    /// AXMenuItemCmdModifiers mask: 0 = ⌘ only; bit 0 (1) ⇧, bit 1 (2) ⌥, bit 2 (4) ⌃, bit 3 (8) no ⌘.
    static func menuItem(commandCharacter: String?, commandModifierMask: Int?,
                         matchesKeyName keyName: String, modifiers: [AgentKeyModifier]) -> Bool {
        guard let commandCharacter, !commandCharacter.isEmpty,
              SafetyGate.canonicalKeyName(commandCharacter) == SafetyGate.canonicalKeyName(keyName) else { return false }
        let modifierMask = commandModifierMask ?? 0
        var menuItemModifiers: Set<AgentKeyModifier> = modifierMask & 8 == 0 ? [.command] : []
        if modifierMask & 1 != 0 { menuItemModifiers.insert(.shift) }
        if modifierMask & 2 != 0 { menuItemModifiers.insert(.option) }
        if modifierMask & 4 != 0 { menuItemModifiers.insert(.control) }
        return menuItemModifiers == Set(modifiers)
    }
}
