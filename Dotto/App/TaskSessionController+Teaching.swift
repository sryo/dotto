import AppKit

/// Teach-once flow: the user demonstrates the first item, Claude compiles the recording into a routine, and the
/// user reviews it before it replays.
extension TaskSessionController {
    func startTeachingFirstItem() {
        guard case .awaitingApproval(let checklist) = sessionState, attachedRoutine == nil,
              let firstPendingItem = checklist.includedItems.first(where: { $0.runStatus == .pending }),
              apply(.demonstrationStarted(itemIdentifier: firstPendingItem.itemIdentifier)) else { return }
        recordedDemonstrationEventCount = 0
        demonstrationRecordingNotes = []
        demonstrationRecorder.startRecording(application: checklist.targetApplication)
        userInputObserver.startObserving(holderIdentifier: currentSession.demonstrationInputObservationHolderIdentifier,
                                          includingPointerMoves: true)
        cursorController.putCursorAway()
        checklistPanelController?.resignKeyWithoutHiding()
        // The user chose to demonstrate, so the target app must be in front for them; this is not Dotto taking focus.
        NSRunningApplication(processIdentifier: checklist.targetApplication.processIdentifier)?.activate()
        checklistPanelController?.showChecklistPanel(makeKey: false)
        statusLine = "Recording — do the item yourself"
        currentAuditLogWriter?.append(eventKind: .demonstration, itemIdentifier: firstPendingItem.itemIdentifier,
                                      message: "Teaching started", details: [:])
    }

    func finishTeaching() {
        guard case .demonstrating(let checklist, let itemIdentifier, false) = sessionState,
              let demonstratedItem = checklist.items.first(where: { $0.itemIdentifier == itemIdentifier }) else { return }
        let demonstrationRecording = demonstrationRecorder.stopRecording()
        userInputObserver.stopObserving(holderIdentifier: currentSession.demonstrationInputObservationHolderIdentifier)
        apply(.demonstrationRecordingStopped)
        guard let auditLogWriter = currentAuditLogWriter, let taskResourceBudget = currentTaskResourceBudget else {
            completeTeaching(statusLineAfterTeaching: "Couldn't learn a routine (Dotto isn't configured). It will use Claude for each item.")
            return
        }

        statusLine = "Learning the routine…"
        let teachingAbortSignal = TaskAbortSignal()
        currentTeachingAbortSignal = teachingAbortSignal
        let demonstrationRoutineCompiler = DemonstrationRoutineCompiler(transport: claudeTransport, auditLogWriter: auditLogWriter,
                                                                        taskResourceBudget: taskResourceBudget)
        Task { [weak self] in
            do {
                let taughtRoutine = try await demonstrationRoutineCompiler.compileRoutine(
                    from: demonstrationRecording, checklist: checklist, demonstratedItem: demonstratedItem,
                    routineIdentifier: "routine-" + checklist.taskIdentifier, abortSignal: teachingAbortSignal)
                guard let self, self.currentTeachingAbortSignal === teachingAbortSignal else { return }
                self.taughtRoutineAwaitingReview = taughtRoutine
                self.statusLine = "Review what Dotto learned"
            } catch {
                guard let self, self.currentTeachingAbortSignal === teachingAbortSignal else { return }
                let failureReason = TaskUserFacingMessages.userFacingDescription(ofDemonstrationCompileError: error)
                self.completeTeaching(statusLineAfterTeaching: "Couldn't learn a routine (\(failureReason)). Dotto will use Claude for each item.")
            }
        }
    }

    func saveTaughtRoutine() {
        guard let taughtRoutine = taughtRoutineAwaitingReview else { return }
        var statusLineAfterTeaching = "Routine ready — run the checklist to replay it"
        if let saveError = saveReviewedRoutine(taughtRoutine) {
            // The routine still replays for this task; it just won't be offered next time.
            statusLineAfterTeaching = "Couldn't save the routine (\(saveError.localizedDescription)); it's used for this task only"
        }
        attachedRoutine = taughtRoutine
        completeTeaching(statusLineAfterTeaching: statusLineAfterTeaching)
    }

    func discardTaughtRoutine() {
        completeTeaching(statusLineAfterTeaching: "Routine discarded. Dotto will use Claude for each item.")
    }

    func cancelTeaching() {
        guard isDemonstrating else { return }
        if demonstrationRecorder.isRecording {
            _ = demonstrationRecorder.stopRecording()
        }
        userInputObserver.stopObserving(holderIdentifier: currentSession.demonstrationInputObservationHolderIdentifier)
        currentTeachingAbortSignal?.abort()
        currentTeachingAbortSignal = nil
        taughtRoutineAwaitingReview = nil
        apply(.demonstrationCancelled)
        statusLine = TaskUserFacingMessages.reviewChecklistStatusLine
    }

    private func completeTeaching(statusLineAfterTeaching: String) {
        guard case .demonstrating(let checklist, let itemIdentifier, true) = sessionState else { return }
        currentTeachingAbortSignal = nil
        taughtRoutineAwaitingReview = nil
        let checklistWithDemonstratedItemDone = checklist.updatingItem(withIdentifier: itemIdentifier) { item in
            item.runStatus = .completed
            item.resultSummary = "Done by you while teaching"
        }
        apply(.demonstrationFinished(checklistWithDemonstratedItemDone))
        statusLine = statusLineAfterTeaching
        checklistPanelController?.showChecklistPanel(makeKey: false)
    }
}
