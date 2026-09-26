import Foundation
import CoreGraphics

@MainActor private func makeTurnQueue() -> ForegroundAssistTurnQueue {
    ForegroundAssistTurnQueue(gapBetweenTurnsSeconds: 0, pollIntervalSeconds: 0.005)
}

let foregroundAssistTurnQueueTestSuite = CoreTestSuite(name: "ForegroundAssistTurnQueue", testCases: [
    CoreTestCase(name: "the first task gets the turn at once, and asking again while holding it doesn't wait") {
        let turnQueue = await makeTurnQueue()
        let abortSignal = TaskAbortSignal()
        try expectTrue(await turnQueue.waitForTurn(ownerIdentifier: "a", abortSignal: abortSignal))
        try expectTrue(await turnQueue.waitForTurn(ownerIdentifier: "a", abortSignal: abortSignal))
        try expectEqual(await turnQueue.currentTurnOwnerIdentifier, "a")
    },
    CoreTestCase(name: "a second task waits until the first ends its turn, and tasks go in the order they asked") {
        let turnQueue = await makeTurnQueue()
        let abortSignal = TaskAbortSignal()
        _ = await turnQueue.waitForTurn(ownerIdentifier: "a", abortSignal: abortSignal)
        let secondTask = Task { await turnQueue.waitForTurn(ownerIdentifier: "b", abortSignal: abortSignal) }
        try await Task.sleep(nanoseconds: 20_000_000)
        let thirdTask = Task { await turnQueue.waitForTurn(ownerIdentifier: "c", abortSignal: abortSignal) }
        try await Task.sleep(nanoseconds: 20_000_000)
        try expectEqual(await turnQueue.waitingOwnerIdentifiers, ["b", "c"])
        await turnQueue.endTurn(ownerIdentifier: "a")
        try expectTrue(await secondTask.value)
        try expectEqual(await turnQueue.currentTurnOwnerIdentifier, "b")
        await turnQueue.endTurn(ownerIdentifier: "b")
        try expectTrue(await thirdTask.value)
        try expectEqual(await turnQueue.currentTurnOwnerIdentifier, "c")
    },
    CoreTestCase(name: "a task stopped while waiting leaves the queue, and ending someone else's turn does nothing") {
        let turnQueue = await makeTurnQueue()
        _ = await turnQueue.waitForTurn(ownerIdentifier: "a", abortSignal: TaskAbortSignal())
        let stoppedSignal = TaskAbortSignal()
        let stoppedTask = Task { await turnQueue.waitForTurn(ownerIdentifier: "b", abortSignal: stoppedSignal) }
        try await Task.sleep(nanoseconds: 20_000_000)
        stoppedSignal.abort()
        try expectTrue(!(await stoppedTask.value))
        try expectEqual(await turnQueue.waitingOwnerIdentifiers, [])
        await turnQueue.endTurn(ownerIdentifier: "b")
        try expectEqual(await turnQueue.currentTurnOwnerIdentifier, "a")
    },
    CoreTestCase(name: "the next turn starts only after the gap since the last one ended") {
        var fakeUptimeSeconds: TimeInterval = 100
        let turnQueue = await ForegroundAssistTurnQueue(gapBetweenTurnsSeconds: 0.5, pollIntervalSeconds: 0.005,
                                                       currentUptimeSeconds: { fakeUptimeSeconds })
        _ = await turnQueue.waitForTurn(ownerIdentifier: "a", abortSignal: TaskAbortSignal())
        await turnQueue.endTurn(ownerIdentifier: "a")
        let nextTask = Task { await turnQueue.waitForTurn(ownerIdentifier: "b", abortSignal: TaskAbortSignal()) }
        try await Task.sleep(nanoseconds: 30_000_000)
        try expectEqual(await turnQueue.currentTurnOwnerIdentifier, nil, "still inside the gap")
        fakeUptimeSeconds += 0.6
        try expectTrue(await nextTask.value)
    },
])
