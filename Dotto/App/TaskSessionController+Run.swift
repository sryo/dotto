import AppKit

extension TaskSessionController {
    func approveChecklistAndRun() {
        guard case .awaitingApproval(let approvedChecklist) = sessionState,
              !approvedChecklist.includedItems.isEmpty,
              let auditLogWriter = currentAuditLogWriter,
              let abortSignal = currentAbortSignal,
              let taskResourceBudget = currentTaskResourceBudget else { return }
        guard apply(.checklistApproved(approvedChecklist)),
              case .executing(let executingChecklist, _) = sessionState else { return }
        if executingChecklist.directRoutePlan != nil {
            startDirectRouteRun(executingChecklist, auditLogWriter: auditLogWriter, abortSignal: abortSignal,
                                taskResourceBudget: taskResourceBudget)
            return
        }

        let targetApplicationName = executingChecklist.targetApplication.applicationName
        statusLine = "Dotto works in \(targetApplicationName) in the background. Keep using other apps; clicking or typing in \(targetApplicationName) pauses it."
        let runSummonOrigin = currentTaskSummonOriginInTopLeftGlobalPoints
        if runSummonOrigin != nil {
            // The checklist folds into the cursor's pill, which shows the progress with Pause and Stop; its chevron
            // opens the checklist again beside wherever the cursor is.
            checklistPanelController?.collapseIntoCursor()
        } else {
            // A saved routine run from the menu bar has no cursor until its window is known, so its checklist stays.
            checklistPanelController?.resignKeyWithoutHiding()
        }
        cursorController.targetApplicationName = targetApplicationName

        let runControl = TaskRunControl()
        currentRunControl = runControl
        let metricsAccumulator = TaskRunMetricsAccumulator(
            baselineModelCallsPerAgentItem: attachedRoutine?.modelCallsUsedWhenLearned.map(Double.init))
        currentRunMetrics = nil

        // The executor only ever talks to this run's proxy, so a stopped run that is still unwinding can't
        // touch the UI or confirmation state of a newer run.
        let runScopedDelegate = TaskRunDelegateBridge(taskSessionController: self, runAbortSignal: abortSignal)
        var executionOptions = TaskExecutionOptions()
        executionOptions.runControl = runControl
        executionOptions.focusPolicy = currentTaskFocusPolicy
        executionOptions.interactionHandler = runScopedDelegate
        executionOptions.routineToReplay = attachedRoutine
        executionOptions.metricsAccumulator = metricsAccumulator
        executionOptions.uploadFileAllowlist = currentUploadFileAllowlist
        executionOptions.foregroundAssistReadinessGate = runScopedDelegate
        let taskExecutor = TaskExecutor(
            transport: MeteredClaudeTransport(wrapping: claudeTransport, metricsAccumulator: metricsAccumulator),
            actionBackend: actionBackend,
            confirmationRequester: runScopedDelegate,
            observer: runScopedDelegate,
            auditLogWriter: auditLogWriter,
            taskResourceBudget: taskResourceBudget,
            options: executionOptions
        )
        userTakeoverDetector.reset()
        targetWindowObserver.startObserving(executingChecklist.targetApplication)
        userTakeoverDetector.rebaselinePinnedTargetWindowFrame(targetWindowObserver.pinnedTargetWindowFrameInTopLeftGlobalPoints)
        userInputObserver.startObserving(includingPointerMoves: false)
        // A routine run skips planning, so nothing else has waited for a stopped run to release the backend.
        let previousRunTask = mostRecentlyStartedRunTask
        let pauseAwareActionBackend = actionBackend as? AccessibilityActionBackend
        let executionTask = Task { [weak self] in
            await previousRunTask?.value
            // Only now: the previous run's finishTask (which may hide the cursor) is over, so it can't hide this one.
            if let self, self.currentAbortSignal === abortSignal, !abortSignal.isAborted {
                // The backend reports the task window with its first action.
                self.cursorController.beginRun(ownedByRunWith: abortSignal,
                                               startingAtSummonOriginInTopLeftGlobalPoints: runSummonOrigin)
            }
            await pauseAwareActionBackend?.attachRunControl(runControl, forRunWith: abortSignal)
            let runSummary = await taskExecutor.run(approvedChecklist: executingChecklist, abortSignal: abortSignal)
            // A newer task may have started after this one was stopped; its UI is not ours to touch.
            guard let self, self.currentAbortSignal === abortSignal else { return }
            // The executor already reported runFinished; the cursor shows done or stuck, then hides itself.
            self.stopRunObservers()
            self.stopRunAttentionTimers()
            self.currentRunMetrics = metricsAccumulator.currentMetrics
            // After Stop (including "Stop task" on a confirmation card) the state is already `aborted`.
            guard self.isExecutingOrPaused else { return }
            self.apply(.executionFinished(runSummary))
            self.statusLine = TaskUserFacingMessages.userFacingDescription(ofStopReason: runSummary.stopReason)
            // The summary (and a learned routine to review) opens beside the cursor while it shows done or stuck.
            self.checklistPanelController?.showChecklistPanel(makeKey: false)
        }
        currentPlanningOrExecutionTask = executionTask
        mostRecentlyStartedRunTask = executionTask
    }

