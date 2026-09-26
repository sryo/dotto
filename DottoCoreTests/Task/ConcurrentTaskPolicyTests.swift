import Foundation
import CoreGraphics

private func active(_ target: Int32, recording: Bool = false) -> TaskSessionSummary {
    TaskSessionSummary(isActive: true, isShowingResult: false, isRecordingDemonstration: recording, targetProcessIdentifier: target)
}
private func showingResult(_ target: Int32) -> TaskSessionSummary {
    TaskSessionSummary(isActive: false, isShowingResult: true, isRecordingDemonstration: false, targetProcessIdentifier: target)
}
private let idle = TaskSessionSummary(isActive: false, isShowingResult: false, isRecordingDemonstration: false, targetProcessIdentifier: nil)

let concurrentTaskPolicyTestSuite = CoreTestSuite(name: "ConcurrentTaskPolicy", testCases: [
    CoreTestCase(name: "a new task takes an idle session, or a new one while fewer than three tasks go") {
        try expectEqual(ConcurrentTaskPolicy.decision(forSummoningInto: 10, sessions: [idle]), .useSession(index: 0))
        try expectEqual(ConcurrentTaskPolicy.decision(forSummoningInto: 10, sessions: [active(20)]), .createSession)
        try expectEqual(ConcurrentTaskPolicy.decision(forSummoningInto: 10, sessions: [active(20), idle, active(30)]), .useSession(index: 1))
    },
    CoreTestCase(name: "an app with a task going shows that task instead: one task per app") {
        try expectEqual(ConcurrentTaskPolicy.decision(forSummoningInto: 20, sessions: [idle, active(20)]), .showExistingTask(index: 1))
    },
    CoreTestCase(name: "a finished task's summary is replaced by that app's new task, as with one task at a time") {
        try expectEqual(ConcurrentTaskPolicy.decision(forSummoningInto: 20, sessions: [idle, showingResult(20)]), .useSession(index: 1))
        try expectEqual(ConcurrentTaskPolicy.decision(forSummoningInto: 30, sessions: [showingResult(20)]), .createSession,
                        "another app's summary stays while there is room")
        try expectEqual(ConcurrentTaskPolicy.decision(forSummoningInto: 40, sessions: [active(10), showingResult(20), showingResult(30)]),
                        .useSession(index: 1), "with no room, the oldest summary makes way")
    },
    CoreTestCase(name: "the fourth task is refused, and recording a demonstration blocks every new task") {
        let threeTasks = [active(1), active(2), active(3)]
        try expectEqual(ConcurrentTaskPolicy.decision(forSummoningInto: 4, sessions: threeTasks), .refuseBecauseTaskLimitReached)
        try expectEqual(ConcurrentTaskPolicy.decision(forSummoningInto: 2, sessions: threeTasks), .showExistingTask(index: 1))
        try expectTrue(!ConcurrentTaskPolicy.anotherTaskCanStart(sessions: threeTasks))
        let recording = [idle, active(5, recording: true)]
        try expectEqual(ConcurrentTaskPolicy.decision(forSummoningInto: 9, sessions: recording), .showExistingTask(index: 1))
        try expectTrue(!ConcurrentTaskPolicy.anotherTaskCanStart(sessions: recording))
        try expectTrue(ConcurrentTaskPolicy.anotherTaskCanStart(sessions: [active(1), showingResult(2), showingResult(3)]))
    },
])
