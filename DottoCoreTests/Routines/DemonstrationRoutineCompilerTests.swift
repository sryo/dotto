import Foundation
import CoreGraphics

private let renameSubmitRoutineInput = #"{"routine_name":"Rename","item_label_template":"Rename {{old_name}}","steps":[{"event_index":0,"text_template":null,"target_text_template":null,"expect":null,"description":"Click the file name"},{"event_index":1,"text_template":"{{new_name}}","target_text_template":null,"expect":null,"description":"Type the new name"}],"completion_evidence":{"kind":"text_appears","text":"{{new_name}}"}}"#

private func renameDemonstrationRecording() throws -> DemonstrationRecording {
    let snapshot = makeFixtureSnapshot(RoutineRunFixtures.finderRootNodes(), windowTitle: "Documents")
    let fieldContext = try unwrapOrFail(snapshot.recordedElementContext(forNodeWithIdentifier: "e11"))
    return DemonstrationRecording(application: fixtureTargetApplication,
                                  events: [.click(target: fieldContext, clickType: .single),
                                           .textEntered(target: fieldContext, finalValue: "shot-01.png")],
                                  finalWindowTitle: "Documents", finalWindowDocument: nil)
}

private func makeDemonstrationRoutineCompiler(transport: ScriptedClaudeTransport,
                                              taskResourceBudget: TaskResourceBudget = TaskResourceBudget(safetyLimits: .standard))
    throws -> DemonstrationRoutineCompiler {
    DemonstrationRoutineCompiler(transport: transport, auditLogWriter: try ConversationFixtures.makeAuditLogWriter(),
                                 taskResourceBudget: taskResourceBudget)
}

let demonstrationRoutineCompilerTestSuite = CoreTestSuite(name: "DemonstrationRoutineCompiler", testCases: [
    CoreTestCase(name: "demonstration compiler: submit_routine produces a routine") {
        let transport = ScriptedClaudeTransport(replies: [
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_routine", "submit_routine", renameSubmitRoutineInput)),
        ])
        let checklist = RoutineRunFixtures.renameChecklist()
        let routine = try await makeDemonstrationRoutineCompiler(transport: transport)
            .compileRoutine(from: try renameDemonstrationRecording(), checklist: checklist, demonstratedItem: checklist.items[0],
                            routineIdentifier: "routine-test-task", abortSignal: TaskAbortSignal())
        try expectEqual(routine.source, .userDemonstration)
        try expectEqual(routine.steps.count, 2)
        try expectEqual(transport.recordedRequests.first?.tools.map(\.name), [AgentToolName.submitRoutine.rawValue])
    },
    CoreTestCase(name: "demonstration compiler: an invalid event index is an error, then a resubmission succeeds") {
        let invalidInput = renameSubmitRoutineInput.replacingOccurrences(of: #""event_index":1"#, with: #""event_index":7"#)
        let transport = ScriptedClaudeTransport(replies: [
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_bad", "submit_routine", invalidInput)),
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_good", "submit_routine", renameSubmitRoutineInput)),
        ])
        let checklist = RoutineRunFixtures.renameChecklist()
        let routine = try await makeDemonstrationRoutineCompiler(transport: transport)
            .compileRoutine(from: try renameDemonstrationRecording(), checklist: checklist, demonstratedItem: checklist.items[0],
                            routineIdentifier: "routine-test-task", abortSignal: TaskAbortSignal())
        try expectEqual(routine.steps.count, 2)
        try expectEqual(try firstToolResult(ofRequest: 1, in: transport).isError, true)
    },
    CoreTestCase(name: "demonstration compiler: an empty recording throws before any request") {
        let transport = ScriptedClaudeTransport(replies: [])
        let checklist = RoutineRunFixtures.renameChecklist()
        var emptyRecording = try renameDemonstrationRecording()
        emptyRecording.events = []
        do {
            _ = try await makeDemonstrationRoutineCompiler(transport: transport)
                .compileRoutine(from: emptyRecording, checklist: checklist, demonstratedItem: checklist.items[0],
                                routineIdentifier: "routine-test-task", abortSignal: TaskAbortSignal())
            throw CoreTestFailure(description: "expected noUsableEvents")
        } catch let compileError as DemonstrationCompileError {
            try expectEqual(compileError, .noUsableEvents)
        }
        try expectTrue(transport.recordedRequests.isEmpty)
    },
    CoreTestCase(name: "demonstration compiler: its turns count against the task-wide ceiling, and a spent budget stops it") {
        let transport = ScriptedClaudeTransport(replies: [
            try ConversationFixtures.toolTurn(ConversationFixtures.toolUse("toolu_routine", "submit_routine", renameSubmitRoutineInput)),
        ])
        var tightLimits = SafetyLimits.standard
        tightLimits.maximumModelTurnsPerTask = 1
        let taskResourceBudget = TaskResourceBudget(safetyLimits: tightLimits)
        let checklist = RoutineRunFixtures.renameChecklist()
        _ = try await makeDemonstrationRoutineCompiler(transport: transport, taskResourceBudget: taskResourceBudget)
            .compileRoutine(from: try renameDemonstrationRecording(), checklist: checklist, demonstratedItem: checklist.items[0],
                            routineIdentifier: "routine-test-task", abortSignal: TaskAbortSignal())
        try expectEqual(taskResourceBudget.modelTurnsUsed, 1)
        do {
            _ = try await makeDemonstrationRoutineCompiler(transport: transport, taskResourceBudget: taskResourceBudget)
                .compileRoutine(from: try renameDemonstrationRecording(), checklist: checklist, demonstratedItem: checklist.items[0],
                                routineIdentifier: "routine-test-task", abortSignal: TaskAbortSignal())
            throw CoreTestFailure(description: "expected the task ceiling")
        } catch let compileError as DemonstrationCompileError {
            try expectEqual(compileError, .taskCeilingReached("the task used its limit of 1 Claude turns"))
        }
        try expectEqual(transport.recordedRequests.count, 1)
    },
])
