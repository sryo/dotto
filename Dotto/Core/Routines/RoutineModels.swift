import Foundation
import CoreGraphics

struct LocatorAncestor: Codable, Equatable, Sendable { var role: String; var titleTemplate: String? }

/// How replay finds a recorded step's element again in a fresh snapshot. Fields may hold {{parameter}}
/// placeholders, and any templated field must match exactly (see ElementLocatorResolver).
struct ElementLocator: Codable, Equatable, Sendable {
    var role: String
    var subrole: String?
    var titleTemplate: String?
    var descriptionTemplate: String?
    /// Kept only when the recorded value contained a parameter value.
    var valueTemplate: String?
    /// First title or value within 2 child levels, which identifies untitled rows and cells.
    var descendantTextTemplate: String?
    var placeholder: String?
    var accessibilityIdentifier: String?
    /// At most 4, window excluded.
    var ancestorsNearestFirst: [LocatorAncestor]
    /// Element center in 0…1 window coordinates.
    var normalizedPositionInWindow: CGPoint?
    var readScope: ReadUserInterfaceScope
}

struct RecordedElementContext: Codable, Equatable, Sendable {
    /// Children stripped.
    var element: AccessibilityElementNode
    /// Children stripped, up to and including the window.
    var ancestorsNearestFirst: [AccessibilityElementNode]
    var descendantText: String?
    var windowFrameInTopLeftGlobalPoints: CGRect?
    var readScope: ReadUserInterfaceScope

    /// Breadth-first over at most two child levels: the first non-empty title, else value. Secure fields are
    /// skipped. Recording and resolution must both use this rule so the texts compare equal.
    static func descendantText(below node: AccessibilityElementNode) -> String? {
        var levelNodes = node.children
        for _ in 0..<2 {
            for levelNode in levelNodes where !levelNode.isSecureTextField {
                for candidateText in [levelNode.title, levelNode.value] {
                    if let trimmedText = candidateText?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmedText.isEmpty {
                        return trimmedText
                    }
                }
            }
            levelNodes = levelNodes.flatMap(\.children)
        }
        return nil
    }
}

enum RoutineStepAction: Codable, Equatable, Sendable {
    case click(clickType: AgentClickType)
    case typeText(textTemplate: String, replaceExistingText: Bool, pressReturnAfter: Bool)
    /// Always has a target locator: replace_text names its field.
    case replaceText(findTemplate: String, replacementTemplate: String, occurrence: TextReplacementOccurrence,
                     insertionPosition: TextInsertionPosition)
    case pressKey(keyName: String, modifiers: [AgentKeyModifier])
    case waitForText(textTemplate: String, timeoutSeconds: Int)
    /// Replay re-checks the rendered paths against the current task's upload allowlist.
    case uploadFiles(filePathTemplates: [String])
}

struct RoutineStep: Codable, Equatable, Sendable {
    /// e.g. "Click textfield “{{old_name}}”"; only ever displayed, never sent to a model as instructions.
    var stepDescription: String
    var action: RoutineStepAction
    /// nil: the focused element (typeText), or no target (pressKey, waitForText).
    var targetLocator: ElementLocator?
    var expectation: StepExpectation?
    /// The recorded step tripped SafetyGate or was confirmed by the user, so replay asks on every item.
    var requiresConfirmationEachItem: Bool
    /// The grant that covers this step's confirmation; nil means .irreversibleItem.
    var confirmationRiskCategory: SafetyRiskCategory? = nil
}

enum RoutineSource: String, Codable, Sendable { case agentRun = "agent_run", userDemonstration = "user_demonstration" }

struct Routine: Codable, Equatable, Sendable, Identifiable {
    static let currentFormatVersion = 1
    var formatVersion: Int
    /// "routine-<taskIdentifier>"; only [a-z0-9-], because it is also the file name.
    var routineIdentifier: String
    var name: String
    var originalCommand: String
    var targetApplicationName: String
    var targetApplicationBundleIdentifier: String?
    var parameterNames: [String]
    var itemLabelTemplate: String
    var itemActionSummaryTemplate: String
    var steps: [RoutineStep]
    var completionEvidence: StepExpectation?
    var source: RoutineSource
    /// nil for demonstrations.
    var modelCallsUsedWhenLearned: Int?
    var createdAt: Date
    var updatedAt: Date
    var patchCount: Int
    /// HMAC-SHA256 set by RoutineLibraryStore.save; files without a valid one are never loaded.
    var integritySignature: String? = nil
    var id: String { routineIdentifier }
}

/// One successful agent step captured for compilation: only `.action` and `.waitFor` tool calls are recorded.
struct RecordedAgentStep: Equatable, Sendable {
    var toolCall: AgentToolCall
    var targetContext: RecordedElementContext?
    var expectation: StepExpectation?
    var wasConfirmedByUser: Bool
    /// The risk category of the confirmation the user answered for this action, if one was asked.
    var confirmedRiskCategory: SafetyRiskCategory? = nil
}

enum DemonstrationEvent: Codable, Equatable, Sendable {
    case click(target: RecordedElementContext, clickType: AgentClickType)
    case keyChord(keyName: String, modifiers: [AgentKeyModifier])
    case textEntered(target: RecordedElementContext, finalValue: String)
}

struct DemonstrationRecording: Codable, Equatable, Sendable {
    var application: TargetApplicationReference
    var events: [DemonstrationEvent]
    var finalWindowTitle: String?
    var finalWindowDocument: String?
}
