import Foundation

enum ChecklistPlanningResult: Equatable {
    case checklist(Checklist)
    /// The planner asked the user something; `continuePlanning(withUserReply:…)` carries on with the answer.
    case question(PlannerQuestion)
    /// The planner can't plan this task and says why; there is nothing to reply to.
    case cannotPlan(messageToUser: String)
}

enum ChecklistPlanningError: Error, Equatable {
    case refused(String?)
    case noPlanSubmitted
    case aborted
    case transportFailed(String)
    case taskCeilingReached(String)
}

/// Runs the Opus planning conversation for one task. Planning is read-only: only read_ui, screenshot, ask_user,
/// submit_plan and the direct-route tools (`ChecklistPlanner+DirectRoutes`: scoped folder reads, the shortcut list and
/// the three direct submit tools) are offered, and any other tool call is answered with an error. When the planner asks the user
/// something, the conversation waits; `continuePlanning(withUserReply:…)` sends the answer into the same conversation,
/// so the planner goes on from what it already read rather than starting over.
final class ChecklistPlanner {
    static let submitPlanNudgeText = "Call submit_plan now."
    static let maximumQuestionsPerTask = 3
    static let questionLimitReachedText = "You have already asked 3 questions, the most allowed. Don't ask again: call submit_plan now with sensible defaults (name them in message_to_user), or with an empty items list and one sentence in message_to_user saying what is blocking."
    static let secondQuestionInTurnText = "Only one question at a time. This one wasn't shown to the user; ask it after the first is answered, if it still matters."
    static let questionNotAskedBecausePlanSubmittedText = "Not shown to the user: the plan was submitted in the same turn."
    static let fallbackCannotPlanMessage = "Dotto couldn't find anything to do. Try describing the task in more detail."

    private let transport: ClaudeTransport
    private let actionBackend: ActionBackend
    let auditLogWriter: AuditLogWriter
    /// The task's budget: planning turns and tokens count against the task-wide ceilings like the run's do.
    private let taskResourceBudget: TaskResourceBudget
    let safetyLimits: SafetyLimits
    /// The files the user attached for the next plan; the backend keeps it while planning reads the app.
    var uploadFileAllowlist: UploadFileAllowlist = .empty
    /// User-attached upload paths (folders already expanded) for the next plan; the UI sets it before planning.
    var attachedFilePathsForPrompt: [String] = []
    var focusPolicy: TaskFocusPolicy = .allowApprovedAssist
    /// Direct routes for the next plan (scope folders, scriptability); the App sets it before planning.
    var directRouteContext: PlannerDirectRouteContext = .disabled
    var directRouteFileSystemReader: DirectRouteFileSystemReading?
    var shortcutRunner: ShortcutRunning?
    /// The user's time zone, calendar and locale for date folder names ("2026-09 septiembre").
    var dateFolderNamingEnvironment: DateFolderNamingEnvironment = .current
    /// The home folder the scope policy measures roots against.
    var directRouteHomeDirectoryPath: String = NSHomeDirectory()
    /// Chunks, read counts and cached shortcut names for this task's direct routes.
    var directRoutePlanningState = DirectRoutePlanningState()

    /// The conversation so far, kept while the planner waits on the user.
    private(set) var conversationRunner: ClaudeToolConversationRunner?
    private var plannedCommand: String?
    private(set) var plannedTargetApplication: TargetApplicationReference?
    private var plannedTaskIdentifier: String?
    /// Questions shown to the user so far, counting text-only answers taken as questions.
    private(set) var askedQuestionCount = 0
    /// The ask_user call the next reply answers; nil when the question was a text-only answer, which is answered by
    /// a plain user message.
    private var askUserToolUseIdentifierAwaitingReply: String?
    private var isAwaitingUserReply = false

