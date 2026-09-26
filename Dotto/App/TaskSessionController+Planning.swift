import AppKit

/// From a typed command to a checklist the user reviews: the task's resources are created before planning, so the
/// planner draws on the same task-wide budget as the run, and the plan can be edited until it is approved. While it
/// plans there is no card: Dotto's cursor appears where the user summoned it, reading and then thinking, with Stop in
/// its pill. The first panel the user sees is the checklist, attached to that cursor.
extension TaskSessionController {
    func submitCommand(_ commandText: String) {
        let trimmedCommandText = commandText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommandText.isEmpty, !sessionState.isBusy else { return }

        // Only while Dotto holds the keyboard (the command bar is key, or Dotto's own file picker activated it):
        // handing it back to where the user was restores their focus, it doesn't take anyone's.
        let thisAppHoldsKeyboard = NSApp.keyWindow != nil || NSApp.isActive
        let submittedCommandPill = commandBarPanelController?.hideCommandBarAfterSubmitting(submittedCommandText: trimmedCommandText)
        if thisAppHoldsKeyboard, let applicationFrontmostWhenCommandBarWasSummoned,
           applicationFrontmostWhenCommandBarWasSummoned.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            applicationFrontmostWhenCommandBarWasSummoned.activate()
        }
        lastSubmittedCommandText = trimmedCommandText
        commandSubmittedAtSystemUptime = ProcessInfo.processInfo.systemUptime
        frontmostApplicationProcessIdentifierWhenCommandWasSubmitted = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let previousRunTask = mostRecentlyStartedRunTask
        resetPerTaskResources()
        let uploadFileAllowlist = UploadFileAllowlist(grants: attachedUploadGrants)
        let attachedFilePathsForPrompt = UploadFilePathResolver.filePathsForPlannerPrompt(from: attachedUploadGrants)
        currentUploadFileAllowlist = uploadFileAllowlist
        attachedUploadGrants = []
        guard apply(.commandSubmitted(trimmedCommandText)) else { return }
        statusLine = "Planning…"
        plannerConversationTranscript = PlannerConversationTranscript(command: trimmedCommandText)
        currentPlanningProgress = nil
        currentTaskSummonOriginInTopLeftGlobalPoints = summonOriginOfNextCommandInTopLeftGlobalPoints
        // The previous task's checklist folds away; this task's cursor speaks from the summon point instead.
        checklistPanelController?.hideChecklistPanel()

        guard hasAnthropicAPIKey else {
            failPlanningBeforeItStarts(TaskUserFacingMessages.missingAnthropicAPIKeyMessage)
            showAnthropicAPIKeySetup()
            return
        }
        guard let targetApplication else {
            failPlanningBeforeItStarts("No target app. Click into the app you want Dotto to work in, then press \(summonHotkey.displayText).")
            return
        }
        // The app may have quit while the command was typed, and its process id could even belong to another app now.
        guard let runningTargetApplication = NSRunningApplication(processIdentifier: targetApplication.processIdentifier),
              !runningTargetApplication.isTerminated,
              runningTargetApplication.bundleIdentifier == targetApplication.bundleIdentifier else {
            failPlanningBeforeItStarts(TaskUserFacingMessages.targetApplicationQuitMessage(applicationName: targetApplication.applicationName))
            return
        }

        let taskStartResources: TaskStartResources
        do {
            taskStartResources = try makeTaskStartResources(targetApplication: targetApplication, auditMessage: trimmedCommandText)
        } catch {
            failPlanningBeforeItStarts(TaskUserFacingMessages.taskLogCreationFailedMessage(describing: error))
            return
        }
        adoptTaskStartResources(taskStartResources)
        if let summonOrigin = currentTaskSummonOriginInTopLeftGlobalPoints {
            // Submitted from the pill at the pointer: the cursor's status pill takes the capsule's place, and the pill
            // morphs into it first unless Reduce Motion is on.
            let morphsCommandPill = submittedCommandPill?.morphsIntoStatusPill ?? false
            cursorController.beginPlanning(atSummonOriginInTopLeftGlobalPoints: summonOrigin,
                                           targetApplicationName: targetApplication.applicationName,
                                           commandPillHandoff: submittedCommandPill?.commandPillHandoff,
                                           holdsStatusPillForMorph: morphsCommandPill)
            if let submittedCommandPill, morphsCommandPill {
                morphSubmittedCommandPillIntoStatusPill(submittedCommandPill)
            }
        } else {
            // Nowhere to put the cursor: the planning card (with its Stop) stands in for it.
            checklistPanelController?.showChecklistPanel(makeKey: false)
        }
        let auditLogWriter = taskStartResources.auditLogWriter
        let abortSignal = taskStartResources.abortSignal
        let checklistPlanner = ChecklistPlanner(transport: claudeTransport, actionBackend: taskStartResources.actionBackend, auditLogWriter: auditLogWriter,
                                                taskResourceBudget: taskStartResources.taskResourceBudget)
        checklistPlanner.uploadFileAllowlist = uploadFileAllowlist
        checklistPlanner.focusPolicy = currentTaskFocusPolicy
        checklistPlanner.attachedFilePathsForPrompt = attachedFilePathsForPrompt
        currentChecklistPlanner = checklistPlanner
        let onPlanningProgress = planningProgressHandler(for: abortSignal)

