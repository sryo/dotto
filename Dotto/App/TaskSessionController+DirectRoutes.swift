import AppKit

/// Direct routes: file operations, a script or one of the user's shortcuts, run without the cursor. This builds what
/// the planner is told (the scope folders, whether the target app is scriptable, its Automation state), runs an
/// approved direct plan through `DirectRouteExecutor` instead of `TaskExecutor`, and undoes a file-operations task
/// from its journal.
extension TaskSessionController {
    static let finderBundleIdentifier = "com.apple.finder"

    // MARK: - Before planning

    /// Scope folders come only from the user: the Finder window they summoned Dotto over, folders they attached, and
    /// folder paths they typed in the command. Each candidate is canonicalized and must pass
    /// `FileOperationScopePolicy`; refused ones are dropped and audited. The one prompt here is macOS asking, once, to
    /// let Dotto read which folder a Finder window shows.
    func makePlannerDirectRouteContext(commandText: String, targetApplication: TargetApplicationReference) async -> PlannerDirectRouteContext {
        if directRouteSessionState.directRoutesAreDisabledForNextPlanning {
            directRouteSessionState.directRoutesAreDisabledForNextPlanning = false
            return .disabled
        }
        guard let directRouteExecutionDependencies else { return .disabled }
        let homeDirectoryPath = directRouteExecutionDependencies.homeDirectoryPath

        var scopeRootCandidates: [DirectRouteScopeRootCandidate] = []
        let targetApplicationIsFinder = targetApplication.bundleIdentifier == Self.finderBundleIdentifier
        var finderWindowContents: FinderWindowContents?
        if targetApplicationIsFinder {
            finderWindowContents = await FinderWindowFolderResolver.windowContents(
                forFinderProcessIdentifier: targetApplication.processIdentifier,
                summonOriginInTopLeftGlobalPoints: currentTaskSummonOriginInTopLeftGlobalPoints,
                mayPromptForAutomation: currentTaskFocusPolicy.allowsForegroundAssist)
        }
        if let finderWindowContents {
            scopeRootCandidates.append(DirectRouteScopeRootCandidate(path: finderWindowContents.folderPath,
                                                                     source: .finderWindowUnderSummonPoint))
        }
        for attachedFolderGrant in currentUploadFileAllowlist.grants where attachedFolderGrant.isDirectory {
            scopeRootCandidates.append(DirectRouteScopeRootCandidate(path: attachedFolderGrant.canonicalPath, source: .attachedByUser))
        }
        for typedFolderPath in CommandPathExtractor.candidateFolderPaths(inUserText: commandText, homeDirectoryPath: homeDirectoryPath) {
            scopeRootCandidates.append(DirectRouteScopeRootCandidate(path: typedFolderPath, source: .typedInCommand))
        }

        let fileSystemReader = directRouteExecutionDependencies.fileSystemReader
        let candidatesToEvaluate = scopeRootCandidates
        // realpath and lstat can wait on a slow or network volume, so they run off the main actor.
        let scopeResolution = await Task.detached(priority: .userInitiated) {
            Self.resolveDirectRouteScope(fromCandidates: candidatesToEvaluate, fileSystemReader: fileSystemReader,
                                         homeDirectoryPath: homeDirectoryPath)
        }.value

        // A selected item counts only when its real folder is an accepted scope root, like every path the planner reads.
        let selectedItemPathsToCanonicalize = finderWindowContents?.selectedItemPaths ?? []
        let acceptedScopeRootPaths = Set(scopeResolution.scope.roots.map(\.canonicalPath))
        let finderSelectionPaths = await Task.detached(priority: .userInitiated) {
            selectedItemPathsToCanonicalize.compactMap { selectedItemPath -> String? in
                guard let resolvedParentFolderPath = fileSystemReader.canonicalExistingFolderPath(
                          (selectedItemPath as NSString).deletingLastPathComponent),
                      acceptedScopeRootPaths.contains(resolvedParentFolderPath) else { return nil }
                return (resolvedParentFolderPath as NSString).appendingPathComponent((selectedItemPath as NSString).lastPathComponent)
            }
        }.value

        let scriptRunner = directRouteExecutionDependencies.scriptRunner
        var targetApplicationIsScriptable = false
        if currentTaskFocusPolicy.allowsForegroundAssist, let targetBundleIdentifier = targetApplication.bundleIdentifier {
            targetApplicationIsScriptable = await Task.detached(priority: .userInitiated) {
                ScriptabilityProbe.isRunningApplicationScriptable(bundleIdentifier: targetBundleIdentifier)
            }.value
        }
        var targetApplicationAutomationState = AutomationPermissionState.unknown
        if targetApplicationIsScriptable, let targetBundleIdentifier = targetApplication.bundleIdentifier {
            // Never prompts here: macOS asks only once the user has clicked Run on a script.
            targetApplicationAutomationState = await scriptRunner.automationPermission(forBundleIdentifier: targetBundleIdentifier,
                                                                                       mayPromptUser: false)
        }

        for refusedCandidate in scopeResolution.refusedCandidates {
            currentAuditLogWriter?.append(eventKind: .directRouteValidation, itemIdentifier: nil,
                                          message: "Scope folder refused",
                                          details: ["path": refusedCandidate.path, "source": refusedCandidate.source.rawValue,
                                                    "reason": refusedCandidate.reason])
        }
        currentAuditLogWriter?.append(eventKind: .directRouteValidation, itemIdentifier: nil,
                                      message: "Direct route context",
                                      details: ["scope_roots": scopeResolution.scope.roots.map(\.canonicalPath).joined(separator: "\n"),
                                                "scriptable": targetApplicationIsScriptable ? "yes" : "no",
                                                "automation": targetApplicationAutomationState.rawValue,
                                                "finder_selection_count": String(finderSelectionPaths.count)])
        return PlannerDirectRouteContext(scope: scopeResolution.scope,
                                         targetApplicationIsScriptable: targetApplicationIsScriptable,
                                         targetApplicationAutomationState: targetApplicationAutomationState,
                                         directRoutesAreEnabled: true,
                                         focusPolicy: currentTaskFocusPolicy,
                                         targetApplicationIsFinder: targetApplicationIsFinder,
                                         finderSelectionPaths: finderSelectionPaths)
    }