    init(transport: ClaudeTransport, actionBackend: ActionBackend, auditLogWriter: AuditLogWriter,
         taskResourceBudget: TaskResourceBudget, safetyLimits: SafetyLimits = .standard) {
        self.transport = transport
        self.actionBackend = actionBackend
        self.auditLogWriter = auditLogWriter
        self.taskResourceBudget = taskResourceBudget
        self.safetyLimits = safetyLimits
    }

    func produceChecklist(command: String, targetApplication: TargetApplicationReference, taskIdentifier: String,
                          abortSignal: TaskAbortSignal,
                          onProgress: @escaping @MainActor @Sendable (ChecklistPlanningProgress) -> Void) async throws -> ChecklistPlanningResult {
        auditLogWriter.append(eventKind: .checklistRequested, itemIdentifier: nil, message: command,
                              details: ["application": targetApplication.applicationName])
        return try await mappingPlanningErrors(abortSignal: abortSignal) {
            try await runPlanningConversation(command: command, targetApplication: targetApplication,
                                              taskIdentifier: taskIdentifier, abortSignal: abortSignal,
                                              onProgress: onProgress)
        }
    }

    /// Sends the user's answer to the last question and carries on planning in the same conversation.
    func continuePlanning(withUserReply userReplyText: String, abortSignal: TaskAbortSignal,
                          onProgress: @escaping @MainActor @Sendable (ChecklistPlanningProgress) -> Void) async throws -> ChecklistPlanningResult {
        guard isAwaitingUserReply, let conversationRunner, let plannedTargetApplication else {
            throw ChecklistPlanningError.noPlanSubmitted
        }
        isAwaitingUserReply = false
        auditLogWriter.append(eventKind: .checklistRequested, itemIdentifier: nil, message: "User answered the planner's question",
                              details: ["reply": userReplyText])
        let addedScopeRoots = addScopeRoots(fromUserReplyText: userReplyText)
        var replyText = PromptLibrary.plannerUserReplyText(userReplyText)
        if !addedScopeRoots.isEmpty { replyText += "\n\n" + Self.scopeRootsAddedNoteText(addedScopeRoots) }
        let userReplyBlocks: [ClaudeContentBlock]
        if let askUserToolUseIdentifier = askUserToolUseIdentifierAwaitingReply {
            userReplyBlocks = [ClaudeToolResultBuilding.textResult(toolUseIdentifier: askUserToolUseIdentifier, text: replyText, isError: false)]
        } else {
            userReplyBlocks = [.plainText(replyText)]
        }
        askUserToolUseIdentifierAwaitingReply = nil
        return try await mappingPlanningErrors(abortSignal: abortSignal) {
            await onProgress(.thinking)
            var planningTurnState = PlanningTurnState()
            let conversationEnd = try await conversationRunner.resume(
                withUserReplyBlocks: userReplyBlocks, abortSignal: abortSignal,
                onProgress: thinkingProgressForwarder(onProgress),
                shouldEndOnTextOnlyTurn: { self.canAskAnotherQuestion },
                handleToolUses: { toolUseBlocks in
                    try await self.resolvePlanningToolTurn(toolUseBlocks, applicationName: plannedTargetApplication.applicationName,
                                                           abortSignal: abortSignal, onProgress: onProgress,
                                                           planningTurnState: &planningTurnState)
                })
            return try planningResult(for: conversationEnd, planningTurnState: planningTurnState)
        }
    }

    private var canAskAnotherQuestion: Bool { askedQuestionCount < Self.maximumQuestionsPerTask }

    private func mappingPlanningErrors(abortSignal: TaskAbortSignal,
                                       _ planningWork: () async throws -> ChecklistPlanningResult) async throws -> ChecklistPlanningResult {
        do {
            return try await planningWork()
        } catch let planningError as ChecklistPlanningError {
            throw planningError
        } catch {
            if ClaudeToolResultBuilding.isAbort(error, abortSignal: abortSignal) { throw ChecklistPlanningError.aborted }
            // Backend failures (e.g. missing Accessibility permission) keep their own type so the UI can say what's wrong.
            if error is ActionBackendError { throw error }
            if let ceilingError = error as? TaskCeilingReachedError {
                throw ChecklistPlanningError.taskCeilingReached(ceilingError.userFacingDescription)
            }
            throw ChecklistPlanningError.transportFailed(error.localizedDescription)
        }
    }

