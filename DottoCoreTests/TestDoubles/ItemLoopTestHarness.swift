import Foundation
import CoreGraphics

/// Bundles one item loop with its fakes so each test only states what differs.
struct ItemLoopTestHarness {
    let transport: ScriptedClaudeTransport
    let actionBackend: FakeActionBackend
    let confirmationRequester: ScriptedConfirmationRequester
    let observer: RecordingExecutionObserver
    let auditLogWriter: AuditLogWriter
    let itemAgentLoop: ChecklistItemAgentLoop

    init(replies: [ScriptedClaudeTransport.ScriptedReply], confirmationAnswers: [SafetyConfirmationAnswer] = [],
         safetyLimits: SafetyLimits = .standard,
         snapshotRootNodes: [AccessibilityElementNode] = ConversationFixtures.windowRootNodes()) throws {
        transport = ScriptedClaudeTransport(replies: replies)
        actionBackend = FakeActionBackend(snapshotRootNodes: snapshotRootNodes)
        confirmationRequester = ScriptedConfirmationRequester(scriptedAnswers: confirmationAnswers)
        observer = RecordingExecutionObserver()
        auditLogWriter = try ConversationFixtures.makeAuditLogWriter()
        itemAgentLoop = ChecklistItemAgentLoop(transport: transport, actionBackend: actionBackend,
                                               confirmationRequester: confirmationRequester, observer: observer,
                                               auditLogWriter: auditLogWriter,
                                               safetyLimits: safetyLimits)
        itemAgentLoop.postActionSettleDelayNanoseconds = 0
        itemAgentLoop.waitForPollIntervalNanoseconds = 0
        itemAgentLoop.expectationTimeoutSeconds = 0
    }

    /// Runs the first item of a one-item checklist (or of `checklist`), as item 1 of the task.
    @discardableResult
    func runItem(itemLabel: String = "Rename a", checklist: Checklist? = nil, runControl: TaskRunControl? = nil,
                 remainingTaskActionBudget: Int = 500, abortSignal: TaskAbortSignal = TaskAbortSignal()) async throws -> ChecklistItemExecutionResult {
        let itemContext = ConversationFixtures.itemContext(checklist: checklist ?? ConversationFixtures.makeChecklist(itemLabels: [itemLabel]),
                                                           remainingTaskActionBudget: remainingTaskActionBudget, runControl: runControl)
        return try await itemAgentLoop.runItem(itemContext, abortSignal: abortSignal)
    }
}