    /// Canonicalizes each candidate (it must be an existing folder, not a package), applies the root allowlist,
    /// drops duplicates and keeps at most `DirectRouteScope.maximumRootCount` roots, in the order given.
    nonisolated static func resolveDirectRouteScope(fromCandidates scopeRootCandidates: [DirectRouteScopeRootCandidate],
                                                    fileSystemReader: DirectRouteFileSystemReading,
                                                    homeDirectoryPath: String) -> DirectRouteScopeResolution {
        var acceptedRoots: [DirectRouteScopeRoot] = []
        var refusedCandidates: [DirectRouteScopeResolution.RefusedCandidate] = []
        for scopeRootCandidate in scopeRootCandidates {
            guard let canonicalFolderPath = fileSystemReader.canonicalExistingFolderPath(scopeRootCandidate.path) else {
                refusedCandidates.append(.init(path: scopeRootCandidate.path, source: scopeRootCandidate.source,
                                               reason: "not an existing folder"))
                continue
            }
            guard !acceptedRoots.contains(where: { $0.canonicalPath == canonicalFolderPath }) else { continue }
            guard acceptedRoots.count < DirectRouteScope.maximumRootCount else {
                refusedCandidates.append(.init(path: canonicalFolderPath, source: scopeRootCandidate.source,
                                               reason: "more than \(DirectRouteScope.maximumRootCount) scope folders"))
                continue
            }
            switch FileOperationScopePolicy.evaluateScopeRootCandidate(canonicalFolderPath: canonicalFolderPath,
                                                                       source: scopeRootCandidate.source,
                                                                       isPackage: false, homeDirectoryPath: homeDirectoryPath) {
            case .accepted(let acceptedRoot):
                acceptedRoots.append(acceptedRoot)
            case .refused(let reason):
                refusedCandidates.append(.init(path: canonicalFolderPath, source: scopeRootCandidate.source, reason: reason))
            }
        }
        return DirectRouteScopeResolution(scope: DirectRouteScope(roots: acceptedRoots), refusedCandidates: refusedCandidates)
    }

    // MARK: - Running

