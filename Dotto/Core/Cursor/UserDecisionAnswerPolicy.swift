import Foundation

/// One click on a decision button, wherever it was clicked: the cursor pill, the live view or a notification.
struct UserDecisionAnswer: Equatable, Sendable {
    var optionIdentifier: UserDecisionOptionIdentifier
    /// The attention request whose buttons were on screen when the click happened; nil for buttons shown without
    /// one (Resume on the paused pill, Pause and Stop, the countdown's Cancel).
    var attentionRequestIdentifier: String?
}

/// Which answers still apply. A button can outlive its question by a frame, and a notification by minutes, so an
/// answer counts only for the question it was given for.
enum UserDecisionAnswerPolicy {
    /// Stop, Pause and Cancel only ever make Dotto do less, so they are honored whatever question is up (Stop always
    /// works), unless they name a request that is no longer pending: a Stop on a notification from an earlier
    /// question must not stop whatever runs now.
    static func optionIsAlwaysHonored(_ optionIdentifier: UserDecisionOptionIdentifier) -> Bool {
        optionIdentifier == .stop || optionIdentifier == .pause || optionIdentifier == .cancel
    }

    /// Answers to a question (Allow, Allow for the rest, Skip, Retry) need that exact question to still be pending.
    /// Resume belongs to the paused pill, which carries no attention request, so it must match "none pending".
    static func accepts(_ answer: UserDecisionAnswer, pendingAttentionRequestIdentifier: String?) -> Bool {
        if optionIsAlwaysHonored(answer.optionIdentifier) {
            return answer.attentionRequestIdentifier == nil || answer.attentionRequestIdentifier == pendingAttentionRequestIdentifier
        }
        if answer.optionIdentifier == .resume {
            return answer.attentionRequestIdentifier == pendingAttentionRequestIdentifier
        }
        guard let answeredAttentionRequestIdentifier = answer.attentionRequestIdentifier,
              let pendingAttentionRequestIdentifier else { return false }
        return answeredAttentionRequestIdentifier == pendingAttentionRequestIdentifier
    }
}

/// Buttons that just appeared, or whose question just changed, ignore clicks for a moment: a click aimed at what
/// was there a split second earlier (the user was about to click something else in that spot) must not answer the
/// new question.
struct UserDecisionClickGuard: Sendable {
    static let armingDelaySeconds: TimeInterval = 0.5

    private(set) var displayedQuestionSignature: String?
    private var displayedQuestionShownAtUptimeSeconds: TimeInterval = -.greatestFiniteMagnitude

    /// `questionSignature` identifies what the buttons answer (the request id, the question text and the options);
    /// nil while no buttons are shown. Only a change re-arms the delay.
    mutating func noteDisplayedQuestion(signature questionSignature: String?, atUptimeSeconds uptimeSeconds: TimeInterval) {
        guard questionSignature != displayedQuestionSignature else { return }
        displayedQuestionSignature = questionSignature
        displayedQuestionShownAtUptimeSeconds = uptimeSeconds
    }

    func acceptsClick(on optionIdentifier: UserDecisionOptionIdentifier, atUptimeSeconds uptimeSeconds: TimeInterval) -> Bool {
        if UserDecisionAnswerPolicy.optionIsAlwaysHonored(optionIdentifier) { return true }
        return uptimeSeconds - displayedQuestionShownAtUptimeSeconds >= Self.armingDelaySeconds
    }
}
