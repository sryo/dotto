import Foundation
import CoreGraphics

/// Which per-task Accessibility modes Dotto switches on for an app kind, and which notifications it listens to so the
/// app keeps its tree live while its window is covered.
struct AccessibilityModePolicy: Equatable, Sendable {
    var setsManualAccessibility: Bool
    var setsEnhancedUserInterface: Bool
    /// Chromium's Blink stops updating a covered window's tree unless it sees a remote-aware observer.
    var remoteObserverNotificationNames: [String]

    /// EUI makes some apps animate and move their windows, but without it Chromium ignores AXPress in web content.
    /// It stays on until a live check shows the remote-aware observer alone keeps web content pressable.
    static let chromiumNeedsEnhancedUserInterface = true
    static let focusedElementChangedNotificationName = "AXFocusedUIElementChanged"

    static let none = AccessibilityModePolicy(setsManualAccessibility: false, setsEnhancedUserInterface: false,
                                              remoteObserverNotificationNames: [])

    static func policy(for applicationKind: TargetApplicationKind,
                       canKeepRemoteAccessibilityTreeAlive: Bool) -> AccessibilityModePolicy {
        let remoteObserverNotificationNames = canKeepRemoteAccessibilityTreeAlive ? [focusedElementChangedNotificationName] : []
        switch applicationKind {
        case .cocoa, .webKitBrowser:
            return .none
        case .electron:
            return AccessibilityModePolicy(setsManualAccessibility: true, setsEnhancedUserInterface: false,
                                           remoteObserverNotificationNames: remoteObserverNotificationNames)
        case .chromiumBrowser:
            return AccessibilityModePolicy(setsManualAccessibility: true,
                                           setsEnhancedUserInterface: chromiumNeedsEnhancedUserInterface,
                                           remoteObserverNotificationNames: remoteObserverNotificationNames)
        }
    }
}
