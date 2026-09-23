import Foundation

/// The run's one outstanding question to the user: a safety confirmation or an item failure decision. The run
/// waits in `waitForAnswer()`; whichever surface the user answers from resumes it, exactly once.
@MainActor final class PendingUserAnswer<Answer: Sendable> {
    private var answerContinuation: CheckedContinuation<Answer, Never>?

    var isPending: Bool { answerContinuation != nil }

    /// The executor is sequential, so callers check `isPending` first and never ask twice at once.
    func waitForAnswer() async -> Answer {
        await withCheckedContinuation { (newAnswerContinuation: CheckedContinuation<Answer, Never>) in
            answerContinuation = newAnswerContinuation
        }
    }

    /// Does nothing when no question is waiting, so a late or repeated answer can never resume the run twice.
    func resume(with answer: Answer) {
        let waitingContinuation = answerContinuation
        answerContinuation = nil
        waitingContinuation?.resume(returning: answer)
    }
}
