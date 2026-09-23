import Foundation

enum UserAttentionKind: String, Codable, Equatable, Sendable { case needsDecision, needsBringForward, stuck, finished }

/// `cancel` calls off a bring-forward during its countdown.
enum UserDecisionOptionIdentifier: String, Codable, Equatable, Sendable { case allow, allowRestOfTask, skip, stop, pause, resume, retry, cancel }

struct UserDecisionOption: Equatable, Sendable {
    var identifier: UserDecisionOptionIdentifier
    var title: String
    var isPrimary: Bool
}

/// Dotto needs the user while it works in the background. It asks through a notification, a sound and the menu bar
/// icon, never by taking focus. The texts come from item labels, app names and Dotto's own safety wording only,
/// never from typed text or model summaries, because notifications can show on the lock screen.
struct UserAttentionRequest: Equatable, Sendable {
    static let maximumTitleLength = 60
    static let maximumBodyTextLength = 180

    /// New for every request: the UI posts one notification per identifier and withdraws it once the state's
    /// request goes back to nil.
    var requestIdentifier: String
    var kind: UserAttentionKind
    var title: String
    var bodyText: String
    var decisionOptions: [UserDecisionOption]
}

extension SafetyConfirmationAnswer {
    init?(decisionOptionIdentifier: UserDecisionOptionIdentifier) {
        switch decisionOptionIdentifier {
        case .allow: self = .allowOnce
        case .allowRestOfTask: self = .allowForAllRemainingItems
        case .skip: self = .skipItem
        case .stop: self = .stopTask
        case .pause, .resume, .retry, .cancel: return nil
        }
    }
}

extension ChecklistItemFailureDecision {
    init?(decisionOptionIdentifier: UserDecisionOptionIdentifier) {
        switch decisionOptionIdentifier {
        case .retry: self = .retry
        case .skip: self = .skipItem
        case .stop: self = .stopTask
        case .allow, .allowRestOfTask, .pause, .resume, .cancel: return nil
        }
    }
}

struct AttentionDeliveryChannels: Equatable, Sendable {
    var postsNotification: Bool
    var playsSound: Bool
    var pulsesMenuBarIcon: Bool
}

struct AttentionPreferences: Codable, Equatable, Sendable {
    /// Opt-in: the cursor pill, the sound and the menu bar icon come first.
    var notificationsEnabled = false
    var soundEnabled = true
    var menuBarPulseEnabled = true
    /// The user already sees the cursor and the checklist panel while the target app or Dotto is in front.
    var notifyOnlyWhenTargetOrThisAppNotFrontmost = true

    static let standard = AttentionPreferences()

    func deliveryChannels(for attentionRequest: UserAttentionRequest, targetOrThisAppIsFrontmost: Bool) -> AttentionDeliveryChannels {
        let userIsLookingElsewhere = !(notifyOnlyWhenTargetOrThisAppNotFrontmost && targetOrThisAppIsFrontmost)
        return AttentionDeliveryChannels(
            postsNotification: notificationsEnabled && userIsLookingElsewhere,
            // A finished task needs no immediate answer, so it never makes a sound.
            playsSound: soundEnabled && userIsLookingElsewhere && attentionRequest.kind != .finished,
            pulsesMenuBarIcon: menuBarPulseEnabled)
    }
}

enum UserFacingTextSanitizing {
    /// One line: control characters and line breaks become spaces, runs of whitespace collapse, and text longer
    /// than `maximumLength` ends with "…".
    static func singleLine(_ rawText: String, maximumLength: Int) -> String {
        let spacedText = String(rawText.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) ? " " : Character(scalar)
        })
        let collapsedText = spacedText.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsedText.count > maximumLength else { return collapsedText }
        return String(collapsedText.prefix(max(0, maximumLength - 1))) + "…"
    }
}