    /// Thinking, then, while a submit_plan call streams in, how many items it has written so far.
    private func thinkingProgressForwarder(_ onProgress: @escaping @MainActor @Sendable (ChecklistPlanningProgress) -> Void)
        -> @Sendable (ClaudeStreamProgressEvent) -> Void {
        let submittedItemCounterBox = SubmittedChecklistItemStreamCounterBox()
        return { streamProgressEvent in
            switch streamProgressEvent {
            case .thinkingStarted:
                Task { @MainActor in onProgress(.thinking) }
            case .toolUseStarted(let toolName) where toolName == AgentToolName.submitPlan.rawValue:
                submittedItemCounterBox.restart()
            case .toolInputDelta(let toolName, let partialJSON) where toolName == AgentToolName.submitPlan.rawValue:
                if let itemsWrittenSoFar = submittedItemCounterBox.consume(partialJSON: partialJSON) {
                    Task { @MainActor in onProgress(.writingChecklist(itemsWrittenSoFar: itemsWrittenSoFar)) }
                }
            default:
                break
            }
        }
    }

    private func runPlanningConversation(command: String, targetApplication: TargetApplicationReference,
                                         taskIdentifier: String, abortSignal: TaskAbortSignal,
                                         onProgress: @escaping @MainActor @Sendable (ChecklistPlanningProgress) -> Void) async throws -> ChecklistPlanningResult {
        let applicationName = targetApplication.applicationName
        await onProgress(.readingApplication(applicationName: applicationName))
        try await actionBackend.prepareForTask(ActionBackendTaskConfiguration(targetApplication: targetApplication,
                                                                              uploadFileAllowlist: uploadFileAllowlist))
        let initialSnapshot = try await actionBackend.readUserInterface(
            ReadUserInterfaceRequest(scope: .focusedWindow, applicationName: nil, query: nil), abortSignal: abortSignal)
        let initialOutline = AccessibilityOutlineFormatter.formatOutline(initialSnapshot, query: nil, limits: .planner)
        let initialUserText = PromptLibrary.plannerInitialUserText(
            command: command, targetApplicationName: applicationName, focusedWindowOutline: initialOutline,
            attachedFilePaths: attachedFilePathsForPrompt,
            directRouteContextSection: PromptLibrary.plannerDirectRouteContextSection(directRouteContext),
            focusPolicy: focusPolicy)

        let conversationRunner = ClaudeToolConversationRunner(
            transport: transport,
            makeRequest: PromptLibrary.makePlannerRequest,
            nudgeTextWhenRequiredToolMissing: Self.submitPlanNudgeText,
            maximumModelTurns: safetyLimits.maximumModelTurnsForPlanning,
            auditLogWriter: auditLogWriter,
            itemIdentifierForAudit: nil,
            maximumRetainedScreenshots: safetyLimits.maximumRetainedScreenshotsPerConversation,
            taskResourceBudget: taskResourceBudget)
        self.conversationRunner = conversationRunner
        plannedCommand = command
        plannedTargetApplication = targetApplication
        plannedTaskIdentifier = taskIdentifier
        directRoutePlanningState = DirectRoutePlanningState()

        var planningTurnState = PlanningTurnState()
        let conversationEnd = try await conversationRunner.run(
            initialUserText: initialUserText,
            abortSignal: abortSignal,
            onProgress: thinkingProgressForwarder(onProgress),
            shouldEndOnTextOnlyTurn: { self.canAskAnotherQuestion },
            handleToolUses: { toolUseBlocks in
                try await self.resolvePlanningToolTurn(toolUseBlocks, applicationName: applicationName, abortSignal: abortSignal,
                                                       onProgress: onProgress, planningTurnState: &planningTurnState)
            })
        return try planningResult(for: conversationEnd, planningTurnState: planningTurnState)
    }

