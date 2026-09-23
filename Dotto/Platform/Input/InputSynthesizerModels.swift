import ApplicationServices
import CoreGraphics

enum SyntheticInputMarker {
    /// Stamped on every synthesized CGEvent ("SDK1") so the user-input observer can tell Dotto's own input apart
    /// from the user's.
    static let eventSourceUserDataValue: Int64 = 0x5344_4B31
}

/// The only address synthesized input can have. Pins are made only for the task's target app; the initializer
/// refuses Dotto's own process and non-positive pids.
struct TargetProcessPin: Equatable, Sendable {
    let processIdentifier: pid_t
    let windowIdentifier: CGWindowID?

    init?(processIdentifier: pid_t, windowIdentifier: CGWindowID?) {
        guard processIdentifier > 0, processIdentifier != getpid() else { return nil }
        self.processIdentifier = processIdentifier
        self.windowIdentifier = windowIdentifier
    }
}

enum AccessibilityActionAttemptResult: Equatable {
    case performed
    /// The app refused the action (unsupported, invalid element, bad argument): nothing happened.
    case refused(AXError)
    /// The app didn't answer in time or reported a generic failure: the action may still have happened.
    case mayHaveActed(AXError)
}
