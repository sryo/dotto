import Foundation

/// The stages of the command pill turning into the cursor's status pill after Return, in seconds from the moment the
/// morph starts. The submitted text leaves first, the capsule starts changing shape while it goes, and the status
/// text and buttons arrive only once the submitted text is gone, so the two texts are never both readable at once.
/// The capsule's change is a spring, which has no fixed end; the view reports when it has settled.
struct CommandPillMorphTimeline: Equatable, Sendable {
    var outgoingContentFadeStartSeconds: Double = 0
    var outgoingContentFadeDurationSeconds: Double = 0.12
    var capsuleMorphStartSeconds: Double = 0.08
    var incomingContentFadeStartSeconds: Double = 0.16
    var incomingContentFadeDurationSeconds: Double = 0.12

    static let standard = CommandPillMorphTimeline()

    var outgoingContentFadeEndSeconds: Double {
        outgoingContentFadeStartSeconds + outgoingContentFadeDurationSeconds
    }

    var incomingContentFadeEndSeconds: Double {
        incomingContentFadeStartSeconds + incomingContentFadeDurationSeconds
    }

    /// The submitted text is fully gone before the status text starts to show.
    var keepsTextsApart: Bool {
        incomingContentFadeStartSeconds >= outgoingContentFadeEndSeconds
    }

    /// When the real status pill may take over: the status text has fully arrived and the capsule's spring (which
    /// takes `capsuleMorphSettlingSeconds` from its start) has come to rest on the status pill's frame.
    func handoffSeconds(capsuleMorphSettlingSeconds: Double) -> Double {
        max(incomingContentFadeEndSeconds, capsuleMorphStartSeconds + max(0, capsuleMorphSettlingSeconds))
    }
}
