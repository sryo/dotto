import Foundation

let taskUserFacingMessagesTestSuite = CoreTestSuite(name: "TaskUserFacingMessages", testCases: [
    CoreTestCase(name: "planning errors read as plain sentences, with the refusal explanation when present") {
        try expectEqual(TaskUserFacingMessages.userFacingDescription(ofPlanningError: ChecklistPlanningError.refused("unsafe")),
                        "Claude declined to plan this task: unsafe")
        try expectEqual(TaskUserFacingMessages.userFacingDescription(ofPlanningError: ChecklistPlanningError.refused(nil)),
                        "Claude declined to plan this task.")
        try expectEqual(TaskUserFacingMessages.userFacingDescription(ofPlanningError: ChecklistPlanningError.noPlanSubmitted),
                        "Claude didn't produce a checklist. Try rephrasing the command.")
        try expectEqual(TaskUserFacingMessages.userFacingDescription(ofPlanningError: ChecklistPlanningError.transportFailed("offline")),
                        "Couldn't reach Claude: offline")
    },
    CoreTestCase(name: "an action backend error during planning shows the backend's own message") {
        try expectEqual(TaskUserFacingMessages.userFacingDescription(ofPlanningError: ActionBackendError.accessibilityPermissionMissing),
                        ActionBackendError.accessibilityPermissionMissing.messageForModel)
    },
    CoreTestCase(name: "a target app that quit before planning is named") {
        try expectEqual(TaskUserFacingMessages.targetApplicationQuitMessage(applicationName: "TextEdit"),
                        "TextEdit quit before Dotto could start")
    },
    CoreTestCase(name: "stop reasons describe how the run ended") {
        try expectEqual(TaskUserFacingMessages.userFacingDescription(ofStopReason: .allItemsProcessed), "All items processed")
        try expectEqual(TaskUserFacingMessages.userFacingDescription(ofStopReason: .userAborted), "Stopped by you")
        try expectEqual(TaskUserFacingMessages.userFacingDescription(ofStopReason: .taskCeilingReached("the 30-minute limit")),
                        "Stopped: the 30-minute limit")
    },
    CoreTestCase(name: "demonstration compile errors complete the teaching failure sentence") {
        try expectEqual(TaskUserFacingMessages.userFacingDescription(ofDemonstrationCompileError: DemonstrationCompileError.noUsableEvents),
                        "nothing was recorded")
        try expectEqual(TaskUserFacingMessages.userFacingDescription(ofDemonstrationCompileError: DemonstrationCompileError.refused("no")),
                        "Claude declined: no")
        try expectEqual(TaskUserFacingMessages.userFacingDescription(ofDemonstrationCompileError: DemonstrationCompileError.refused(nil)),
                        "Claude declined")
    },
])
