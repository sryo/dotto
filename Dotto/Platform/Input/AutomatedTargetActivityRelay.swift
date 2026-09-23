import Foundation

/// Tells the session when Dotto's own input to the target app starts and ends, and when a bring-forward assist
/// starts and ends, stamped on the clock observed events use. Windows the target app moves, resizes or closes in
/// response to these are Dotto's doing, never the user taking over (`UserTakeoverDetector`).
@MainActor final class AutomatedTargetActivityRelay {
    var onAutomatedTargetActivity: ((AutomatedTargetActivity, TimeInterval) -> Void)?

    func report(_ automatedActivity: AutomatedTargetActivity) {
        onAutomatedTargetActivity?(automatedActivity, UserInputObserver.currentMonotonicTimestampSeconds())
    }
}