    /// What one stretch of the conversation produced: a plan, or the question it stopped for.
    private struct PlanningTurnState {
        var submittedChecklist: SubmittedChecklistDraft?
        var acceptedDirectRoutePlan: AcceptedDirectRoutePlan?
        var hasSubmittedPlan: Bool { submittedChecklist != nil || acceptedDirectRoutePlan != nil }
        var askedQuestion: (toolUseIdentifier: String, question: PlannerQuestion)?
    }

    private func resolvePlanningToolTurn(_ toolUseBlocks: [ClaudeToolUseBlock], applicationName: String, abortSignal: TaskAbortSignal,
                                         onProgress: @escaping @MainActor @Sendable (ChecklistPlanningProgress) -> Void,
                                         planningTurnState: inout PlanningTurnState) async throws -> ClaudeToolTurnResolution {
        var toolResultBlocks: [ClaudeContentBlock] = []
        var questionInThisTurn: (toolUseIdentifier: String, question: PlannerQuestion)?
        for toolUseBlock in toolUseBlocks {
            try abortSignal.throwIfAborted()
            if case .success(.askUser(let plannerQuestion)) = AgentToolCallDecoder.decodeToolCall(toolUseBlock) {
                // Its result is the user's answer, added when the conversation resumes.
                if !canAskAnotherQuestion {
                    toolResultBlocks.append(ClaudeToolResultBuilding.textResult(
                        toolUseIdentifier: toolUseBlock.toolUseIdentifier, text: Self.questionLimitReachedText, isError: true))
                } else if questionInThisTurn != nil {
                    toolResultBlocks.append(ClaudeToolResultBuilding.textResult(
                        toolUseIdentifier: toolUseBlock.toolUseIdentifier, text: Self.secondQuestionInTurnText, isError: true))
                } else {
                    questionInThisTurn = (toolUseBlock.toolUseIdentifier, plannerQuestion)
                }
                continue
            }
            let (resultContent, isError) = try await executePlanningToolCall(
                toolUseBlock, applicationName: applicationName, abortSignal: abortSignal, onProgress: onProgress,
                recordSubmittedChecklist: { planningTurnState.submittedChecklist = $0 },
                recordAcceptedDirectRoutePlan: { planningTurnState.acceptedDirectRoutePlan = $0 })
            toolResultBlocks.append(.toolResult(ClaudeToolResultBlock(
                toolUseIdentifier: toolUseBlock.toolUseIdentifier, content: resultContent, isError: isError)))
        }
        if let questionInThisTurn {
            if planningTurnState.hasSubmittedPlan {
                toolResultBlocks.append(ClaudeToolResultBuilding.textResult(
                    toolUseIdentifier: questionInThisTurn.toolUseIdentifier, text: Self.questionNotAskedBecausePlanSubmittedText,
                    isError: true))
            } else {
                planningTurnState.askedQuestion = questionInThisTurn
            }
        }
        return ClaudeToolTurnResolution(toolResultBlocks: toolResultBlocks,
                                        shouldStopAfterThisTurn: planningTurnState.hasSubmittedPlan,
                                        waitsForUserReply: planningTurnState.askedQuestion != nil)
    }

