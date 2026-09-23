import AppKit
import Carbon.HIToolbox

/// What Core's ForegroundAssistReadinessPolicy needs right before a bring-forward: how long the user's hands have been
/// off the mouse buttons, wheel and keyboard, and who holds secure event input. Cheap enough to poll every 250 ms.
enum ForegroundAssistReadinessProbe {
    /// The HID system state only counts hardware events. Dotto's own input is posted to a process or at the session
    /// tap, never through HID, so it never looks like the user. Pointer travel alone doesn't count.
    private static let realUserInputEventTypes: [CGEventType] = [
        .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown, .flagsChanged,
    ]

    static func currentInputs() -> ForegroundAssistReadinessInputs {
        let secondsSinceLastRealUserInput = realUserInputEventTypes
            .map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }
            .filter { $0.isFinite && $0 >= 0 }
            .min()
        let (secureEventInputIsEnabled, secureEventInputProcessIdentifier) = currentSecureEventInputHolder()
        return ForegroundAssistReadinessInputs(secondsSinceLastRealUserInput: secondsSinceLastRealUserInput,
                                               secureEventInputIsEnabled: secureEventInputIsEnabled,
                                               secureEventInputProcessIdentifier: secureEventInputProcessIdentifier)
    }

    /// The session names the process that turned secure event input on. When the session has no dictionary at all
    /// (no GUI session), whether it is on stays unknown, which the policy treats as on.
    static func currentSecureEventInputHolder() -> (isEnabled: Bool?, processIdentifier: Int32?) {
        guard let sessionDictionary = CGSessionCopyCurrentDictionary() as? [String: Any] else { return (nil, nil) }
        let secureInputProcessIdentifier = (sessionDictionary["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value
        if let secureInputProcessIdentifier, secureInputProcessIdentifier > 0 {
            return (true, secureInputProcessIdentifier)
        }
        return (IsSecureEventInputEnabled(), nil)
    }
}
