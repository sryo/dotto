import AppKit
import ApplicationServices

/// upload_files: the allowlist is checked first, then the file control is pressed and the open panel driven inside
/// the user-approved foreground assist, with the only focused keyboard input Dotto ever sends (invariant 3c).
/// The press happens only once the app is in front: a panel opened in the background never becomes the key window,
/// so its keys would go to the window behind it. A panel is never left open: any error or abort cancels it before the
/// user's app comes back.
extension AccessibilityActionBackend {
    private static let openPanelWaitSeconds: TimeInterval = 5
    private static let attachedFileConfirmationWaitSeconds: TimeInterval = 3
    private static let attachedFileConfirmationPollNanoseconds: UInt64 = 200_000_000
    private static let maximumConfirmationSearchNodeCount = 3000
    /// Web content is deep; the walk up to the page only needs a cap against a parent chain that loops.
    private static let maximumPageAncestorWalkDepth = 200

    func uploadFiles(_ filePaths: [String], toElementWithIdentifier elementIdentifier: String,
                     context: ActionRunContext) async throws -> ActionOutcome {
        // The allowlist is re-checked here for agent steps and routine replay alike, so a saved routine can never
        // upload files from an earlier task.
        let allowlistDecision = uploadFileAllowlist.evaluate(
            requestedPaths: filePaths, canonicalizeExistingRegularFile: UploadFilePathResolver.canonicalizeExistingRegularFile)
        let canonicalFilePaths: [String]
        switch allowlistDecision {
        case .denied(let reasonForModel):
            throw ActionBackendError.uploadNotAllowed(reasonForModel)
        case .allowed(let allowedCanonicalPaths):
            canonicalFilePaths = allowedCanonicalPaths
        }
        if canonicalFilePaths.count > 1, UploadFileAllowlist.sharedParentFolderPath(ofCanonicalPaths: canonicalFilePaths) == nil {
            throw ActionBackendError.uploadNotAllowed("Attach files from one folder per step.")
        }
        let fileBasenames = canonicalFilePaths.map { ($0 as NSString).lastPathComponent }

        let (fileControl, node) = try resolveTargetApplicationElement(elementIdentifier, context: context)
        let fileControlDescription = describe(node, elementIdentifier: elementIdentifier)
        let fileControlFrame = AccessibilityElementReader.frameInTopLeftGlobalPoints(of: fileControl) ?? node?.frameInTopLeftGlobalPoints
        try await flyCursor(toCenterOf: fileControlFrame, actionKind: .attachingFiles, context: context)
        let targetProcessPin = try makeTargetProcessPin(context)
        let fileControlSupportsPress = elementReader.elementInputTraits(of: fileControl).supportsPressAction
        // The user's own clicks and keys are counted from before the app comes forward: any of them stops the upload.
        var assistContext = context
        assistContext.realUserInputCountAtAssistStart = context.realUserInputCountAtAssistStart ?? realUserInputCounter.currentCount
        guard assistContext.realUserInputCountAtAssistStart != nil else {
            throw ActionBackendError.foregroundAssistFailed(ForegroundAssistInterruption.userInputNotObservable.reasonForModel)
        }

        await cursorPresenter.handle(.foregroundAssistStarted)
        do {
            try await ForegroundAssistSession.run(
                targetApplication: context.targetApplication, targetWindow: context.taskWindow?.element,
                timeLimitSeconds: ForegroundAssistSession.maximumUploadAssistSeconds, abortSignal: context.abortSignal,
                automatedActivityRelay: automatedActivityRelay) {
                try await self.chooseFilesInOpenPanel(canonicalFilePaths, fileControl: fileControl,
                                                      fileControlSupportsPress: fileControlSupportsPress,
                                                      fileControlFrame: fileControlFrame, targetProcessPin: targetProcessPin,
                                                      context: assistContext)
            }
        } catch {
            cancelAnyOpenPanel(of: context.targetApplication)
            await cursorPresenter.handle(.foregroundAssistFinished)
            throw error
        }
        await cursorPresenter.handle(.foregroundAssistFinished)

        guard try await pageShowsAttachedFiles(fileBasenames, near: fileControl, context: context) else {
            throw ActionBackendError.inputNotDelivered("the dialog closed but the page doesn't show the file", foregroundAssistMayHelp: false)
        }
        let attachedFileList = fileBasenames.count <= 3
            ? fileBasenames.joined(separator: ", ") : "\(fileBasenames.prefix(3).joined(separator: ", ")) and \(fileBasenames.count - 3) more"
        return ActionOutcome(descriptionForModel: "attached \(fileBasenames.count) file(s) (\(attachedFileList)) to \(fileControlDescription)",
                             deliveryTier: .accessibilityAction, usedForegroundAssist: true)
    }