    private func planningResult(for conversationEnd: ClaudeToolConversationEnd,
                                planningTurnState: PlanningTurnState) throws -> ChecklistPlanningResult {
        guard let plannedCommand, let plannedTargetApplication, let plannedTaskIdentifier else {
            throw ChecklistPlanningError.noPlanSubmitted
        }
        switch conversationEnd {
        case .stoppedByToolHandler:
            if let acceptedDirectRoutePlan = planningTurnState.acceptedDirectRoutePlan {
                return makeDirectRoutePlanningResult(acceptedDirectRoutePlan, command: plannedCommand,
                                                     targetApplication: plannedTargetApplication, taskIdentifier: plannedTaskIdentifier)
            }
            guard let submittedChecklist = planningTurnState.submittedChecklist else { throw ChecklistPlanningError.noPlanSubmitted }
            return makePlanningResult(submittedChecklist, command: plannedCommand, targetApplication: plannedTargetApplication,
                                      taskIdentifier: plannedTaskIdentifier)
        case .pausedForUserReply:
            guard let askedQuestion = planningTurnState.askedQuestion else { throw ChecklistPlanningError.noPlanSubmitted }
            return waitForUserReply(to: askedQuestion.question, askUserToolUseIdentifier: askedQuestion.toolUseIdentifier)
        case .endedWithTextOnlyTurn(let responseText):
            // The model wrote its question as plain text instead of calling ask_user: shown as an open question.
            let plannerQuestion = PlannerQuestion.sanitized(text: responseText, choices: [], allowsFreeText: true)
            guard !plannerQuestion.text.isEmpty else { throw ChecklistPlanningError.noPlanSubmitted }
            return waitForUserReply(to: plannerQuestion, askUserToolUseIdentifier: nil)
        case .endedWithoutRequiredTool:
            // Out of questions and still no plan after the nudge: its last words explain what blocks it.
            let lastResponseText = conversationRunner?.conversationMessages.last { $0.role == .assistant }
                .map { ClaudeToolConversationRunner.joinedText(of: $0.content) } ?? ""
            let blockingExplanation = PlannerQuestion.blockingExplanation(lastResponseText)
            guard !blockingExplanation.text.isEmpty else { throw ChecklistPlanningError.noPlanSubmitted }
            auditLogWriter.append(eventKind: .checklistProduced, itemIdentifier: nil,
                                  message: "Planner couldn't plan", details: ["message_to_user": blockingExplanation.text])
            return .cannotPlan(messageToUser: blockingExplanation.text)
        case .refused(let explanation):
            throw ChecklistPlanningError.refused(explanation)
        case .turnLimitReached, .truncatedRepeatedly:
            throw ChecklistPlanningError.noPlanSubmitted
        case .unexpectedStopReason(let stopReason):
            throw ChecklistPlanningError.transportFailed("Unexpected stop reason \(stopReason)")
        }
    }

    private func waitForUserReply(to plannerQuestion: PlannerQuestion, askUserToolUseIdentifier: String?) -> ChecklistPlanningResult {
        askedQuestionCount += 1
        askUserToolUseIdentifierAwaitingReply = askUserToolUseIdentifier
        isAwaitingUserReply = true
        var questionDetails = ["question": plannerQuestion.text, "question_number": String(askedQuestionCount)]
        if !plannerQuestion.choices.isEmpty { questionDetails["choices"] = plannerQuestion.choices.map(\.label).joined(separator: " | ") }
        auditLogWriter.append(eventKind: .checklistProduced, itemIdentifier: nil, message: "Planner asked a question", details: questionDetails)
        return .question(plannerQuestion)
    }