        let planningTask = Task { [weak self] in
            // The previous run shares the ActionBackend; preparing it while that run is still finishing
            // would reset element ids and state underneath it.
            await previousRunTask?.value
            do {
                try abortSignal.throwIfAborted()
                // Resolving the Finder window's folder and the app's scriptability is async, so it happens here.
                if let self {
                    let plannerDirectRouteContext = await self.makePlannerDirectRouteContext(commandText: trimmedCommandText,
                                                                                            targetApplication: targetApplication)
                    try abortSignal.throwIfAborted()
                    guard self.currentAbortSignal === abortSignal else { return }
                    self.directRouteSessionState.currentPlannerContext = plannerDirectRouteContext
                    checklistPlanner.directRouteContext = plannerDirectRouteContext
                    checklistPlanner.directRouteFileSystemReader = self.directRouteExecutionDependencies?.fileSystemReader
                    checklistPlanner.shortcutRunner = self.directRouteExecutionDependencies?.shortcutRunner
                }
                let planningResult = try await checklistPlanner.produceChecklist(
                    command: trimmedCommandText,
                    targetApplication: targetApplication,
                    taskIdentifier: taskStartResources.taskIdentifier,
                    abortSignal: abortSignal,
                    onProgress: onPlanningProgress
                )
                guard let self, self.currentAbortSignal === abortSignal, !abortSignal.isAborted else { return }
                self.showPlanningResult(planningResult)
            } catch {
                guard let self, self.currentAbortSignal === abortSignal, !abortSignal.isAborted else { return }
                self.showPlanningFailure(error, auditLogWriter: auditLogWriter)
            }
        }
        currentPlanningOrExecutionTask = planningTask
        mostRecentlyStartedRunTask = planningTask
    }

    private func morphSubmittedCommandPillIntoStatusPill(_ submittedCommandPill: SubmittedCommandPill) {
        guard let commandBarPanelController,
              let heldStatusPillFrame = cursorController.heldStatusPillFrameForCommandPillHandoff else {
            cursorController.finishCommandPillHandoff()
            return
        }
        commandBarPanelController.morphSubmittedCommandPill(
            submittedCommandPill, intoStatusPillAt: heldStatusPillFrame, cursorViewModel: cursorController.viewModel,
            onMorphFinished: { [weak self] in self?.cursorController.finishCommandPillHandoff() })
    }

    // MARK: - The planning thread

    /// The user answered Dotto's question, with a choice's label or their own words: the answer joins the thread and
    /// the planner carries on in the same conversation.
    func sendPlannerReply(_ replyText: String) {
        let trimmedReplyText = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedReplyText.isEmpty,
              case .plannerNeedsInput(_, let plannerQuestion) = sessionState, plannerQuestion.acceptsReply,
              let checklistPlanner = currentChecklistPlanner,
              let abortSignal = currentAbortSignal,
              let auditLogWriter = currentAuditLogWriter else { return }
        guard apply(.plannerReplySent) else { return }
        plannerConversationTranscript.appendUserMessage(trimmedReplyText)
        statusLine = "Planning…"
        currentPlanningProgress = .thinking
        cursorController.resumePlanningAfterReply()
        let onPlanningProgress = planningProgressHandler(for: abortSignal)

        let planningTask = Task { [weak self] in
            do {
                let planningResult = try await checklistPlanner.continuePlanning(
                    withUserReply: trimmedReplyText, abortSignal: abortSignal, onProgress: onPlanningProgress)
                guard let self, self.currentAbortSignal === abortSignal, !abortSignal.isAborted else { return }
                self.showPlanningResult(planningResult)
            } catch {
                guard let self, self.currentAbortSignal === abortSignal, !abortSignal.isAborted else { return }
                self.showPlanningFailure(error, auditLogWriter: auditLogWriter)
            }
        }
        currentPlanningOrExecutionTask = planningTask
        mostRecentlyStartedRunTask = planningTask
    }

    private func planningProgressHandler(for abortSignal: TaskAbortSignal) -> @MainActor @Sendable (ChecklistPlanningProgress) -> Void {
        { [weak self] planningProgress in
            guard let self, self.currentAbortSignal === abortSignal, !abortSignal.isAborted else { return }
            self.statusLine = planningProgress.statusLineText
            self.currentPlanningProgress = planningProgress
            self.cursorController.showPlanningProgress(planningProgress)
        }
    }

    private func showPlanningResult(_ planningResult: ChecklistPlanningResult) {
        currentPlanningProgress = nil
        switch planningResult {
        case .checklist(let producedChecklist):
            apply(.checklistProduced(producedChecklist))
            statusLine = TaskUserFacingMessages.reviewChecklistStatusLine
            cursorController.showChecklistReadyForReview()
            checklistPanelController?.showChecklistPanel(makeKey: false)
            // The reply field is gone; reviewing the checklist doesn't need the keyboard.
            checklistPanelController?.resignKeyWithoutHiding()
        case .question(let plannerQuestion):
            apply(.plannerAskedForInput(plannerQuestion))
            plannerConversationTranscript.appendPlannerQuestion(plannerQuestion)
            statusLine = CursorPresentationStateMapper.plannerNeedsInputStatusText
            cursorController.showPlannerNeedsInput()
            // Only a user still waiting on Dotto gets the reply field focused; someone who went back to work keeps
            // their keyboard, and the pill, chime and pulse call them over instead.
            if userIsStillWaitingOnDotto() {
                checklistPanelController?.showPlannerReplyField()
            } else {
                checklistPanelController?.showChecklistPanel(makeKey: false)
                checklistPanelController?.resignKeyWithoutHiding()
            }
        case .cannotPlan(let messageToUser):
            let blockingExplanation = PlannerQuestion.blockingExplanation(messageToUser)
            apply(.plannerAskedForInput(blockingExplanation))
            plannerConversationTranscript.appendPlannerQuestion(blockingExplanation)
            statusLine = CursorPresentationStateMapper.plannerNeedsInputStatusText
            cursorController.showPlannerNeedsInput()
            checklistPanelController?.showChecklistPanel(makeKey: false)
            checklistPanelController?.resignKeyWithoutHiding()
        }
    }

    /// True when the app that was in front at submit is still in front and there has been no real click, scroll or
    /// key since. Unknown input history counts as "moved on", so Dotto never takes a keyboard it can't account for.
    private func userIsStillWaitingOnDotto() -> Bool {
        guard let commandSubmittedAtSystemUptime,
              let frontmostApplicationProcessIdentifierWhenCommandWasSubmitted,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmostApplicationProcessIdentifierWhenCommandWasSubmitted,
              let secondsSinceLastRealUserInput = ForegroundAssistReadinessProbe.currentInputs().secondsSinceLastRealUserInput
        else { return false }
        let secondsSinceSubmit = ProcessInfo.processInfo.systemUptime - commandSubmittedAtSystemUptime
        // The Return key that submitted the command is itself a real key press, so allow a short margin for it.
        return secondsSinceLastRealUserInput >= secondsSinceSubmit - 0.5
    }

    private func showPlanningFailure(_ error: Error, auditLogWriter: AuditLogWriter) {
        currentPlanningProgress = nil
        auditLogWriter.append(eventKind: .error, itemIdentifier: nil, message: "\(error)", details: [:])
        apply(.planningFailed(TaskUserFacingMessages.userFacingDescription(ofPlanningError: error)))
        statusLine = "Planning failed"
        // The cursor goes; the failure card hangs from the point it was summoned at.
        cursorController.putCursorAway()
        checklistPanelController?.showChecklistPanel(makeKey: false)
        checklistPanelController?.resignKeyWithoutHiding()
    }

    /// Planning couldn't start (no key, no target, the app quit, no log): the failure card opens beside the summon
    /// point, since no cursor came up.
    private func failPlanningBeforeItStarts(_ failureReason: String) {
        apply(.planningFailed(failureReason))
        checklistPanelController?.showChecklistPanel(makeKey: false)
    }

    // MARK: - Checklist editing

    func setItemIncluded(itemIdentifier: String, isIncluded: Bool) {
        guard case .awaitingApproval(let checklist) = sessionState else { return }
        let editedChecklist = checklist.updatingItem(withIdentifier: itemIdentifier) { item in
            item.isIncludedByUser = isIncluded
        }
        apply(.checklistEdited(editedChecklist))
    }

    func editItemLabel(itemIdentifier: String, newLabel: String) {
        guard case .awaitingApproval(let checklist) = sessionState else { return }
        let editedChecklist = checklist.updatingItem(withIdentifier: itemIdentifier) { item in
            guard item.label != newLabel else { return }
            item.label = newLabel
            item.wasLabelEditedByUser = true
        }
        apply(.checklistEdited(editedChecklist))
    }
}
