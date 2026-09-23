import Foundation
import CoreGraphics

/// One executor wired with every option and fake; each test states only what differs. Typing into a field makes
/// the fake UI show the typed value, so routine replays and completion checks see their own work.
struct TaskExecutorTestHarness {
    let transport: ScriptedClaudeTransport
    let actionBackend: FakeActionBackend
    let confirmationRequester: ScriptedConfirmationRequester
    let observer: RecordingExecutionObserver
    let interactionHandler: ScriptedInteractionHandler
    let metricsAccumulator = TaskRunMetricsAccumulator()
    let runControl = TaskRunControl(pollIntervalNanoseconds: 1_000_000)
    let taskResourceBudget: TaskResourceBudget
    let taskExecutor: TaskExecutor

    /// `canAskUser: false` leaves out the interaction handler, so failed items are never put to the user.
    init(replies: [ScriptedClaudeTransport.ScriptedReply], rootNodes: [AccessibilityElementNode] = ConversationFixtures.windowRootNodes(),
         routineToReplay: Routine? = nil, confirmationAnswers: [SafetyConfirmationAnswer] = [],
         failureDecisions: [ChecklistItemFailureDecision] = [], canAskUser: Bool = true,
         safetyLimits: SafetyLimits = .standard, currentDate: @escaping () -> Date = Date.init,
         uploadFileAllowlist: UploadFileAllowlist = .empty,
         taskResourceBudget: TaskResourceBudget? = nil) throws {
        transport = ScriptedClaudeTransport(replies: replies)
        let actionBackend = FakeActionBackend(snapshotRootNodes: rootNodes)
        actionBackend.actionHookAfterPerform = { [unowned actionBackend] performedAction in
            if case .typeText(let elementIdentifier?, let typedText, _, _) = performedAction {
                actionBackend.snapshotRootNodes = RoutineRunFixtures.settingValue(typedText, ofNodeWithIdentifier: elementIdentifier,
                                                                              in: actionBackend.snapshotRootNodes)
            }
        }
        self.actionBackend = actionBackend
        confirmationRequester = ScriptedConfirmationRequester(scriptedAnswers: confirmationAnswers)
        observer = RecordingExecutionObserver()
        interactionHandler = ScriptedInteractionHandler(scriptedDecisions: failureDecisions)
        self.taskResourceBudget = taskResourceBudget ?? TaskResourceBudget(safetyLimits: safetyLimits, currentDate: currentDate)
        var options = TaskExecutionOptions()
        options.runControl = runControl
        options.interactionHandler = canAskUser ? interactionHandler : nil
        options.routineToReplay = routineToReplay
        options.metricsAccumulator = metricsAccumulator
        options.uploadFileAllowlist = uploadFileAllowlist
        taskExecutor = TaskExecutor(transport: MeteredClaudeTransport(wrapping: transport, metricsAccumulator: metricsAccumulator),
                                    actionBackend: actionBackend, confirmationRequester: confirmationRequester, observer: observer,
                                    auditLogWriter: try ConversationFixtures.makeAuditLogWriter(),
                                    taskResourceBudget: self.taskResourceBudget, safetyLimits: safetyLimits,
                                    currentDate: currentDate, options: options)
        taskExecutor.checklistItemAgentLoop.postActionSettleDelayNanoseconds = 0
        taskExecutor.checklistItemAgentLoop.waitForPollIntervalNanoseconds = 0
        taskExecutor.checklistItemAgentLoop.expectationTimeoutSeconds = 0
        taskExecutor.routineReplayEngine.stepSettleDelayNanoseconds = 0
        taskExecutor.routineReplayEngine.expectationPollIntervalNanoseconds = 0
        taskExecutor.routineReplayEngine.expectationTimeoutSeconds = 0
    }

    func run(_ approvedChecklist: Checklist, abortSignal: TaskAbortSignal = TaskAbortSignal()) async -> TaskRunSummary {
        await taskExecutor.run(approvedChecklist: approvedChecklist, abortSignal: abortSignal)
    }
}
