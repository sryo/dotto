import Foundation

private let fastPollIntervalNanoseconds: UInt64 = 1_000_000

/// Runs a checkpoint in its own Task while the test drives the control from outside, as the UI does.
private func startCheckpoint(_ runControl: TaskRunControl, abortSignal: TaskAbortSignal = TaskAbortSignal())
    -> Task<TaskRunCheckpointOutcome, Error> {
    Task { try await runControl.checkpoint(abortSignal: abortSignal) }
}

private func pauseBriefly() async throws {
    try await Task.sleep(nanoseconds: 20_000_000)
}

private func expectAborted(_ checkpointTask: Task<TaskRunCheckpointOutcome, Error>) async throws {
    do {
        let outcome = try await checkpointTask.value
        throw CoreTestFailure(description: "expected ActionBackendError.aborted, got \(outcome)")
    } catch let backendError as ActionBackendError {
        try expectEqual(backendError, .aborted)
    }
}

let taskRunControlTestSuite = CoreTestSuite(name: "TaskRunControl", testCases: [
    CoreTestCase(name: "an unpaused checkpoint proceeds") {
        try expectEqual(try await TaskRunControl().checkpoint(abortSignal: TaskAbortSignal()), .proceed)
    },
    CoreTestCase(name: "pause blocks until resume from another Task, then reports resumedAfterPause") {
        let runControl = TaskRunControl(pollIntervalNanoseconds: fastPollIntervalNanoseconds)
        runControl.requestPause(reason: .requestedByUser)
        let checkpointTask = startCheckpoint(runControl)
        try await pauseBriefly()
        try expectEqual(runControl.currentPauseReason, .requestedByUser)
        runControl.resume()
        try expectEqual(try await checkpointTask.value, .resumedAfterPause)
        try expectEqual(runControl.currentPauseReason, nil)
    },
    CoreTestCase(name: "skip while paused unblocks with skipCurrentItem and leaves the control unpaused") {
        let runControl = TaskRunControl(pollIntervalNanoseconds: fastPollIntervalNanoseconds)
        runControl.requestPause(reason: .userTookOver(.mouseClicked))
        let checkpointTask = startCheckpoint(runControl)
        try await pauseBriefly()
        runControl.requestSkipCurrentItem()
        try expectEqual(try await checkpointTask.value, .skipCurrentItem)
        try expectEqual(runControl.currentPauseReason, nil)
        try expectEqual(try await runControl.checkpoint(abortSignal: TaskAbortSignal()), .proceed, "the checkpoint consumes the skip request")
    },
    CoreTestCase(name: "abort while paused throws aborted") {
        let runControl = TaskRunControl(pollIntervalNanoseconds: fastPollIntervalNanoseconds)
        let abortSignal = TaskAbortSignal()
        runControl.requestPause(reason: .requestedByUser)
        let checkpointTask = startCheckpoint(runControl, abortSignal: abortSignal)
        try await pauseBriefly()
        abortSignal.abort()
        try await expectAborted(checkpointTask)
    },
    CoreTestCase(name: "Task cancellation while paused throws aborted") {
        let runControl = TaskRunControl(pollIntervalNanoseconds: 50_000_000)
        runControl.requestPause(reason: .requestedByUser)
        let checkpointTask = startCheckpoint(runControl)
        try await pauseBriefly()
        checkpointTask.cancel()
        try await expectAborted(checkpointTask)
    },
    CoreTestCase(name: "a skip pressed while running skips at the next checkpoint, once") {
        let runControl = TaskRunControl()
        runControl.requestSkipCurrentItem()
        try expectEqual(try await runControl.checkpoint(abortSignal: TaskAbortSignal()), .skipCurrentItem)
        try expectEqual(try await runControl.checkpoint(abortSignal: TaskAbortSignal()), .proceed)
    },
    CoreTestCase(name: "abort wins over a pending skip at either checkpoint") {
        let runControl = TaskRunControl()
        let abortSignal = TaskAbortSignal()
        abortSignal.abort()
        runControl.requestSkipCurrentItem()
        try await expectAborted(Task { try await runControl.checkpoint(abortSignal: abortSignal) })
        try await expectAborted(Task { try await runControl.checkpointBetweenItems(abortSignal: abortSignal) })
    },
    CoreTestCase(name: "the first pause reason is kept") {
        let runControl = TaskRunControl()
        runControl.requestPause(reason: .userTookOver(.keyPressed))
        runControl.requestPause(reason: .requestedByUser)
        try expectEqual(runControl.currentPauseReason, .userTookOver(.keyPressed))
        try expectEqual(TaskPauseReason.userTookOver(.keyPressed).bannerText, "Paused: you typed in the app Dotto is using. Resume?")
        try expectEqual(TaskPauseReason.userTookOver(.windowClosed).bannerText,
                        "Paused: the window Dotto is using was closed or minimized. Resume?")
        try expectEqual(TaskPauseReason.requestedByUser.bannerText, "Paused.")
    },
    CoreTestCase(name: "a skip pressed while paused between items applies to the next item") {
        let runControl = TaskRunControl(pollIntervalNanoseconds: fastPollIntervalNanoseconds)
        runControl.requestPause(reason: .requestedByUser)
        runControl.requestSkipCurrentItem()
        try expectEqual(try await runControl.checkpointBetweenItems(abortSignal: TaskAbortSignal()), .skipCurrentItem)
        try expectEqual(try await runControl.checkpointBetweenItems(abortSignal: TaskAbortSignal()), .proceed)
    },
    CoreTestCase(name: "a skip pressed during the between-items wait applies to the next item") {
        let runControl = TaskRunControl(pollIntervalNanoseconds: fastPollIntervalNanoseconds)
        runControl.requestPause(reason: .userTookOver(.mouseClicked))
        let betweenItemsTask = Task { try await runControl.checkpointBetweenItems(abortSignal: TaskAbortSignal()) }
        try await pauseBriefly()
        runControl.requestSkipCurrentItem()
        try expectEqual(try await betweenItemsTask.value, .skipCurrentItem)
    },
    CoreTestCase(name: "a skip left over from the finished item is dropped between items") {
        let runControl = TaskRunControl(pollIntervalNanoseconds: fastPollIntervalNanoseconds)
        runControl.requestSkipCurrentItem()
        try expectEqual(try await runControl.checkpointBetweenItems(abortSignal: TaskAbortSignal()), .proceed)
        try expectEqual(try await runControl.checkpoint(abortSignal: TaskAbortSignal()), .proceed, "the dropped skip is gone")
    },
])
