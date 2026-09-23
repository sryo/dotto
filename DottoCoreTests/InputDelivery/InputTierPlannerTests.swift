import Foundation

private let allCapabilities = PrivateWindowServerCapabilities(canPostEventsThroughWindowServer: true, canAuthenticateKeyboardEvents: true,
                                                              canResolveWindowOfAccessibilityElement: true,
                                                              canKeepRemoteAccessibilityTreeAlive: true)

private func traits(press: Bool = false, showMenu: Bool = false, web: Bool = false, singleLine: Bool = false,
                    settable: Bool = false, scrollBar: Bool = false, opensMenu: Bool = false) -> ElementInputTraits {
    ElementInputTraits(supportsPressAction: press, supportsShowMenuAction: showMenu, isInsideWebArea: web,
                       isSingleLineTextInput: singleLine, isValueSettable: settable, hasSettableScrollBar: scrollBar,
                       opensMenuWhenPressed: opensMenu)
}

private func plannedTiers(_ actionKind: InputActionKind, _ applicationKind: TargetApplicationKind, _ elementTraits: ElementInputTraits? = nil,
                          capabilities: PrivateWindowServerCapabilities = allCapabilities, enhancedUserInterfaceIsActive: Bool = true,
                          windowIdentifierIsKnown: Bool = true, targetIsFrontmost: Bool = false,
                          windowServerKeyboardApproved: Bool = true) -> [InputDeliveryTier] {
    InputTierPlanner.backgroundTiers(for: InputTierPlanningRequest(
        actionKind: actionKind, applicationKind: applicationKind, elementTraits: elementTraits, capabilities: capabilities,
        enhancedUserInterfaceIsActive: enhancedUserInterfaceIsActive, windowIdentifierIsKnown: windowIdentifierIsKnown,
        targetIsFrontmost: targetIsFrontmost, windowServerKeyboardEventsAreApproved: windowServerKeyboardApproved))
}

