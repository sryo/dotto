import Foundation
import CoreGraphics

enum AgentToolName: String, CaseIterable, Sendable {
    case readUserInterface = "read_ui"
    case screenshot = "screenshot"
    case click = "click"
    case typeText = "type_text"
    case replaceText = "replace_text"
    case pressKey = "press_key"
    case scroll = "scroll"
    case clickPoint = "click_point"
    case uploadFiles = "upload_files"
    case waitFor = "wait_for"
    case finishItem = "finish_item"
    case askUser = "ask_user"
    case submitPlan = "submit_plan"
    case submitRoutine = "submit_routine"
    case listFolder = "list_folder"
    case readFileMetadata = "read_file_metadata"
    case listShortcuts = "list_shortcuts"
    case submitFileOperationsPlan = "submit_file_operations_plan"
    case submitScriptPlan = "submit_script_plan"
    case submitShortcutPlan = "submit_shortcut_plan"
}

enum ReadUserInterfaceScope: String, Codable, Sendable { case focusedWindow = "focused_window", allWindows = "all_windows", menuBar = "menu_bar" }
enum AgentClickType: String, Codable, Sendable { case single, double, right }
enum AgentKeyModifier: String, Codable, Sendable { case command, option, control, shift }
enum AgentScrollDirection: String, Codable, Sendable { case up, down, left, right }
enum TextReplacementOccurrence: String, Codable, Sendable { case first, all }
/// Where replace_text inserts when `find` is empty; `atFind` is the only position for a non-empty `find`.
enum TextInsertionPosition: String, Codable, Sendable { case atFind = "at_find", start, end }
enum ChecklistItemOutcome: String, Codable, Sendable { case completed, failed, needsUser = "needs_user" }

struct ReadUserInterfaceRequest: Equatable, Sendable {
    var scope: ReadUserInterfaceScope
    var applicationName: String?
    var query: String?
}

enum AgentAction: Equatable, Sendable {
    case clickElement(elementIdentifier: String, clickType: AgentClickType)
    case typeText(elementIdentifier: String?, text: String, replaceExistingText: Bool, pressReturnAfter: Bool)
    /// An empty `findText` inserts `replacementText` at `insertionPosition` (start or end of the field's text).
    case replaceText(elementIdentifier: String, findText: String, replacementText: String,
                     occurrence: TextReplacementOccurrence, insertionPosition: TextInsertionPosition)
    case pressKey(keyName: String, modifiers: [AgentKeyModifier])
    case scroll(elementIdentifier: String?, direction: AgentScrollDirection, pages: Int)
    case clickScreenshotPoint(screenshotPixelPoint: CGPoint, clickType: AgentClickType)
    case uploadFiles(elementIdentifier: String, filePaths: [String])
}

extension AgentAction {
    /// Uploads drive the native file dialog, which only works with the app in front, so they skip the background
    /// attempt and go straight to the assist their own confirmation already covers.
    var requiresForegroundAssist: Bool {
        if case .uploadFiles = self { return true }
        return false
    }
}

struct SubmittedChecklistDraftItem: Equatable, Sendable { var label: String; var actionSummary: String; var parameters: [ChecklistItemParameter]; var isIrreversible: Bool }
struct SubmittedChecklistDraft: Equatable, Sendable { var taskTitle: String; var messageToUser: String?; var items: [SubmittedChecklistDraftItem] }

enum AgentToolCall: Equatable, Sendable {
    case readUserInterface(ReadUserInterfaceRequest)
    case screenshot
    case action(AgentAction)
    case waitFor(text: String, timeoutSeconds: Int)
    case finishItem(outcome: ChecklistItemOutcome, summary: String)
    case askUser(PlannerQuestion)
    case submitPlan(SubmittedChecklistDraft)
    case readDirectRouteData(DirectRouteReadRequest)
    case submitDirectRoutePlan(SubmittedDirectRoutePlanDraft)
}

struct AgentToolInputError: Error, Equatable { var messageForModel: String }

struct SubmittedRoutineDraftStep: Equatable, Sendable {
    var eventIndex: Int
    var textTemplate: String?
    var targetTextTemplate: String?
    var expectation: StepExpectation?
    var stepDescription: String
}

struct SubmittedRoutineDraft: Equatable, Sendable {
    var routineName: String
    var itemLabelTemplate: String
    var steps: [SubmittedRoutineDraftStep]
    var completionEvidence: StepExpectation?
}
