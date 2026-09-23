import Foundation
import CoreGraphics

enum TargetApplicationKind: String, Codable, Equatable, Sendable { case cocoa, chromiumBrowser, electron, webKitBrowser }

/// Ways to deliver input to the target app without taking focus. The bring-forward assist is never a tier: it
/// happens only after the user approves it (ForegroundAssistingActionPerformer).
enum InputDeliveryTier: String, Codable, Equatable, Sendable {
    case accessibilityAction, accessibilityValue, processKeyboardEvents, windowServerKeyboardEvents
    /// Public per-process pointer events. Planned only while the target is frontmost inside the assist, because a
    /// background pixel click would need a focus change that can disturb the user's own window.
    case processPointerEvents
}

/// How a key event is posted to the target pid.
enum KeyboardEventRoute: Equatable, Sendable { case processEvents, windowServerAuthenticated }

struct PrivateWindowServerCapabilities: Equatable, Sendable {
    var canPostEventsThroughWindowServer: Bool       // SLEventPostToPid
    var canAuthenticateKeyboardEvents: Bool          // SLSEventAuthenticationMessage + SLEventSetAuthenticationMessage
    var canResolveWindowOfAccessibilityElement: Bool // _AXUIElementGetWindow
    var canKeepRemoteAccessibilityTreeAlive: Bool    // _AXObserverAddNotificationAndCheckRemote

    static let none = PrivateWindowServerCapabilities(canPostEventsThroughWindowServer: false, canAuthenticateKeyboardEvents: false,
                                                      canResolveWindowOfAccessibilityElement: false,
                                                      canKeepRemoteAccessibilityTreeAlive: false)

    /// e.g. "post=1 auth=1 window=1 remote=1".
    var auditDescription: String {
        [("post", canPostEventsThroughWindowServer), ("auth", canAuthenticateKeyboardEvents),
         ("window", canResolveWindowOfAccessibilityElement), ("remote", canKeepRemoteAccessibilityTreeAlive)]
            .map { "\($0.0)=\($0.1 ? 1 : 0)" }.joined(separator: " ")
    }
}

struct TargetWindowReference: Equatable, Sendable {
    var processIdentifier: Int32
    var windowIdentifier: UInt32
    var frameInTopLeftGlobalPoints: CGRect
}

struct ElementInputTraits: Equatable, Sendable {
    var supportsPressAction: Bool
    var supportsShowMenuAction: Bool
    var isInsideWebArea: Bool
    /// AXTextField, AXComboBox, AXSearchField (roles or subroles), never AXTextArea.
    var isSingleLineTextInput: Bool
    var isValueSettable: Bool
    var hasSettableScrollBar: Bool
    /// AXPopUpButton and AXMenuButton: pressing one opens a menu.
    var opensMenuWhenPressed: Bool = false
}

/// What makes a delivered input count as done.
enum DeliveryConfirmation: Equatable, Sendable {
    /// The tier's own result is trusted: an AX press or value on the element itself, or typing that is read back.
    case tierConfirmsItself
    /// Only a visible change counts. Without one the input is reported as not delivered, and the assist is offered.
    case visibleChangeRequired
    /// With the target in front there is nothing better to try, so a missing change is only noted for the model.
    case visibleChangeNoted
}
