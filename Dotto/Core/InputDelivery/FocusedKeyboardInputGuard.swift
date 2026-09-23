import Foundation

/// What is true right before one chunk of real (session-level) keyboard input. Such keys go to whatever window is
/// key, not to a pinned process, so they are only allowed while the user-approved assist has the target's open
/// panel in front (AGENTS.md invariant 3c).
struct FocusedKeyboardInputConditions: Equatable, Sendable {
    var foregroundAssistIsActive: Bool
    var runIsAborted: Bool
    var targetProcessIdentifier: Int32
    var frontmostProcessIdentifier: Int32?
    /// A sandboxed app's open panel is drawn by the system's open-and-save panel service, which may be frontmost.
    var openPanelServiceProcessIdentifiers: Set<Int32>
    var openPanelIsKeyWindow: Bool
    /// The user's real clicks, scrolls and keys counted since observation began; nil when nothing is observing them.
    var realUserInputCountAtAssistStart: Int?
    var realUserInputCountNow: Int?
}

enum FocusedKeyboardInputRefusal: String, Equatable, Sendable {
    case outsideForegroundAssist, runStopped, userInputNotObservable, userInputObserved, targetNotFrontmost, openPanelNotKey

    var reasonForModel: String {
        switch self {
        case .outsideForegroundAssist: return "keys can only be typed into the file dialog while the app is brought forward"
        case .runStopped: return "the task was stopped"
        case .userInputNotObservable: return "Dotto couldn't watch for your own typing, so it didn't type into the file dialog"
        case .userInputObserved: return "you used the mouse or keyboard, so Dotto stopped choosing files"
        case .targetNotFrontmost: return "another app came to the front while Dotto was choosing files"
        case .openPanelNotKey: return "the file dialog was no longer the active window"
        }
    }
}

enum FocusedKeyboardInputDecision: Equatable, Sendable {
    case post
    case refuse(FocusedKeyboardInputRefusal)
}

enum FocusedKeyboardInputGuard {
    /// Checked before every chunk. Any doubt refuses: the keys would otherwise land wherever the user now is.
    static func decision(for conditions: FocusedKeyboardInputConditions) -> FocusedKeyboardInputDecision {
        guard conditions.foregroundAssistIsActive else { return .refuse(.outsideForegroundAssist) }
        guard !conditions.runIsAborted else { return .refuse(.runStopped) }
        guard let realUserInputCountAtAssistStart = conditions.realUserInputCountAtAssistStart,
              let realUserInputCountNow = conditions.realUserInputCountNow else { return .refuse(.userInputNotObservable) }
        guard realUserInputCountNow == realUserInputCountAtAssistStart else { return .refuse(.userInputObserved) }
        guard let frontmostProcessIdentifier = conditions.frontmostProcessIdentifier,
              frontmostProcessIdentifier == conditions.targetProcessIdentifier
                || conditions.openPanelServiceProcessIdentifiers.contains(frontmostProcessIdentifier) else {
            return .refuse(.targetNotFrontmost)
        }
        guard conditions.openPanelIsKeyWindow else { return .refuse(.openPanelNotKey) }
        return .post
    }
}
