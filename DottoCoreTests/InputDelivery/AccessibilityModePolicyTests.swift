import Foundation
import CoreGraphics

let accessibilityModePolicyTestSuite = CoreTestSuite(name: "AccessibilityModePolicy", testCases: [
    CoreTestCase(name: "native apps and Safari get no modes and no observer") {
        for applicationKind in [TargetApplicationKind.cocoa, .webKitBrowser] {
            try expectEqual(AccessibilityModePolicy.policy(for: applicationKind, canKeepRemoteAccessibilityTreeAlive: true), .none)
        }
    },
    CoreTestCase(name: "Chromium browsers and Electron both keep a covered tree live through the remote-aware observer") {
        let chromiumPolicy = AccessibilityModePolicy.policy(for: .chromiumBrowser, canKeepRemoteAccessibilityTreeAlive: true)
        try expectEqual(chromiumPolicy.setsManualAccessibility, true)
        try expectEqual(chromiumPolicy.setsEnhancedUserInterface, AccessibilityModePolicy.chromiumNeedsEnhancedUserInterface)
        try expectEqual(chromiumPolicy.remoteObserverNotificationNames, ["AXFocusedUIElementChanged"])
        let electronPolicy = AccessibilityModePolicy.policy(for: .electron, canKeepRemoteAccessibilityTreeAlive: true)
        try expectEqual(electronPolicy.setsManualAccessibility, true)
        try expectEqual(electronPolicy.setsEnhancedUserInterface, false)
        try expectEqual(electronPolicy.remoteObserverNotificationNames, ["AXFocusedUIElementChanged"])
    },
    CoreTestCase(name: "without the private observer symbol no notification is registered") {
        for applicationKind in [TargetApplicationKind.chromiumBrowser, .electron] {
            let policy = AccessibilityModePolicy.policy(for: applicationKind, canKeepRemoteAccessibilityTreeAlive: false)
            try expectEqual(policy.remoteObserverNotificationNames, [])
            try expectEqual(policy.setsManualAccessibility, true)
        }
    },
])