    private func executePlanningToolCall(_ toolUseBlock: ClaudeToolUseBlock, applicationName: String,
                                         abortSignal: TaskAbortSignal,
                                         onProgress: @escaping @MainActor @Sendable (ChecklistPlanningProgress) -> Void,
                                         recordSubmittedChecklist: (SubmittedChecklistDraft) -> Void,
                                         recordAcceptedDirectRoutePlan: (AcceptedDirectRoutePlan) -> Void) async throws -> ([ClaudeToolResultContent], Bool) {
        let decodedToolCall: AgentToolCall
        switch AgentToolCallDecoder.decodeToolCall(toolUseBlock) {
        case .success(let toolCall): decodedToolCall = toolCall
        case .failure(let inputError): return ([.text(inputError.messageForModel)], true)
        }

        do {
            switch decodedToolCall {
            case .readUserInterface(let readRequest):
                await onProgress(.readingApplication(applicationName: readRequest.applicationName ?? applicationName))
                let snapshot = try await actionBackend.readUserInterface(readRequest, abortSignal: abortSignal)
                let outline = AccessibilityOutlineFormatter.formatOutline(snapshot, query: readRequest.query, limits: .planner)
                return ([.text(PromptLibrary.untrustedUserInterfaceBlock(outline))], false)
            case .screenshot:
                await onProgress(.takingScreenshot)
                let markedScreenshotCapture = try await actionBackend.captureMarkedScreenshot(markLimits: .planner,
                                                                                              abortSignal: abortSignal)
                return (ClaudeToolResultBuilding.screenshotResultContent(markedScreenshotCapture, applicationName: applicationName,
                                                                         markLimits: .planner), false)
            case .submitPlan(let submittedChecklist):
                recordSubmittedChecklist(submittedChecklist)
                return ([.text("Plan received.")], false)
            case .readDirectRouteData(let readRequest):
                let readResult = try await executeDirectRouteRead(readRequest, abortSignal: abortSignal, onProgress: onProgress)
                return (readResult.content, readResult.isError)
            case .submitDirectRoutePlan(let submittedDraft):
                let submitResult = try await acceptSubmittedDirectRoutePlan(submittedDraft, abortSignal: abortSignal,
                                                                            onProgress: onProgress)
                if let acceptedPlan = submitResult.acceptedPlan { recordAcceptedDirectRoutePlan(acceptedPlan) }
                return (submitResult.content, submitResult.isError)
            case .askUser:
                return ([.text("ask_user is answered by the user.")], true)
            case .action, .waitFor, .finishItem:
                return ([.text("\(toolUseBlock.toolName) is not available during planning.")], true)
            }
        } catch {
            if ClaudeToolResultBuilding.isAbort(error, abortSignal: abortSignal) { throw error }
            return ([.text(ClaudeToolResultBuilding.fencedMessageForModel(describing: error))], true)
        }
    }

    private func makePlanningResult(_ submittedChecklist: SubmittedChecklistDraft, command: String,
                                    targetApplication: TargetApplicationReference, taskIdentifier: String) -> ChecklistPlanningResult {
        if submittedChecklist.items.isEmpty {
            let messageToUser = submittedChecklist.messageToUser.map(PlannerQuestion.blockingExplanation)?.text
                .nonEmptyOrNil ?? Self.fallbackCannotPlanMessage
            auditLogWriter.append(eventKind: .checklistProduced, itemIdentifier: nil,
                                  message: "Planner couldn't plan", details: ["message_to_user": messageToUser])
            return .cannotPlan(messageToUser: messageToUser)
        }
        let checklist = Checklist.fromPlannerSubmission(submittedChecklist, originalCommand: command,
                                                        targetApplication: targetApplication,
                                                        taskIdentifier: taskIdentifier, createdAt: Date())
        var checklistDetails = ["title": checklist.title, "item_count": String(checklist.items.count)]
        if let messageToUser = submittedChecklist.messageToUser { checklistDetails["message_to_user"] = messageToUser }
        auditLogWriter.append(eventKind: .checklistProduced, itemIdentifier: nil, message: checklist.title, details: checklistDetails)
        return .checklist(checklist)
    }
}

/// The stream's progress callback is @Sendable, so the counter it updates lives behind a lock.
private final class SubmittedChecklistItemStreamCounterBox: @unchecked Sendable {
    private let counterLock = NSLock()
    private var submittedItemCounter = SubmittedChecklistItemStreamCounter()

    func restart() {
        counterLock.withLock { submittedItemCounter = SubmittedChecklistItemStreamCounter() }
    }

    /// The new count, or nil when this fragment didn't finish another item's label key.
    func consume(partialJSON: String) -> Int? {
        counterLock.withLock {
            submittedItemCounter.consume(partialJSON: partialJSON) ? submittedItemCounter.itemsWrittenSoFar : nil
        }
    }
}

private extension String {
    var nonEmptyOrNil: String? { isEmpty ? nil : self }
}
