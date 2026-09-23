import AppKit

/// The saved routine library (reload, save, delete), "run on a list" and "run on a folder", which build a checklist
/// from a saved routine without planning, and the files attached to the next task.
extension TaskSessionController {
    func reloadSavedRoutines() {
        let routineLibraryContents = routineLibraryStore.loadRoutineLibrary()
        savedRoutines = routineLibraryContents.routines
        skippedRoutineFiles = routineLibraryContents.skippedFiles
    }

    /// Saves a routine the user reviewed and chose to keep, and refreshes the library list either way.
    /// Returns the error when saving failed.
    func saveReviewedRoutine(_ reviewedRoutine: Routine) -> Error? {
        defer { reloadSavedRoutines() }
        do {
            try routineLibraryStore.save(reviewedRoutine)
        } catch {
            return error
        }
        currentAuditLogWriter?.append(eventKind: .routineSaved, itemIdentifier: nil, message: reviewedRoutine.name,
                                      details: ["routine": reviewedRoutine.routineIdentifier])
        return nil
    }

    func revealRoutineLibraryFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([RoutineLibraryStore.defaultDirectoryURL])
    }

    func deleteSavedRoutine(routineIdentifier: String) {
        try? routineLibraryStore.deleteRoutine(withIdentifier: routineIdentifier)
        reloadSavedRoutines()
    }

    func prepareRoutineRun(routineIdentifier: String, pastedListText: String) -> String? {
        guard let routine = savedRoutines.first(where: { $0.routineIdentifier == routineIdentifier }) else {
            return TaskUserFacingMessages.routineNoLongerExistsMessage
        }
        switch RoutineChecklistFactory.parseListInput(pastedListText, parameterNames: routine.parameterNames) {
        case .failure(let parseError):
            return parseError.message
        case .success(let parameterSets):
            return prepareRoutineChecklist(routine: routine, parameterSets: parameterSets)
        }
    }

    /// Returns nil when the user cancels the folder picker as well as on success.
    func prepareRoutineRunFromFolder(routineIdentifier: String) -> String? {
        guard let routine = savedRoutines.first(where: { $0.routineIdentifier == routineIdentifier }) else {
            return TaskUserFacingMessages.routineNoLongerExistsMessage
        }
        let folderOpenPanel = NSOpenPanel()
        folderOpenPanel.canChooseDirectories = true
        folderOpenPanel.canChooseFiles = false
        folderOpenPanel.allowsMultipleSelection = false
        folderOpenPanel.prompt = "Use folder"
        folderOpenPanel.message = "Dotto runs “\(routine.name)” once for each file in the folder."
        guard runOpenPanelOwnedByThisApp(folderOpenPanel) == .OK, let folderURL = folderOpenPanel.url else { return nil }
        if UploadFileAllowlist.isRefusedGrantRoot(folderURL.resolvingSymlinksInPath().path) {
            return "That folder covers a whole disk or every user's files. Pick the folder that holds the files."
        }

        let folderEntryURLs = (try? FileManager.default.contentsOfDirectory(
            at: folderURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
        let regularFileURLs = folderEntryURLs.filter { folderEntryURL in
            (try? folderEntryURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        guard regularFileURLs.count <= Checklist.maximumItemCount else {
            return "That folder has \(regularFileURLs.count) files; Dotto runs at most \(Checklist.maximumItemCount) items at a time."
        }
        switch RoutineChecklistFactory.validatedParameterSets(forFileURLs: regularFileURLs, parameterNames: routine.parameterNames) {
        case .failure(let validationError):
            return validationError.message
        case .success(let parameterSets):
            let preparationProblem = prepareRoutineChecklist(routine: routine, parameterSets: parameterSets)
            // The folder the user just picked is the only thing this run may upload from.
            if preparationProblem == nil, let pickedFolderGrant = UploadFilePathResolver.makeUserPickedGrant(forPath: folderURL.path) {
                currentUploadFileAllowlist = UploadFileAllowlist(grants: [pickedFolderGrant])
            }
            return preparationProblem
        }
    }

    // MARK: - Attached files

    func chooseFilesToAttach() {
        let attachmentOpenPanel = NSOpenPanel()
        attachmentOpenPanel.canChooseFiles = true
        attachmentOpenPanel.canChooseDirectories = true
        attachmentOpenPanel.allowsMultipleSelection = true
        attachmentOpenPanel.prompt = "Attach"
        attachmentOpenPanel.message = "Dotto can upload only the files and folders you attach to this task."
        let attachmentPanelResponse = runOpenPanelOwnedByThisApp(attachmentOpenPanel)
        // Typing goes on in the command bar (a non-activating panel, so it can be key without Dotto being active).
        returnKeyboardToCommandBar()
        guard attachmentPanelResponse == .OK else { return }
        attachFilesForNextTask(urls: attachmentOpenPanel.urls)
    }

    func attachFilesForNextTask(urls: [URL]) {
        for attachedURL in urls where attachedURL.isFileURL {
            guard let uploadFileGrant = UploadFilePathResolver.makeUserPickedGrant(forPath: attachedURL.path),
                  !attachedUploadGrants.contains(where: { $0.canonicalPath == uploadFileGrant.canonicalPath }) else { continue }
            // Never honored for uploads, so it isn't listed as if it were.
            if UploadFileAllowlist.isRefusedGrantRoot(uploadFileGrant.canonicalPath) { continue }
            attachedUploadGrants.append(uploadFileGrant)
        }
    }

    func clearAttachedFiles() {
        attachedUploadGrants = []
    }

    /// Runs one of Dotto's own file pickers. A menu bar app is never active on its own, and an inactive app's open
    /// panel opens behind other windows, so Dotto activates for it; once it closes, activation goes back to the app
    /// the user was in.
    private func runOpenPanelOwnedByThisApp(_ openPanel: NSOpenPanel) -> NSApplication.ModalResponse {
        NSApp.activate()
        let openPanelResponse = openPanel.runModal()
        previousApplicationTracker.handActivationBackIfThisAppIsActive()
        return openPanelResponse
    }

    private func prepareRoutineChecklist(routine: Routine, parameterSets: [[ChecklistItemParameter]]) -> String? {
        guard !parameterSets.isEmpty else { return "There are no items to run. Add one line per item." }
        guard !sessionState.isBusy, !isDemonstrating else { return "Finish or stop the current task first." }
        guard hasAnthropicAPIKey else {
            showAnthropicAPIKeySetup()
            return TaskUserFacingMessages.missingAnthropicAPIKeyMessage
        }
        // Matching by display name alone could hand the routine's clicks and typing to a different app that happens
        // to share the name, so a routine without a bundle identifier is never run.
        guard let routineTargetBundleIdentifier = routine.targetApplicationBundleIdentifier else {
            return "“\(routine.name)” doesn't record which app it was made for, so Dotto won't run it. Teach it once more."
        }
        guard let routineTargetRunningApplication = NSRunningApplication
            .runningApplications(withBundleIdentifier: routineTargetBundleIdentifier).first else {
            return "Open \(routine.targetApplicationName) first, then try again."
        }

        if isAwaitingApproval {
            cancelChecklist()
        }
        resetPerTaskResources()
        let routineTargetApplication = TargetApplicationReference(
            processIdentifier: routineTargetRunningApplication.processIdentifier,
            applicationName: routineTargetRunningApplication.localizedName ?? routine.targetApplicationName,
            bundleIdentifier: routineTargetRunningApplication.bundleIdentifier
        )
        let taskStartResources: TaskStartResources
        do {
            taskStartResources = try makeTaskStartResources(
                targetApplication: routineTargetApplication, auditMessage: "Run routine on a list: \(routine.name)",
                additionalAuditDetails: ["routine": routine.routineIdentifier])
        } catch {
            return TaskUserFacingMessages.taskLogCreationFailedMessage(describing: error)
        }

        let routineChecklist = RoutineChecklistFactory.makeChecklist(routine: routine, parameterSets: parameterSets,
                                                                     targetApplication: routineTargetApplication,
                                                                     taskIdentifier: taskStartResources.taskIdentifier, now: Date())
        guard apply(.routineChecklistPrepared(routineChecklist)) else { return "Couldn't prepare the checklist." }
        targetApplication = routineTargetApplication
        adoptTaskStartResources(taskStartResources)
        attachedRoutine = routine
        statusLine = TaskUserFacingMessages.reviewChecklistStatusLine
        checklistPanelController?.showChecklistPanel(makeKey: false)
        return nil
    }
}
