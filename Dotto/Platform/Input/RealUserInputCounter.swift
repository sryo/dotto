import Foundation

/// Counts the user's real clicks, scrolls and key presses while `UserInputObserver` is observing. It is read off the
/// main thread, between keyboard chunks of a foreground assist, so every access takes the lock.
final class RealUserInputCounter: @unchecked Sendable {
    private let countLock = NSLock()
    private var realUserInputCount = 0
    private var isObserving = false

    /// nil while nothing is observing: the caller can't tell whether the user is typing, and must fail closed.
    var currentCount: Int? {
        countLock.withLock { isObserving ? realUserInputCount : nil }
    }

    func setObserving(_ observing: Bool) {
        countLock.withLock { isObserving = observing }
    }

    func recordRealUserInput() {
        countLock.withLock { realUserInputCount &+= 1 }
    }
}