    /// Mirrors `approveChecklistAndRun`, without anything the cursor route needs: no user-input or window
    /// observation (nothing a direct route does depends on the target window, so the user may keep working in it),
    /// no backend run control and no `prepareForTask`, so accessibility modes are never touched and Dotto takes no
    /// focus. Pause and Stop still work through `TaskRunControl` and the abort signal.
    func startDirectRouteRun(_ executingChecklist: Checklist, auditLogWriter: AuditLogWriter,
                             abortSignal: TaskAbortSignal, taskResourceBudget: TaskResourceBudget) {
        let runSummonOrigin = currentTaskSummonOriginInTopLeftGlobalPoints
        statusLine = "Running directly, without the cursor…"
        if runSummonOrigin != nil {
            checklistPanelController?.collapseIntoCursor()
        } else {
            checklistPanelController?.resignKeyWithoutHiding()
        }
        cursorController.targetApplicationName = executingChecklist.targetApplication.applicationName
        directRouteSessionState.beginRun()

        let runControl = TaskRunControl()
        currentRunControl = runControl
        currentRunMetrics = nil
        userTakeoverDetector.reset()

        guard let directRouteExecutionDependencies else {
            // Unreachable in practice: without dependencies the planner is never offered direct routes.
            apply(.executionFinished(TaskRunSummary.summarize(
                checklist: executingChecklist, stopReason: .unrecoverableError("Direct routes aren't available"))))
            checklistPanelController?.showChecklistPanel(makeKey: false)
            return
        }
        let runScopedDelegate = TaskRunDelegateBridge(taskSessionController: self, runAbortSignal: abortSignal)
        let directRouteExecutor = DirectRouteExecutor(
            dependencies: directRouteExecutionDependencies,
            confirmationRequester: runScopedDelegate,
            observer: runScopedDelegate,
            auditLogWriter: auditLogWriter,
            taskResourceBudget: taskResourceBudget,
            runControl: runControl,
            focusPolicy: currentTaskFocusPolicy)
        let previousRunTask = mostRecentlyStartedRunTask
        let undoTaskInProgress = directRouteSessionState.currentUndoTask
        let executionTask = Task { [weak self] in
            await previousRunTask?.value
            // Files an undo is still putting back must not be moved again underneath it.
            await undoTaskInProgress?.value
            if let self, self.currentAbortSignal === abortSignal, !abortSignal.isAborted, runSummonOrigin != nil {
                // The cursor stays parked at the summon point for the whole run: no window, no flight.
                self.cursorController.beginRun(ownedByRunWith: abortSignal, startingAtSummonOriginInTopLeftGlobalPoints: runSummonOrigin)
            }
            let directRouteRunSummary = await directRouteExecutor.run(approvedChecklist: executingChecklist, abortSignal: abortSignal)
            guard let self, self.currentAbortSignal === abortSignal else { return }
            self.stopRunAttentionTimers()
            // Kept even after Stop: what already changed can still be undone from the stopped task's summary.
            self.directRouteSessionState.lastRunReport = directRouteRunSummary.report
            self.directRouteSessionState.runProgress = nil
            self.refreshMostRecentUndoableJournal()
            guard self.isExecutingOrPaused else { return }
            self.apply(.executionFinished(directRouteRunSummary.taskRunSummary))
            self.statusLine = TaskUserFacingMessages.userFacingDescription(ofStopReason: directRouteRunSummary.taskRunSummary.stopReason)
            self.checklistPanelController?.showChecklistPanel(makeKey: false)
        }
        currentPlanningOrExecutionTask = executionTask
        mostRecentlyStartedRunTask = executionTask
    }

    /// The executor's operation count, kept for the panel's progress view (the pill gets it from the cursor event).
    func recordDirectRouteProgress(from cursorActivityEvent: CursorActivityEvent) {
        guard case .directOperationProgressed(let completedCount, let totalCount, let operationDescription) = cursorActivityEvent else { return }
        directRouteSessionState.runProgress = DirectRouteRunProgress(completedCount: completedCount, totalCount: totalCount,
                                                                     operationDescription: operationDescription)
    }

    // MARK: - After the run

    /// Reverses a file-operations task from its journal, newest change first. Undo never overwrites and never
    /// deletes: a change it can't reverse safely is left as it is and reported.
    func undoDirectRouteTask(journalIdentifier: String) {
        guard let directRouteExecutionDependencies, !directRouteSessionState.isUndoInProgress, !sessionState.isBusy else { return }
        // Into the task's own log while its summary is open, otherwise into a log of its own.
        let undoAuditLogWriter: AuditLogWriter?
        if sessionState.currentChecklist?.taskIdentifier == journalIdentifier, let currentAuditLogWriter {
            undoAuditLogWriter = currentAuditLogWriter
        } else {
            undoAuditLogWriter = try? AuditLogWriter(taskIdentifier: "\(journalIdentifier)-undo")
        }
        let undoRunner = FileOperationUndoRunner(fileSystem: directRouteExecutionDependencies.fileSystem,
                                                 journalStore: directRouteExecutionDependencies.journalStore,
                                                 auditLogWriter: undoAuditLogWriter,
                                                 homeDirectoryPath: directRouteExecutionDependencies.homeDirectoryPath)
        let directRouteSessionState = self.directRouteSessionState
        directRouteSessionState.undoJournalIdentifier = journalIdentifier
        directRouteSessionState.lastUndoReport = nil
        directRouteSessionState.undoFailureMessage = nil
        directRouteSessionState.undoProgress = nil
        directRouteSessionState.undoIsRunning = true
        statusLine = "Undoing…"
        let undoAbortSignal = TaskAbortSignal()
        directRouteSessionState.currentUndoAbortSignal = undoAbortSignal
        directRouteSessionState.currentUndoTask = Task { [weak self] in
            do {
                // The undo runs off the main actor (`@concurrent`); only its progress reports hop back here.
                let undoReport = try await undoRunner.undo(journalIdentifier: journalIdentifier, abortSignal: undoAbortSignal,
                                                           onProgress: { undoProgress in
                    await MainActor.run { directRouteSessionState.undoProgress = undoProgress }
                })
                directRouteSessionState.lastUndoReport = undoReport
                self?.statusLine = undoReport.skippedCount == 0 ? "Undone" : "Partly undone"
            } catch {
                directRouteSessionState.undoFailureMessage = "Couldn't undo the task (\(error.localizedDescription))."
                self?.statusLine = "Undo failed"
            }
            directRouteSessionState.undoProgress = nil
            directRouteSessionState.undoIsRunning = false
            directRouteSessionState.currentUndoTask = nil
            directRouteSessionState.currentUndoAbortSignal = nil
            self?.refreshMostRecentUndoableJournal()
        }
    }


