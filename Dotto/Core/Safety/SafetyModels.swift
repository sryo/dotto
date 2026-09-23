import Foundation

struct SafetyLimits: Equatable, Sendable {
    var maximumActionsPerItem: Int = 25
    var maximumActionsPerTask: Int = 500
    var maximumModelTurnsPerItem: Int = 40
    var maximumModelTurnsForPlanning: Int = 12
    var maximumConsecutiveFailedItems: Int = 3
    var maximumTaskWallClockSeconds: TimeInterval = 30 * 60
    var maximumModelTurnsPerTask: Int = 600
    /// Counts uncached, cache-read and cache-write input tokens alike, since each one is billed and re-sent.
    var maximumInputTokensPerTask: Int = 6_000_000
    /// Older screenshots in an item's conversation are replaced with a placeholder so requests stay far below
    /// the Messages API's request size limit.
    var maximumRetainedScreenshotsPerConversation: Int = 8
    var maximumFileOperationsPerTask: Int = 2_000
    var maximumScriptTimeoutSeconds: Int = 300
    var maximumFileMetadataReadsPerPlanning: Int = 2_000
    static let standard = SafetyLimits()
}

/// What kind of risk a confirmation covers. "Allow for all remaining items" grants exactly one category,
/// so approving "send" steps never silently approves later "delete" or "pay" steps.
enum SafetyRiskCategory: String, CaseIterable, Codable, Sendable {
    case sendingOrPublishing
    case deleting
    case payingOrBuying
    case submittingOrApproving
    case pressingReturn
    case quittingOrClosing
    case unverifiableClick
    case unrecognizedShortcut
    case irreversibleItem
    case pastingClipboard
    case bringingAppForward
    case uploadingFiles
    case runningScript
    case runningShortcut

    /// Completes "Allow … for the rest of this task" in the confirmation card.
    var userFacingScopeDescription: String {
        switch self {
        case .sendingOrPublishing: return "sending, posting and sharing"
        case .deleting: return "deleting and discarding"
        case .payingOrBuying: return "paying, buying and transferring"
        case .submittingOrApproving: return "submitting, approving and accepting"
        case .pressingReturn: return "pressing Return"
        case .quittingOrClosing: return "quitting apps and closing windows"
        case .unverifiableClick: return "clicks Dotto can't identify"
        case .unrecognizedShortcut: return "keyboard shortcuts from taught routines"
        case .irreversibleItem: return "items marked as irreversible"
        case .pastingClipboard: return "pasting from the clipboard"
        case .bringingAppForward: return "bringing an app forward for a moment"
        case .uploadingFiles: return "attaching files you added to this task"
        case .runningScript: return "running scripts Dotto wrote for this task"
        case .runningShortcut: return "running your shortcuts"
        }
    }

    /// The owner's choice: Dotto asks only before sending, deleting or paying, before bringing an app forward or
    /// uploading, and before every shortcut. Every other category (submit words, Return outside mail, chat and
    /// browsers, quitting, clicks it can't identify, taught shortcuts, irreversible items, pasting, scripts the user
    /// already read) runs without asking. Actions in those categories still count as risky for automatic retries.
    var asksUser: Bool {
        switch self {
        case .sendingOrPublishing, .deleting, .payingOrBuying, .bringingAppForward, .uploadingFiles, .runningShortcut:
            return true
        case .submittingOrApproving, .pressingReturn, .quittingOrClosing, .unverifiableClick, .unrecognizedShortcut,
             .irreversibleItem, .pastingClipboard, .runningScript:
            return false
        }
    }

    /// A shortcut is opaque (it may run a shell script, send or delete), so every run asks again: its confirmation
    /// never offers, and never honors, "Allow for the rest of this task".
    var offersRestOfTaskGrant: Bool {
        self != .runningShortcut
    }
}

struct SafetyConfirmationRequest: Equatable, Sendable {
    var itemIdentifier: String
    var itemLabel: String
    var reason: String
    var isActionLevel: Bool
    var riskCategory: SafetyRiskCategory = .irreversibleItem
    var itemParameters: [ChecklistItemParameter] = []
}

enum SafetyConfirmationAnswer: Equatable, Sendable { case allowOnce, allowForAllRemainingItems, skipItem, stopTask }

enum SafetyVerdict: Equatable, Sendable {
    case allow
    case requireUserConfirmation(reason: String, riskCategory: SafetyRiskCategory)
    case deny(reasonForModel: String)
}

struct SafetyRiskMatch: Codable, Equatable, Sendable {
    var matchedText: String
    var riskCategory: SafetyRiskCategory
}
