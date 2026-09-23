import Foundation

let pendingUserAnswerTestSuite = CoreTestSuite(name: "PendingUserAnswer", testCases: [
    CoreTestCase(name: "the waiting run gets the first answer only; later answers are ignored") {
        let pendingAnswer = await PendingUserAnswer<SafetyConfirmationAnswer>()
        let waitingTask = Task { await pendingAnswer.waitForAnswer() }
        while !(await pendingAnswer.isPending) { await Task.yield() }
        await pendingAnswer.resume(with: .stopTask)
        await pendingAnswer.resume(with: .allowOnce)
        try expectEqual(await waitingTask.value, .stopTask)
        try expectEqual(await pendingAnswer.isPending, false)
    },
    CoreTestCase(name: "an answer with nothing waiting does nothing") {
        let pendingAnswer = await PendingUserAnswer<ChecklistItemFailureDecision>()
        await pendingAnswer.resume(with: .retry)
        try expectEqual(await pendingAnswer.isPending, false)
    },
])