    func cancelChecklist() {
        guard isAwaitingApproval else { return }
        currentAuditLogWriter?.append(eventKind: .taskAborted, itemIdentifier: nil,
                                      message: "User cancelled the plan before running it", details: [:])
        apply(.dismissed)
        cursorController.putCursorAway()
        closeTaskSession()
    }

    func stopTask() {
        guard sessionState.isBusy else { return }
        // The executor logs its own abort; planning has no such hook, so log it here.
        var wasPlanning = false
        if case .planning = sessionState {
            wasPlanning = true
            currentAuditLogWriter?.append(eventKind: .taskAborted, itemIdentifier: nil,
                                          message: "User stopped planning", details: [:])
        }
        // Read before the cursor goes: the stopped run's summary opens where the cursor was.
        let checklistAnchorBeforeStopping = checklistPanelAnchor()
        currentAbortSignal?.abort()
        currentPlanningOrExecutionTask?.cancel()
        cursorController.cancelCursorFlight()
        apply(.abortRequested)
        // Answered only after the state is `aborted`, so the executor's late events are ignored.
        pendingSafetyConfirmation.resume(with: .stopTask)
        pendingItemFailureDecision.resume(with: .stopTask)
        stopRunObservers()
        stopRunAttentionTimers()
        cursorController.putCursorAway()
        statusLine = "Stopped"
        restoreTargetAccessibilityModesInBackground()
        if wasPlanning {
            // Nothing ran and there is nothing to review: stopping planning just ends the task.
            apply(.dismissed)
            closeTaskSession()
        } else if checklistPanelController?.isVisible != true {
            checklistPanelController?.showChecklistPanel(makeKey: false, anchor: checklistAnchorBeforeStopping)
        }
    }

    func dismissFinishedTask() {
        guard apply(.dismissed) else { return }
        stopRunAttentionTimers()
        cursorController.putCursorAway()
        closeTaskSession()
    }

    /// The end of a task the user is done with: the panel goes away, and nothing of the task stays behind.
    func closeTaskSession() {
        // The reply field or a label field may hold the keyboard; it goes back to the user's app first.
        checklistPanelController?.collapseIntoCursor()
        statusLine = TaskUserFacingMessages.readyStatusLine
        resetPerTaskResources()
        restoreTargetAccessibilityModesInBackground()
    }

    func stopRunObservers() {
        userInputObserver.stopObserving()
        targetWindowObserver.stopObserving()
        visibilityMonitor.stopMonitoring()
    }

    /// Nothing about a run that ended keeps calling for the user: no pulsing icon, no countdown waiting on Cancel.
    /// The cursor's own nudges stop with runFinished or when it's put away.
    func stopRunAttentionTimers() {
        isMenuBarIconPulsing = false
        foregroundAssistCountdownWasCancelled = true
    }

    /// The backend restores the target's accessibility modes itself when a run finishes; this covers stops and
    /// dismissals that happen before or around that point. Restoring twice is harmless.
    private func restoreTargetAccessibilityModesInBackground() {
        guard let accessibilityActionBackend = actionBackend as? AccessibilityActionBackend else { return }
        Task { await accessibilityActionBackend.restoreTargetAccessibilityModes() }
    }

    // MARK: - Learned routine review

    func saveLearnedRoutine() {
        guard let learnedRoutine = learnedRoutineAwaitingReview else { return }
        learnedRoutineAwaitingReview = nil
        if let saveError = saveReviewedRoutine(learnedRoutine) {
            statusLine = "Couldn't save the routine (\(saveError.localizedDescription))"
        } else {
            statusLine = "Routine saved"
        }
    }

    func discardLearnedRoutine() {
        learnedRoutineAwaitingReview = nil
    }
}