    /// Reads the newest undoable journal for the menu bar's "Undo last task" row, a partly undone one included.
    func refreshMostRecentUndoableJournal() {
        guard let journalStore = directRouteExecutionDependencies?.journalStore,
              let journalIdentifier = journalStore.mostRecentUndoableJournalIdentifier(),
              let loadedJournal = try? journalStore.loadJournal(journalIdentifier),
              loadedJournal.isUndoable else {
            directRouteSessionState.mostRecentUndoableJournal = nil
            return
        }
        let journalIsStillRunningInThisSession = loadedJournal.status == .running
            && sessionState.currentChecklist?.taskIdentifier == journalIdentifier && sessionState.isBusy
        directRouteSessionState.mostRecentUndoableJournal = UndoableJournalSummary(
            journalIdentifier: journalIdentifier,
            taskTitle: loadedJournal.header.taskTitle,
            changeCount: loadedJournal.entriesNotYetReverted.count,
            finishedAt: loadedJournal.entries.last?.performedAt ?? loadedJournal.header.startedAt,
            wasInterrupted: loadedJournal.status == .interrupted
                || (loadedJournal.status == .running && !journalIsStillRunningInThisSession),
            wasPartiallyUndone: loadedJournal.status == .partiallyUndone)
    }

    /// Shows the scope folders of the finished file-operations task in Finder.
    func revealDirectRouteScopeInFinder() {
        guard case .fileOperations(let fileOperationsPlan) = sessionState.currentChecklist?.directRoutePlan else { return }
        let scopeRootURLs = fileOperationsPlan.scope.roots.map { URL(fileURLWithPath: $0.canonicalPath, isDirectory: true) }
        guard !scopeRootURLs.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(scopeRootURLs)
    }

    // MARK: - Planning the same command again

    /// "Use the cursor instead" on a direct plan: the same command is planned again with direct routes off, so it
    /// comes back as an ordinary checklist.
    func replanUsingCursorInstead() {
        guard case .awaitingApproval(let checklist) = sessionState, checklist.directRoutePlan != nil else { return }
        currentAuditLogWriter?.append(eventKind: .taskAborted, itemIdentifier: nil,
                                      message: "User chose the cursor instead of the direct route", details: [:])
        guard apply(.dismissed) else { return }
        submitSameCommandAgain(checklist, directRoutesAreEnabled: false)
    }

    /// The run-time check refused the plan because the folder changed: plan the same command again from what is
    /// there now.
    func planAgainAfterDirectRouteValidationFailure() {
        guard !sessionState.isBusy, let checklist = sessionState.currentChecklist, checklist.directRoutePlan != nil else { return }
        guard apply(.dismissed) else { return }
        stopRunAttentionTimers()
        submitSameCommandAgain(checklist, directRoutesAreEnabled: true)
    }

    /// Ends the current task and submits its command again, against the same app, from the same summon point and
    /// with the same attachments.
    private func submitSameCommandAgain(_ checklist: Checklist, directRoutesAreEnabled: Bool) {
        let summonOrigin = currentTaskSummonOriginInTopLeftGlobalPoints
        let attachedGrants = currentUploadFileAllowlist.grants
        closeTaskSession()
        targetApplication = checklist.targetApplication
        summonOriginOfNextCommandInTopLeftGlobalPoints = summonOrigin
        attachedUploadGrants = attachedGrants
        directRouteSessionState.directRoutesAreDisabledForNextPlanning = !directRoutesAreEnabled
        submitCommand(checklist.originalCommand)
    }
}

/// A folder the user pointed at, before it is canonicalized and checked.
struct DirectRouteScopeRootCandidate: Sendable {
    var path: String
    var source: DirectRouteScopeRootSource
}

struct DirectRouteScopeResolution: Sendable {
    struct RefusedCandidate: Sendable {
        var path: String
        var source: DirectRouteScopeRootSource
        var reason: String
    }

    var scope: DirectRouteScope
    var refusedCandidates: [RefusedCandidate]
}
