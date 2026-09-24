import SwiftUI

/// Everything `CursorView` draws. `CursorController` rebuilds it from Core's presentation state.
struct CursorAppearance: Equatable {
    /// During a flight the controller shows `.pointing`, then the state's own activity on arrival.
    var activity: CursorActivity = .pointing
    var pillText: String = ""
    var showsTypingCaret: Bool = false
    var replayProgress: Double = 0
    var decisionOptions: [UserDecisionOption] = []
    /// The attention request the decision buttons answer; nil when they answer none (Resume, the countdown's Cancel).
    var attentionRequestIdentifier: String?
    /// While planning or a run is live the pill ends with a Stop button, whatever else it carries.
    var offersStop: Bool = false
    /// While a run is working (not waiting on the user, paused or finished) the pill offers Pause before Stop.
    var offersPause: Bool = false
    /// While planning or a run is live the pill ends with a chevron that opens the checklist beside the cursor.
    var offersChecklistToggle: Bool = false
    /// What circles the reading ring outside the ring status style: "reading Finder", uppercased when drawn.
    var readingRingText: String = "reading · reading"
    var isPillQuietlyHidden: Bool = false
    var clickRippleCount: Int = 0
    var errorShakeCount: Int = 0
    /// Goes up when Dotto starts waiting for the user and again with every unanswered nudge: the pill hops, the
    /// live view bounces.
    var attentionNudgeCount: Int = 0

    /// Whether the status style shows a pill that carries text and no answers: always in chat, never in ring (the
    /// text circles the cursor instead), and in quiet until it fades a moment after each change.
    func statusStyleShowsTextOnlyPill(_ statusStyle: CursorStatusStyle) -> Bool {
        guard !pillText.isEmpty else { return false }
        switch statusStyle {
        case .chat: return true
        case .ring: return false
        case .quiet: return !isPillQuietlyHidden
        }
    }
}

extension CursorStyleConfiguration {
    var taskAccentColor: Color {
        let taskColorComponents = taskColorRedGreenBlue
        return Color(red: taskColorComponents.red, green: taskColorComponents.green, blue: taskColorComponents.blue)
    }

    /// The task color, or red while Dotto is stuck.
    func stateColor(for activity: CursorActivity) -> Color {
        activity == .error ? DesignSystem.Colors.destructive : taskAccentColor
    }

    /// The system setting always wins; the owner's JSON can only add reduced motion, never take it away.
    func reducesMotion(systemReduceMotion: Bool) -> Bool {
        systemReduceMotion || reduceMotion == true
    }
}

enum CursorPalette {
    /// The lab's deep violet drop shadow under the pill and the docked pill.
    static let pillShadowColor = Color(red: 10 / 255, green: 6 / 255, blue: 30 / 255)
}

extension CursorActivity {
    var showsArrow: Bool { [.pointing, .clicking, .replaying, .paused, .error].contains(self) }
    var showsRing: Bool { [.reading, .thinking, .waiting, .done].contains(self) }
    var fillsRing: Bool { self == .waiting || self == .done }

    /// Ring radius per activity in cursor points; activities without a ring keep the resting radius.
    var ringRadius: CGFloat {
        switch self {
        case .reading: return 24
        case .thinking: return 14
        case .waiting, .done, .error: return 12
        default: return 10
        }
    }

    /// Where the pill's top-left sits relative to the arrow tip. One offset for every activity, clearing the largest
    /// shape (the reading ring): the cursor morphs under a pill that stays put, instead of the pill and the checklist
    /// hanging from it jumping at every state change.
    var pillOffsetFromTip: CGSize {
        CGSize(width: 40, height: 30)
    }
}

extension TaskPauseReason {
    /// The takeover wording on the cursor pill and the paused banner: "Paused · you clicked in Finder".
    func pausedStatusText(targetApplicationName: String) -> String {
        switch self {
        case .requestedByUser: return "Paused"
        case .userTookOver(.mouseClicked): return "Paused · you clicked in \(targetApplicationName)"
        case .userTookOver(.scrolled): return "Paused · you scrolled in \(targetApplicationName)"
        case .userTookOver(.keyPressed): return "Paused · you typed in \(targetApplicationName)"
        case .userTookOver(.windowMovedOrResized): return "Paused · you moved \(targetApplicationName)’s window"
        case .userTookOver(.windowClosed): return "Paused · \(targetApplicationName)’s window closed"
        }
    }
}