let inputTierPlannerTestSuite = CoreTestSuite(name: "InputTierPlanner", testCases: [
    CoreTestCase(name: "clicks: AXPress in the background, nothing for pixel-only clicks") {
        for applicationKind in [TargetApplicationKind.cocoa, .chromiumBrowser, .electron, .webKitBrowser] {
            try expectEqual(plannedTiers(.click(.single), applicationKind, traits(press: true)), [.accessibilityAction], applicationKind.rawValue)
            try expectEqual(plannedTiers(.click(.single), applicationKind, traits()), [], applicationKind.rawValue)
            try expectEqual(plannedTiers(.click(.double), applicationKind, traits(press: true)), [], applicationKind.rawValue)
            try expectEqual(plannedTiers(.click(.right), applicationKind, traits(press: true)), [], applicationKind.rawValue)
            try expectEqual(plannedTiers(.clickScreenshotPoint, applicationKind), [], applicationKind.rawValue)
        }
    },
    CoreTestCase(name: "type_text: web single-line inputs set the value first, native fields type first") {
        try expectEqual(plannedTiers(.typeText, .cocoa, traits(web: true, singleLine: true, settable: true)), [.accessibilityValue, .processKeyboardEvents])
        try expectEqual(plannedTiers(.typeText, .chromiumBrowser, traits(web: true, singleLine: true, settable: true)),
                        [.accessibilityValue, .windowServerKeyboardEvents])
        try expectEqual(plannedTiers(.typeText, .webKitBrowser, traits(web: true, singleLine: true, settable: true)),
                        [.accessibilityValue, .processKeyboardEvents])
        try expectEqual(plannedTiers(.typeText, .cocoa, traits(settable: true)), [.processKeyboardEvents, .accessibilityValue])
        try expectEqual(plannedTiers(.typeText, .electron, traits(settable: true)), [.windowServerKeyboardEvents, .accessibilityValue])
        try expectEqual(plannedTiers(.typeText, .webKitBrowser, traits(settable: true)), [.processKeyboardEvents, .accessibilityValue])
    },
    CoreTestCase(name: "type_text: textareas, contenteditable and the focused element use keys only") {
        try expectEqual(plannedTiers(.typeText, .cocoa, traits(web: true, settable: true)), [.processKeyboardEvents])
        try expectEqual(plannedTiers(.typeText, .chromiumBrowser, traits(web: true, settable: true)), [.windowServerKeyboardEvents])
        try expectEqual(plannedTiers(.typeText, .webKitBrowser, traits(web: true)), [.processKeyboardEvents])
        try expectEqual(plannedTiers(.typeText, .cocoa, nil), [.processKeyboardEvents])
        try expectEqual(plannedTiers(.typeText, .cocoa, traits(settable: false)), [.processKeyboardEvents])
    },
    CoreTestCase(name: "press_key: plain keys go per process (authenticated for Chromium), ⌘ keys through the menu") {
        try expectEqual(plannedTiers(.pressKey(hasCommandModifier: false), .cocoa), [.processKeyboardEvents])
        try expectEqual(plannedTiers(.pressKey(hasCommandModifier: false), .chromiumBrowser), [.windowServerKeyboardEvents])
        try expectEqual(plannedTiers(.pressKey(hasCommandModifier: false), .webKitBrowser), [.processKeyboardEvents])
        for applicationKind in [TargetApplicationKind.cocoa, .chromiumBrowser, .electron, .webKitBrowser] {
            try expectEqual(plannedTiers(.pressKey(hasCommandModifier: true), applicationKind), [.accessibilityAction], applicationKind.rawValue)
        }
    },
    CoreTestCase(name: "scroll: a settable scroll bar outside Chromium, otherwise nothing in the background") {
        try expectEqual(plannedTiers(.scroll, .cocoa, traits(scrollBar: true)), [.accessibilityValue])
        try expectEqual(plannedTiers(.scroll, .webKitBrowser, traits(scrollBar: true)), [.accessibilityValue])
        try expectEqual(plannedTiers(.scroll, .chromiumBrowser, traits(scrollBar: true)), [])
        try expectEqual(plannedTiers(.scroll, .cocoa, traits()), [])
    },
    CoreTestCase(name: "uploads always get an empty list, in the background and in front") {
        try expectEqual(plannedTiers(.uploadFiles, .cocoa, traits(press: true)), [])
        try expectEqual(plannedTiers(.uploadFiles, .chromiumBrowser, traits(press: true), targetIsFrontmost: true), [])
    },
    CoreTestCase(name: "Chromium drops AXPress without verified EUI, but not inside the assist; Electron keeps it") {
        try expectEqual(plannedTiers(.click(.single), .chromiumBrowser, traits(press: true), enhancedUserInterfaceIsActive: false), [])
        try expectEqual(plannedTiers(.click(.single), .chromiumBrowser, traits(press: true), enhancedUserInterfaceIsActive: false,
                                     targetIsFrontmost: true), [.accessibilityAction, .processPointerEvents])
        try expectEqual(plannedTiers(.click(.single), .electron, traits(press: true), enhancedUserInterfaceIsActive: false), [.accessibilityAction])
    },
    CoreTestCase(name: "the authenticated key tier needs its capabilities and the approval flag") {
        let withoutAuthentication = PrivateWindowServerCapabilities(canPostEventsThroughWindowServer: true, canAuthenticateKeyboardEvents: false,
                                                                     canResolveWindowOfAccessibilityElement: true,
                                                                     canKeepRemoteAccessibilityTreeAlive: true)
        let withoutPosting = PrivateWindowServerCapabilities(canPostEventsThroughWindowServer: false, canAuthenticateKeyboardEvents: true,
                                                              canResolveWindowOfAccessibilityElement: true,
                                                              canKeepRemoteAccessibilityTreeAlive: true)
        try expectEqual(plannedTiers(.pressKey(hasCommandModifier: false), .chromiumBrowser, capabilities: withoutAuthentication), [])
        try expectEqual(plannedTiers(.pressKey(hasCommandModifier: false), .chromiumBrowser, capabilities: withoutPosting), [])
        try expectEqual(plannedTiers(.pressKey(hasCommandModifier: false), .chromiumBrowser, windowServerKeyboardApproved: false), [])
        try expectEqual(plannedTiers(.typeText, .chromiumBrowser, traits(web: true, singleLine: true, settable: true),
                                     windowServerKeyboardApproved: false), [.accessibilityValue])
        // Cocoa never needs the window server for keys.
        try expectEqual(plannedTiers(.pressKey(hasCommandModifier: false), .cocoa, capabilities: .none), [.processKeyboardEvents])
    },
    CoreTestCase(name: "inside the assist, pointer events back up clicks and scrolls and plain keys back up Chromium") {
        try expectEqual(plannedTiers(.click(.single), .cocoa, traits(press: true), targetIsFrontmost: true),
                        [.accessibilityAction, .processPointerEvents])
        try expectEqual(plannedTiers(.click(.double), .cocoa, traits(), targetIsFrontmost: true), [.processPointerEvents])
        try expectEqual(plannedTiers(.clickScreenshotPoint, .chromiumBrowser, targetIsFrontmost: true), [.processPointerEvents])
        try expectEqual(plannedTiers(.clickScreenshotPoint, .cocoa, windowIdentifierIsKnown: false, targetIsFrontmost: true), [])
        try expectEqual(plannedTiers(.scroll, .cocoa, traits(scrollBar: true), targetIsFrontmost: true),
                        [.accessibilityValue, .processPointerEvents])
        try expectEqual(plannedTiers(.pressKey(hasCommandModifier: false), .chromiumBrowser, targetIsFrontmost: true),
                        [.windowServerKeyboardEvents, .processKeyboardEvents])
        try expectEqual(plannedTiers(.pressKey(hasCommandModifier: false), .electron, targetIsFrontmost: true, windowServerKeyboardApproved: false),
                        [.processKeyboardEvents])
        try expectEqual(plannedTiers(.pressKey(hasCommandModifier: true), .chromiumBrowser, targetIsFrontmost: true),
                        [.accessibilityAction, .processKeyboardEvents])
    },
    CoreTestCase(name: "context menus, pop-up buttons and menu buttons only open in front (the assist)") {
        for applicationKind in [TargetApplicationKind.cocoa, .chromiumBrowser, .electron, .webKitBrowser] {
            try expectEqual(plannedTiers(.click(.right), applicationKind, traits(showMenu: true)), [], applicationKind.rawValue)
            try expectEqual(plannedTiers(.click(.single), applicationKind, traits(press: true, opensMenu: true)), [], applicationKind.rawValue)
            try expectEqual(plannedTiers(.click(.right), applicationKind, traits(showMenu: true), targetIsFrontmost: true),
                            [.accessibilityAction, .processPointerEvents], applicationKind.rawValue)
            try expectEqual(plannedTiers(.click(.single), applicationKind, traits(press: true, opensMenu: true), targetIsFrontmost: true),
                            [.accessibilityAction, .processPointerEvents], applicationKind.rawValue)
        }
        // Without a known window there is no pointer fallback, so a background menu button has no tier at all.
        try expectEqual(plannedTiers(.click(.single), .cocoa, traits(press: true, opensMenu: true), windowIdentifierIsKnown: false), [])
    },
    CoreTestCase(name: "menu presses, posted keys and pointer events need a visible change in the background") {
        let menuShortcut = InputActionKind.pressKey(hasCommandModifier: true)
        let plainKey = InputActionKind.pressKey(hasCommandModifier: false)
        try expectEqual(InputTierPlanner.deliveryConfirmation(for: .accessibilityAction, actionKind: menuShortcut, targetIsFrontmost: false),
                        .visibleChangeRequired)
        try expectEqual(InputTierPlanner.deliveryConfirmation(for: .processKeyboardEvents, actionKind: plainKey, targetIsFrontmost: false),
                        .visibleChangeRequired)
        try expectEqual(InputTierPlanner.deliveryConfirmation(for: .windowServerKeyboardEvents, actionKind: plainKey, targetIsFrontmost: false),
                        .visibleChangeRequired)
        try expectEqual(InputTierPlanner.deliveryConfirmation(for: .processPointerEvents, actionKind: .click(.single), targetIsFrontmost: false),
                        .visibleChangeRequired)
    },
    CoreTestCase(name: "in front a missing change is only noted; AX presses, values and typing confirm themselves") {
        let menuShortcut = InputActionKind.pressKey(hasCommandModifier: true)
        try expectEqual(InputTierPlanner.deliveryConfirmation(for: .accessibilityAction, actionKind: menuShortcut, targetIsFrontmost: true),
                        .visibleChangeNoted)
        try expectEqual(InputTierPlanner.deliveryConfirmation(for: .processPointerEvents, actionKind: .scroll, targetIsFrontmost: true),
                        .visibleChangeNoted)
        for targetIsFrontmost in [false, true] {
            try expectEqual(InputTierPlanner.deliveryConfirmation(for: .accessibilityAction, actionKind: .click(.single),
                                                                  targetIsFrontmost: targetIsFrontmost), .tierConfirmsItself)
            try expectEqual(InputTierPlanner.deliveryConfirmation(for: .accessibilityValue, actionKind: .typeText,
                                                                  targetIsFrontmost: targetIsFrontmost), .tierConfirmsItself)
            try expectEqual(InputTierPlanner.deliveryConfirmation(for: .processKeyboardEvents, actionKind: .typeText,
                                                                  targetIsFrontmost: targetIsFrontmost), .tierConfirmsItself)
        }
    },
    CoreTestCase(name: "keyboard routes: per process and authenticated; other tiers have none") {
        try expectEqual(InputTierPlanner.keyboardRoute(for: .processKeyboardEvents), .processEvents)
        try expectEqual(InputTierPlanner.keyboardRoute(for: .windowServerKeyboardEvents), .windowServerAuthenticated)
        try expectEqual(InputTierPlanner.keyboardRoute(for: .accessibilityAction), nil)
        try expectEqual(InputTierPlanner.keyboardRoute(for: .processPointerEvents), nil)
    },
    CoreTestCase(name: "capabilities describe themselves for the audit log") {
        try expectEqual(allCapabilities.auditDescription, "post=1 auth=1 window=1 remote=1")
        try expectEqual(PrivateWindowServerCapabilities.none.auditDescription, "post=0 auth=0 window=0 remote=0")
    },
])
