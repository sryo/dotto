import Foundation

enum DemonstrationCompileError: Error, Equatable {
    case noUsableEvents, refused(String?), noRoutineSubmitted, aborted, transportFailed(String), taskCeilingReached(String)
}

/// One Claude call that only selects recorded events and writes {{parameter}} templates (ADR-14); every locator
/// is built from the recorded AX data by RoutineCompiler, never from text the model wrote.
final class DemonstrationRoutineCompiler {
    static let submitRoutineNudgeText = "Call submit_routine now."

    private let transport: ClaudeTransport
    private let auditLogWriter: AuditLogWriter
    /// The task's budget: compiling a taught routine counts against the task-wide ceilings like planning does.
    private let taskResourceBudget: TaskResourceBudget

    init(transport: ClaudeTransport, auditLogWriter: AuditLogWriter, taskResourceBudget: TaskResourceBudget) {
        self.transport = transport
        self.auditLogWriter = auditLogWriter
        self.taskResourceBudget = taskResourceBudget
    }

    func compileRoutine(from recording: DemonstrationRecording, checklist: Checklist, demonstratedItem: ChecklistItem,
                        routineIdentifier: String, abortSignal: TaskAbortSignal) async throws -> Routine {
        guard !recording.events.isEmpty else { throw DemonstrationCompileError.noUsableEvents }
        for case .textEntered(_, let typedValue) in recording.events { auditLogWriter.registerTypedTextForRedaction(typedValue) }

        let conversationRunner = ClaudeToolConversationRunner(
            transport: transport, makeRequest: PromptLibrary.makeRoutineCompilerRequest,
            nudgeTextWhenRequiredToolMissing: Self.submitRoutineNudgeText, maximumModelTurns: 4,
            auditLogWriter: auditLogWriter, itemIdentifierForAudit: demonstratedItem.itemIdentifier,
            taskResourceBudget: taskResourceBudget)
        let initialUserText = PromptLibrary.routineCompilerInitialUserText(checklist: checklist, item: demonstratedItem, recording: recording)
        var compiledRoutine: Routine?
        let conversationEnd: ClaudeToolConversationEnd
        do {
            conversationEnd = try await conversationRunner.run(
                initialUserText: initialUserText,
                abortSignal: abortSignal,
                handleToolUses: { toolUseBlocks in
                    let toolResultBlocks = toolUseBlocks.map { toolUseBlock -> ClaudeContentBlock in
                        func toolResult(_ resultText: String, isError: Bool) -> ClaudeContentBlock {
                            ClaudeToolResultBuilding.textResult(toolUseIdentifier: toolUseBlock.toolUseIdentifier, text: resultText, isError: isError)
                        }
                        guard compiledRoutine == nil else { return toolResult("A routine was already accepted.", isError: true) }
                        switch AgentToolCallDecoder.decodeSubmittedRoutineDraft(toolUseBlock) {
                        case .failure(let inputError):
                            return toolResult(inputError.messageForModel, isError: true)
                        case .success(let submittedDraft):
                            switch RoutineCompiler.compileFromDemonstration(recording: recording, draft: submittedDraft, checklist: checklist,
                                                                            item: demonstratedItem, routineIdentifier: routineIdentifier,
                                                                            now: Date()) {
                            case .failure(let templateError): return toolResult(templateError.message, isError: true)
                            case .success(let routine):
                                compiledRoutine = routine
                                return toolResult("Routine accepted.", isError: false)
                            }
                        }
                    }
                    return ClaudeToolTurnResolution(toolResultBlocks: toolResultBlocks, shouldStopAfterThisTurn: compiledRoutine != nil)
                })
        } catch {
            if ClaudeToolResultBuilding.isAbort(error, abortSignal: abortSignal) { throw DemonstrationCompileError.aborted }
            if let ceilingError = error as? TaskCeilingReachedError {
                throw DemonstrationCompileError.taskCeilingReached(ceilingError.userFacingDescription)
            }
            throw DemonstrationCompileError.transportFailed(error.localizedDescription)
        }
        if let compiledRoutine {
            auditLogWriter.append(eventKind: .demonstration, itemIdentifier: demonstratedItem.itemIdentifier,
                                  message: "compiled \(compiledRoutine.steps.count) steps from \(recording.events.count) recorded events",
                                  details: ["routine": compiledRoutine.routineIdentifier])
            return compiledRoutine
        }
        if case .refused(let explanation) = conversationEnd { throw DemonstrationCompileError.refused(explanation) }
        throw DemonstrationCompileError.noRoutineSubmitted
    }
}
