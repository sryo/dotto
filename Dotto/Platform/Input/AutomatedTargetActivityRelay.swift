import Foundation

/// Tells the session when Dotto's own input to the target app starts and ends, and when a bring-forward assist
/// starts and ends, stamped on the clock observed events use. Windows the target app moves, resizes or closes in
/// response to these are Dotto's doing, never the user taking over (`UserTakeoverDetector`).
///
/// An action names the app it went to, so with several tasks running only that task's detector hears about it: one
/// task's steps must not hide the user moving another task's window. A bring-forward assist names none, because it and
/// the restore that follows re-order every app's windows.
@MainActor final class AutomatedTargetActivityRelay {
    /// The activity, its timestamp, and the app it went to (nil for activity that affects every app's windows).
    var onAutomatedTargetActivity: ((AutomatedTargetActivity, TimeInterval, pid_t?) -> Void)?

    func report(_ automatedActivity: AutomatedTargetActivity, targetProcessIdentifier: pid_t?) {
        onAutomatedTargetActivity?(automatedActivity, UserInputObserver.currentMonotonicTimestampSeconds(), targetProcessIdentifier)
    }
}