    /// A panel that appeared late (after a timeout or an abort) must not stay open in the user's app either.
    private func cancelAnyOpenPanel(of application: TargetApplicationReference) {
        if let openPanel = openPanelDriver.openPanelIfPresent(of: application) { openPanelDriver.cancel(openPanel) }
    }

    /// Runs inside the assist. A control without AXPress is clicked instead.
    private func chooseFilesInOpenPanel(_ canonicalFilePaths: [String], fileControl: AXUIElement, fileControlSupportsPress: Bool,
                                        fileControlFrame: CGRect?, targetProcessPin: TargetProcessPin,
                                        context: ActionRunContext) async throws {
        try await ensureReadyForInput(context)
        if fileControlSupportsPress {
            // A press that the app answers late (it runs the panel modally) still opened the panel; only a refusal stops here.
            if case .refused(let refusalError) = try inputSynthesizer.attemptAccessibilityAction(kAXPressAction, on: fileControl,
                                                                                               abortSignal: context.abortSignal) {
                throw ActionBackendError.accessibilityCallFailed("\(kAXPressAction) failed (AXError \(refusalError.rawValue)).")
            }
        } else {
            guard let fileControlFrame, let taskWindowFrame = context.taskWindow?.reference.frameInTopLeftGlobalPoints else {
                throw ActionBackendError.elementNotActionable("the file control has no on-screen frame and no press action.")
            }
            try await inputSynthesizer.postPointerEvents(
                ProcessPointerEventRecipes.clickSteps(clickType: .single,
                                                      targetPointInTopLeftGlobalPoints: ScreenCoordinateConversion.centerOfTopLeftGlobalFrame(fileControlFrame)),
                to: targetProcessPin, windowFrameInTopLeftGlobalPoints: taskWindowFrame, abortSignal: context.abortSignal,
                verifyBeforeEachPressOrMove: { try await self.ensureReadyForInput(context) })
        }
        let openPanel = try await openPanelDriver.waitForOpenPanel(of: context.targetApplication, timeoutSeconds: Self.openPanelWaitSeconds,
                                                                   abortSignal: context.abortSignal)
        do {
            try await openPanelDriver.chooseFiles(canonicalFilePaths: canonicalFilePaths, in: openPanel,
                                                  targetApplication: context.targetApplication,
                                                  realUserInputCountAtAssistStart: context.realUserInputCountAtAssistStart,
                                                  abortSignal: context.abortSignal)
        } catch {
            openPanelDriver.cancel(openPanel)
            throw error
        }
    }

    /// Pages show the chosen file's name (or "3 files") next to the control once the dialog has handed it over.
    private func pageShowsAttachedFiles(_ fileBasenames: [String], near fileControl: AXUIElement,
                                        context: ActionRunContext) async throws -> Bool {
        let pageOrWindow = AccessibilityElementReader.firstAncestorOrSelf(of: fileControl, maximumDepth: Self.maximumPageAncestorWalkDepth) {
            let elementRole = AccessibilityElementReader.role(of: $0)
            return elementRole == AccessibilityElementReader.webAreaRole || elementRole == kAXWindowRole
        }
        let searchRoot = pageOrWindow ?? fileControl
        let acceptedTexts = [fileBasenames[0], "\(fileBasenames.count) files"]
        let deadlineUptime = ProcessInfo.processInfo.systemUptime + Self.attachedFileConfirmationWaitSeconds
        repeat {
            try throwIfRunEnded(context)
            let elementShowingAttachedFiles = AccessibilityElementReader.firstElementInSubtree(
                of: searchRoot, maximumVisitedNodeCount: Self.maximumConfirmationSearchNodeCount) { element in
                AccessibilityElementReader.displayedTexts(of: element).contains { displayedText in
                    acceptedTexts.contains(where: displayedText.contains)
                }
            }
            if elementShowingAttachedFiles != nil { return true }
            try await Task.sleep(nanoseconds: Self.attachedFileConfirmationPollNanoseconds)
        } while ProcessInfo.processInfo.systemUptime < deadlineUptime
        return false
    }
}
