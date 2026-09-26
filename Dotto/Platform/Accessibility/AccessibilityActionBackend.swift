import AppKit
import ApplicationServices

/// Background-first ActionBackend: Dotto works in the target app while the user keeps using other apps.
/// Input goes only to the target's process, through AX actions and values or per-process key events, and never
/// activates the app, raises a window or moves the real cursor. What can't be delivered that way throws
/// `inputNotDelivered(foregroundAssistMayHelp: true)`, and Core asks the user before `performWithForegroundAssist`
/// brings the app forward for a moment.
///
/// read_ui may outline another app, but only the target's elements ever receive input. It is an actor so the element
/// cache and counters are never mutated by two runs at once (for example a new plan starting while an aborted run is
/// still finishing).
actor AccessibilityActionBackend: ActionBackend {
    static let pauseReleasePollIntervalNanoseconds: UInt64 = 100_000_000

    typealias TaskWindow = (element: AXUIElement, reference: TargetWindowReference)

    /// What every check inside one perform() call needs to know about the run it belongs to.
    struct ActionRunContext {
        var targetApplication: TargetApplicationReference
        var runGeneration: Int
        var abortSignal: TaskAbortSignal
        /// True only inside the foreground assist, where the target app is frontmost.
        var targetIsFrontmost: Bool
        var taskWindow: TaskWindow?
        /// The user's real clicks, scrolls and keys counted before the assist brought the app forward. Any change
        /// during the assist ends it; nil (nothing observing) refuses every input.
        var realUserInputCountAtAssistStart: Int? = nil
    }

    let elementReader: AccessibilityElementReader
    let inputSynthesizer: InputSynthesizer
    let windowCapturer: TargetWindowCapturer
    let windowServerBridge: PrivateWindowServerBridge
    let accessibilityModes: TargetApplicationAccessibilityModes
    let openPanelDriver: NativeOpenPanelDriver
    let cursorPresenter: CursorPresenting
    let automatedActivityRelay: AutomatedTargetActivityRelay
    /// Its count is nil while nothing observes the user's input, which refuses every foreground-assist input.
    let realUserInputCounter: RealUserInputCounter

    private var targetApplication: TargetApplicationReference?
    private(set) var applicationKind: TargetApplicationKind = .cocoa
    private(set) var enhancedUserInterfaceIsActive = false
    /// The app whose Accessibility modes this backend holds on (at most one), released exactly once.
    private var processIdentifierWithHeldAccessibilityModes: pid_t?
    private(set) var uploadFileAllowlist: UploadFileAllowlist = .empty
    private var currentTaskWindow: TaskWindow?
    var cachedMenuItems: [MenuItemWithCommandCharacter]?
    /// Set once the app dropped a value Dotto set directly when the field committed (AccessibilityValueCommitCheck).
    var accessibilityValueTypingIsUnreliable = false
    /// Text set directly without Return: the model's next press_key Return commits it, and is checked like one.
    var pendingAccessibilityValueCommit: PendingAccessibilityValueCommit?

    private var latestSnapshotApplication: TargetApplicationReference?
    private var nextElementNumber = 1
    private var snapshotGeneration = 0
    private var latestElementReferencesByIdentifier: [String: AXUIElement] = [:]
    private var latestSnapshot: AccessibilityTreeSnapshot?
    private(set) var latestScreenshot: ScreenshotCapture?

    /// Bumped by every prepareForTask. Work that suspends (cursor flights, sleeps) compares it afterwards so an
    /// action from a superseded run never fires into the new run's state.
    private(set) var runGeneration = 0
    /// The Swift task that called prepareForTask. finishTask comes from the same task, so a late
    /// finishTask from an older run can recognise that the cache now belongs to someone else and leave it alone.
    private var owningSwiftTaskIdentity: Int?
    /// read_ui has no abort parameter in the protocol, so the tree walk watches the signal of the latest action.
    private var abortSignalOfCurrentRun: TaskAbortSignal?
    /// The executor only checks for a pause between actions. A pause (the Pause button, or the user taking over)
    /// that lands while an action is under way must also stop the rest of its input, so every synthesized input
    /// re-checks the run control of the run it belongs to (matched by its abort signal).
    private var attachedRunControl: (runAbortSignal: TaskAbortSignal, runControl: TaskRunControl)?

    init(elementReader: AccessibilityElementReader, inputSynthesizer: InputSynthesizer, windowCapturer: TargetWindowCapturer,
         windowServerBridge: PrivateWindowServerBridge, accessibilityModes: TargetApplicationAccessibilityModes,
         openPanelDriver: NativeOpenPanelDriver, cursorPresenter: CursorPresenting,
         automatedActivityRelay: AutomatedTargetActivityRelay) {
        self.elementReader = elementReader
        self.inputSynthesizer = inputSynthesizer
        self.windowCapturer = windowCapturer
        self.windowServerBridge = windowServerBridge
        self.accessibilityModes = accessibilityModes
        self.openPanelDriver = openPanelDriver
        self.cursorPresenter = cursorPresenter
        self.automatedActivityRelay = automatedActivityRelay
        realUserInputCounter = openPanelDriver.realUserInputCounter
    }

    /// Never activates or launches the app: opening one would take focus.
    func prepareForTask(_ taskConfiguration: ActionBackendTaskConfiguration) async throws {
        runGeneration += 1
        let runGenerationBeingPrepared = runGeneration
        owningSwiftTaskIdentity = Self.currentSwiftTaskIdentity()
        targetApplication = nil
        abortSignalOfCurrentRun = nil
        nextElementNumber = 1
        snapshotGeneration = 0
        clearCachedState()

        let taskTargetApplication = taskConfiguration.targetApplication
        guard AXIsProcessTrusted() else { throw ActionBackendError.accessibilityPermissionMissing }
        if TargetApplicationPolicy.isBlockedTargetApplication(taskTargetApplication) {
            throw ActionBackendError.applicationNotAllowed(taskTargetApplication.applicationName)
        }
        guard NSRunningApplication(processIdentifier: taskTargetApplication.processIdentifier) != nil else {
            throw ActionBackendError.applicationNotFound(
                "Open \(taskTargetApplication.applicationName) first. Dotto never opens apps itself, because opening one would take focus.")
        }
        applicationKind = TargetApplicationAccessibilityModes.applicationKind(of: taskTargetApplication)
        // Planning and the run both prepare the same task's backend; its modes are held once for the pair.
        if processIdentifierWithHeldAccessibilityModes != taskTargetApplication.processIdentifier {
            await releaseHeldAccessibilityModes()
            processIdentifierWithHeldAccessibilityModes = taskTargetApplication.processIdentifier
            enhancedUserInterfaceIsActive = await accessibilityModes.enable(
                for: taskTargetApplication, applicationKind: applicationKind, windowServerBridge: windowServerBridge)
        }
        guard runGeneration == runGenerationBeingPrepared else { throw ActionBackendError.aborted }
        uploadFileAllowlist = taskConfiguration.uploadFileAllowlist
        targetApplication = taskTargetApplication
        _ = await resolveTaskWindow(of: taskTargetApplication)
    }

    /// Not part of ActionBackend, because only real input can be paused.
    func attachRunControl(_ runControl: TaskRunControl, forRunWith runAbortSignal: TaskAbortSignal) {
        attachedRunControl = (runAbortSignal, runControl)
    }

    /// Also needed outside a run: on cancel and dismiss. Releases only this task's hold; other tasks' apps keep theirs.
    func restoreTargetAccessibilityModes() async {
        await releaseHeldAccessibilityModes()
    }

    private func releaseHeldAccessibilityModes() async {
        guard let processIdentifierWithHeldAccessibilityModes else { return }
        self.processIdentifierWithHeldAccessibilityModes = nil
        enhancedUserInterfaceIsActive = false
        await accessibilityModes.release(processIdentifier: processIdentifierWithHeldAccessibilityModes)
    }

    func readUserInterface(_ request: ReadUserInterfaceRequest, abortSignal: TaskAbortSignal) async throws -> AccessibilityTreeSnapshot {
        abortSignalOfCurrentRun = abortSignal
        let taskTargetApplication = try requireTargetApplication()
        var applicationToRead = taskTargetApplication
        if let requestedApplicationName = request.applicationName,
           requestedApplicationName.caseInsensitiveCompare(taskTargetApplication.applicationName) != .orderedSame {
            // Reading another app is allowed (e.g. to copy information), but its elements stay read-only.
            guard let requestedApplication = elementReader.runningApplication(named: requestedApplicationName) else {
                throw ActionBackendError.applicationNotFound(requestedApplicationName)
            }
            applicationToRead = requestedApplication
        }
        let applicationToReadKind = applicationToRead.processIdentifier == taskTargetApplication.processIdentifier
            ? applicationKind : TargetApplicationAccessibilityModes.applicationKind(of: applicationToRead)
        snapshotGeneration += 1
        // The walk is synchronous on this actor, so no other run can change the cache between reading and storing.
        let (snapshot, elementReferencesByIdentifier) = try elementReader.readSnapshot(
            of: applicationToRead, scope: request.scope, snapshotGeneration: snapshotGeneration,
            nextElementNumber: &nextElementNumber, budget: .budget(for: applicationToReadKind),
            windowFrameForPruning: elementReader.focusedWindowFrameInTopLeftGlobalPoints(of: applicationToRead),
            shouldAbortWalk: { Task.isCancelled || abortSignal.isAborted })
        // Only the newest outline's ids resolve, so a stale id fails loudly instead of hitting a different element.
        latestElementReferencesByIdentifier = elementReferencesByIdentifier
        latestSnapshot = snapshot
        latestSnapshotApplication = applicationToRead
        return snapshot
    }

    /// The task window only, also when other windows cover it, with its interactive elements marked by id. The window
    /// is read first, so the marked ids are the latest outline's. A minimized, hidden or blank window is refused with
    /// guidance rather than sent as a misleading image; Dotto never unminimizes, unhides or switches Spaces to fix it.
    func captureMarkedScreenshot(markLimits: ScreenshotMarkLimits, abortSignal: TaskAbortSignal) async throws -> MarkedScreenshotCapture {
        let taskTargetApplication = try requireTargetApplication()
        let runGenerationAtStart = runGeneration
        guard let taskWindow = await resolveTaskWindow(of: taskTargetApplication) else {
            throw ActionBackendError.accessibilityCallFailed("\(taskTargetApplication.applicationName) has no open window to capture.")
        }
        let windowIsMinimized = AccessibilityElementReader.boolAttribute(kAXMinimizedAttribute, of: taskWindow.element) ?? false
        let applicationIsHidden = NSRunningApplication(processIdentifier: taskTargetApplication.processIdentifier)?.isHidden ?? false
        if let earlyUnavailableReason = WindowCaptureAssessment.unavailableReason(
            windowIsMinimized: windowIsMinimized, applicationIsHidden: applicationIsHidden, windowIsOnAnotherSpace: false,
            captureIsBlank: false) {
            throw ActionBackendError.screenshotUnavailable(earlyUnavailableReason)
        }

        var markedSnapshot: AccessibilityTreeSnapshot?
        do {
            markedSnapshot = try await readUserInterface(ReadUserInterfaceRequest(scope: .focusedWindow, applicationName: nil, query: nil),
                                                         abortSignal: abortSignal)
        } catch ActionBackendError.aborted {
            throw ActionBackendError.aborted
        } catch {
            // The picture is still useful without marks; the model is told none could be drawn.
            markedSnapshot = nil
        }
        guard runGeneration == runGenerationAtStart else { throw ActionBackendError.aborted }

        let capturedWindowImage = try await windowCapturer.captureComposedWindowImage(taskWindow.reference)
        guard runGeneration == runGenerationAtStart else { throw ActionBackendError.aborted }
        let captureIsBlank = TargetWindowCapturer.grayscaleThumbnail(of: capturedWindowImage.image).map(WindowCaptureAssessment.isBlank) ?? false
        if captureIsBlank, let blankUnavailableReason = WindowCaptureAssessment.unavailableReason(
            windowIsMinimized: false, applicationIsHidden: false,
            windowIsOnAnotherSpace: windowServerBridge.windowIsOnAnotherSpace(taskWindow.reference.windowIdentifier) ?? false,
            captureIsBlank: true) {
            throw ActionBackendError.screenshotUnavailable(blankUnavailableReason)
        }

        let imagePixelSize = CGSize(width: capturedWindowImage.image.width, height: capturedWindowImage.image.height)
        let markLayout = markedSnapshot.map { snapshot in
            ScreenshotMarkLayoutCalculator.layOutMarks(
                for: snapshot, capturedWindowFrameInTopLeftGlobalPoints: capturedWindowImage.taskWindowFrame,
                imagePixelSize: imagePixelSize, occludingFramesInTopLeftGlobalPoints: capturedWindowImage.childWindowFrames,
                labelMetrics: ScreenshotMarkRenderer.labelMetrics, limits: markLimits)
        } ?? .unavailable(.outlineUnreadable)
        let markedImage = ScreenshotMarkRenderer.drawing(markLayout, onto: capturedWindowImage.image)
        var capturedWindow = taskWindow.reference
        capturedWindow.frameInTopLeftGlobalPoints = capturedWindowImage.taskWindowFrame
        let screenshotCapture = ScreenshotCapture(jpegData: try TargetWindowCapturer.encodeJPEG(markedImage),
                                                  pixelWidth: markedImage.width, pixelHeight: markedImage.height,
                                                  capturedWindow: capturedWindow, capturedAt: Date())
        latestScreenshot = screenshotCapture
        return MarkedScreenshotCapture(screenshotCapture: screenshotCapture, snapshot: markedSnapshot, markLayout: markLayout)
    }

    func perform(_ action: AgentAction, abortSignal: TaskAbortSignal) async throws -> ActionOutcome {
        let actionRunContext = try await makeActionRunContext(abortSignal: abortSignal, targetIsFrontmost: false)
        try await throwIfPausedBeforeInput(actionRunContext)
        if case .uploadFiles = action {
            throw ActionBackendError.inputNotDelivered("attaching files runs only after the user approves the file dialog step",
                                                       foregroundAssistMayHelp: false)
        }
        return try await performActionReportingAutomatedActivity(action, context: actionRunContext)
    }

    /// Only after the user approved bringing the app forward (or approved the upload).
    func performWithForegroundAssist(_ action: AgentAction, abortSignal: TaskAbortSignal) async throws -> ActionOutcome {
        // Counted from before the app comes forward, so a click or key the user makes during the activation also ends it.
        var actionRunContext = try await makeActionRunContext(abortSignal: abortSignal, targetIsFrontmost: true)
        actionRunContext.realUserInputCountAtAssistStart = realUserInputCounter.currentCount
        guard actionRunContext.realUserInputCountAtAssistStart != nil else {
            throw ActionBackendError.foregroundAssistFailed(ForegroundAssistInterruption.userInputNotObservable.reasonForModel)
        }
        try await throwIfPausedBeforeInput(actionRunContext)
        if case .uploadFiles(let elementIdentifier, let filePaths) = action {
            return try await uploadFiles(filePaths, toElementWithIdentifier: elementIdentifier, context: actionRunContext)
        }
        await cursorPresenter.handle(.foregroundAssistStarted)
        do {
            var actionOutcome = try await ForegroundAssistSession.run(
                targetApplication: actionRunContext.targetApplication, targetWindow: actionRunContext.taskWindow?.element,
                timeLimitSeconds: ForegroundAssistSession.maximumAssistSeconds, abortSignal: abortSignal,
                automatedActivityRelay: automatedActivityRelay) {
                try await self.performActionReportingAutomatedActivity(action, context: actionRunContext)
            }
            await cursorPresenter.handle(.foregroundAssistFinished)
            actionOutcome.usedForegroundAssist = true
            return actionOutcome
        } catch {
            await cursorPresenter.handle(.foregroundAssistFinished)
            throw error
        }
    }

    func finishTask() async {
        if let owningSwiftTaskIdentity, owningSwiftTaskIdentity != Self.currentSwiftTaskIdentity() { return }
        let runGenerationBeingFinished = runGeneration
        let finishingRunAbortSignal = attachedRunControl?.runAbortSignal ?? abortSignalOfCurrentRun
        await cursorPresenter.hideCursor(ownedByRunWith: finishingRunAbortSignal)
        await releaseHeldAccessibilityModes()
        // A new run may have prepared while the cursor was hiding; its state is not ours to clear.
        guard runGeneration == runGenerationBeingFinished else { return }
        clearCachedState()
        targetApplication = nil
        abortSignalOfCurrentRun = nil
        attachedRunControl = nil
        owningSwiftTaskIdentity = nil
    }

    /// The start is reported before any input is posted, so a window the action closes or resizes is known to be
    /// Dotto's by the time the app's notification arrives.
    private func performActionReportingAutomatedActivity(_ action: AgentAction, context: ActionRunContext) async throws -> ActionOutcome {
        await automatedActivityRelay.report(.actionStarted(action))
        do {
            let actionOutcome = try await performAction(action, context: context)
            await automatedActivityRelay.report(.actionFinished)
            return actionOutcome
        } catch {
            await automatedActivityRelay.report(.actionFinished)
            throw error
        }
    }

    private func performAction(_ action: AgentAction, context: ActionRunContext) async throws -> ActionOutcome {
        let pendingAccessibilityValueCommitBeforeThisAction = pendingAccessibilityValueCommit
        let actionCommitsPendingValue = Self.actionIsPlainReturnPress(action)
        if !actionCommitsPendingValue { pendingAccessibilityValueCommit = nil }
        if actionCommitsPendingValue, let pendingAccessibilityValueCommitBeforeThisAction,
           case .pressKey(let keyName, let modifiers) = action {
            let returnOutcome = try await pressKey(keyName, modifiers: modifiers, context: context)
            pendingAccessibilityValueCommit = nil
            try await throwIfAccessibilityValueWasNotKept(pendingAccessibilityValueCommitBeforeThisAction,
                                                          retryingThisActionMayHelp: false, context: context)
            return returnOutcome
        }
        switch action {
        case .clickElement(let elementIdentifier, let clickType):
            return try await clickElement(elementIdentifier, clickType: clickType, context: context)
        case .typeText(let elementIdentifier, let text, let replaceExistingText, let pressReturnAfter):
            return try await typeText(text, intoElementWithIdentifier: elementIdentifier, replaceExistingText: replaceExistingText,
                                      pressReturnAfter: pressReturnAfter, context: context)
        case .replaceText(let elementIdentifier, let findText, let replacementText, let occurrence, let insertionPosition):
            return try await replaceText(findText, with: replacementText, occurrence: occurrence, insertionPosition: insertionPosition,
                                         inElementWithIdentifier: elementIdentifier, context: context)
        case .pressKey(let keyName, let modifiers):
            return try await pressKey(keyName, modifiers: modifiers, context: context)
        case .scroll(let elementIdentifier, let direction, let pages):
            return try await scroll(elementIdentifier: elementIdentifier, direction: direction, pages: pages, context: context)
        case .clickScreenshotPoint(let screenshotPixelPoint, let clickType):
            return try await clickScreenshotPoint(screenshotPixelPoint, clickType: clickType, context: context)
        case .uploadFiles:
            throw ActionBackendError.inputNotDelivered("attaching files can't run inside another step", foregroundAssistMayHelp: false)
        }
    }

    // MARK: - Task window

    /// AXFocusedWindow, then AXMainWindow, then the first window; re-resolved before every action. The cursor is told
    /// whenever it changes, so its overlay and live view follow the right window.
    func resolveTaskWindow(of application: TargetApplicationReference) async -> TaskWindow? {
        guard let windowElement = elementReader.focusedWindowElement(of: application),
              let windowFrame = AccessibilityElementReader.frameInTopLeftGlobalPoints(of: windowElement),
              let windowIdentifier = windowServerBridge.windowIdentifier(ofAccessibilityWindow: windowElement)
                ?? WindowListEntryClassification.windowIdentifier(ownedBy: application.processIdentifier, matchingFrame: windowFrame) else {
            currentTaskWindow = nil
            return nil
        }
        let windowReference = TargetWindowReference(processIdentifier: application.processIdentifier,
                                                    windowIdentifier: windowIdentifier, frameInTopLeftGlobalPoints: windowFrame)
        let windowIdentifierChanged = currentTaskWindow?.reference.windowIdentifier != windowIdentifier
        currentTaskWindow = (windowElement, windowReference)
        if windowIdentifierChanged { await cursorPresenter.handle(.targetWindowChanged(windowReference)) }
        return (windowElement, windowReference)
    }

    // MARK: - Run and target-app guards

    private func makeActionRunContext(abortSignal: TaskAbortSignal, targetIsFrontmost: Bool) async throws -> ActionRunContext {
        try abortSignal.throwIfAborted()
        abortSignalOfCurrentRun = abortSignal
        let taskTargetApplication = try requireTargetApplication()
        let runGenerationAtStart = runGeneration
        // Menus change with the front document, the selection and the app's state, so they are read again for each
        // action that needs them rather than once per task.
        cachedMenuItems = nil
        let taskWindow = await resolveTaskWindow(of: taskTargetApplication)
        guard runGeneration == runGenerationAtStart else { throw ActionBackendError.aborted }
        return ActionRunContext(targetApplication: taskTargetApplication, runGeneration: runGenerationAtStart,
                                abortSignal: abortSignal, targetIsFrontmost: targetIsFrontmost, taskWindow: taskWindow)
    }

    private func requireTargetApplication() throws -> TargetApplicationReference {
        guard let targetApplication else { throw ActionBackendError.applicationNotFound("no target application (task not prepared)") }
        return targetApplication
    }

    /// Only ids from the newest outline of the target app resolve; ids from an outline of another app are read-only.
    func resolveTargetApplicationElement(_ elementIdentifier: String,
                                         context: ActionRunContext) throws -> (AXUIElement, AccessibilityElementNode?) {
        guard let accessibilityElement = latestElementReferencesByIdentifier[elementIdentifier] else {
            throw ActionBackendError.staleOrUnknownElementIdentifier(elementIdentifier)
        }
        let targetProcessIdentifier = context.targetApplication.processIdentifier
        let outlinedApplication = latestSnapshotApplication ?? context.targetApplication
        let elementProcessIdentifier = AccessibilityElementReader.processIdentifier(of: accessibilityElement)
        guard outlinedApplication.processIdentifier == targetProcessIdentifier,
              elementProcessIdentifier == nil || elementProcessIdentifier == targetProcessIdentifier else {
            throw ActionBackendError.elementNotActionable(
                "[\(elementIdentifier)] is from an outline of \(outlinedApplication.applicationName), which is read-only. "
                    + "Dotto only acts inside \(context.targetApplication.applicationName); call read_ui for it first.")
        }
        return (accessibilityElement, latestSnapshot?.node(withIdentifier: elementIdentifier))
    }

    /// The only place pins are made: always for the task's target process, which the pin itself also checks.
    func makeTargetProcessPin(_ context: ActionRunContext) throws -> TargetProcessPin {
        guard let targetProcessPin = TargetProcessPin(processIdentifier: context.targetApplication.processIdentifier,
                                                      windowIdentifier: context.taskWindow?.reference.windowIdentifier) else {
            throw ActionBackendError.targetIsThisAppWindow
        }
        return targetProcessPin
    }

    func throwIfRunEnded(_ context: ActionRunContext) throws {
        try context.abortSignal.throwIfAborted()
        guard runGeneration == context.runGeneration else { throw ActionBackendError.aborted }
    }

    /// Runs before every input: the run must still be current and not paused, and inside the assist the target must
    /// still be in front with the user's hands off the mouse and keyboard.
    func ensureReadyForInput(_ context: ActionRunContext) async throws {
        try throwIfRunEnded(context)
        try await throwIfPausedBeforeInput(context)
        try await throwIfForegroundAssistWasInterrupted(context)
    }

    /// The assist only holds while nothing has moved under it. If the user clicked, scrolled or typed, or another app
    /// came to the front, the next input would land in what the user is now doing, so the assist stops here and
    /// ForegroundAssistSession puts the user's app, window and cursor back.
    func throwIfForegroundAssistWasInterrupted(_ context: ActionRunContext) async throws {
        guard context.targetIsFrontmost else { return }
        guard let realUserInputCountAtAssistStart = context.realUserInputCountAtAssistStart,
              let realUserInputCountNow = realUserInputCounter.currentCount else {
            throw ActionBackendError.foregroundAssistFailed(ForegroundAssistInterruption.userInputNotObservable.reasonForModel)
        }
        guard realUserInputCountNow == realUserInputCountAtAssistStart else {
            throw ActionBackendError.foregroundAssistFailed(ForegroundAssistInterruption.userInputObserved.reasonForModel)
        }
        guard await Self.isFrontmost(context.targetApplication.processIdentifier) else {
            throw ActionBackendError.foregroundAssistFailed(
                ForegroundAssistInterruption.targetNotFrontmost(context.targetApplication.applicationName).reasonForModel)
        }
    }

    private static func isFrontmost(_ processIdentifier: pid_t) async -> Bool {
        let frontmostProcessIdentifier = await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        return frontmostProcessIdentifier == processIdentifier
    }

    /// While the run is paused no input is sent. Dotto waits here until the user resumes, skips or stops (so no model
    /// call is made while paused), then abandons the rest of this action: the user may have changed the screen, so
    /// the remaining input could land on the wrong thing. A skip is left in the run control for the executor.
    func throwIfPausedBeforeInput(_ context: ActionRunContext) async throws {
        guard let attachedRunControl, attachedRunControl.runAbortSignal === context.abortSignal,
              attachedRunControl.runControl.currentPauseReason != nil else { return }
        let pausedRunControl = attachedRunControl.runControl
        while pausedRunControl.currentPauseReason != nil {
            try throwIfRunEnded(context)
            do {
                try await Task.sleep(nanoseconds: Self.pauseReleasePollIntervalNanoseconds)
            } catch {
                throw ActionBackendError.aborted
            }
        }
        try throwIfRunEnded(context)
        throw ActionBackendError.pausedBeforeThisAction
    }

    /// Identifies the calling Swift task by the hash of its task handle. Only compared while both tasks are alive
    /// (the finishing task is running), so a recycled handle can't be mistaken for the owner.
    private static func currentSwiftTaskIdentity() -> Int? {
        withUnsafeCurrentTask { currentTask in currentTask?.hashValue }
    }

    // MARK: - Shared helpers

    enum ForegroundAssistInterruption {
        case userInputNotObservable, userInputObserved, targetNotFrontmost(String)

        var reasonForModel: String {
            switch self {
            case .userInputNotObservable:
                return "Dotto couldn't watch for your own clicks and keys, so it didn't act with the app in front"
            case .userInputObserved:
                return "you used the mouse or keyboard, so Dotto stopped and put your window back"
            case .targetNotFrontmost(let applicationName):
                return "another app came to the front, so Dotto stopped acting in \(applicationName)"
            }
        }
    }

    static func mayHaveActedNoteForModel(applicationName: String) -> String {
        " — but \(applicationName) didn't answer (it may be showing a dialog), so this may or may not have happened. "
            + "Read the UI to verify before doing it again"
    }

    func describe(_ node: AccessibilityElementNode?, elementIdentifier: String) -> String {
        guard let node else { return "[\(elementIdentifier)]" }
        let displayedName = [node.title, node.elementDescription, node.placeholder].compactMap { $0 }.first { !$0.isEmpty }
        let roleNameLabel = Self.roleNameLabel(role: node.role, subrole: node.subrole, displayedName: displayedName)
        return "\(roleNameLabel) [\(elementIdentifier)]"
    }

    /// "button “Save”", or just the short role name when the element shows no name.
    static func roleNameLabel(role: String, subrole: String?, displayedName: String?) -> String {
        let roleName = AccessibilityOutlineFormatter.shortRoleName(role: role, subrole: subrole)
        return displayedName.map { "\(roleName) “\($0.prefix(60))”" } ?? roleName
    }

    /// Flies to the frame's center, or stays put when the element has no frame.
    func flyCursor(toCenterOf frameInTopLeftGlobalPoints: CGRect?, actionKind: CursorActionKind, context: ActionRunContext) async throws {
        guard let frameInTopLeftGlobalPoints else { return }
        try await flyCursor(toTopLeftGlobalPoint: ScreenCoordinateConversion.centerOfTopLeftGlobalFrame(frameInTopLeftGlobalPoints),
                            actionKind: actionKind, context: context)
    }

    /// The cursor shows where Dotto is about to act before any input fires; a Stop during the flight cancels the action.
    func flyCursor(toTopLeftGlobalPoint topLeftGlobalPoint: CGPoint, actionKind: CursorActionKind, context: ActionRunContext) async throws {
        guard let taskWindowReference = context.taskWindow?.reference else { return }
        let windowRelativePoint = ScreenCoordinateConversion.windowRelativePoint(
            fromTopLeftGlobalPoint: topLeftGlobalPoint, windowFrameInTopLeftGlobalPoints: taskWindowReference.frameInTopLeftGlobalPoints)
        await cursorPresenter.flyCursor(toWindowRelativePoint: windowRelativePoint, in: taskWindowReference, actionKind: actionKind)
        try throwIfRunEnded(context)
    }

    /// The authenticated key path is approved only while the target is really in front: in the background it could
    /// disturb the user's own front window, and in front Chromium accepts no other keys. The front position is read
    /// live, not assumed, so tiers that are only safe in front (menus opening, pointer events, the authenticated key
    /// path) are planned only while it really is in front.
    func planTiers(for actionKind: InputActionKind, elementTraits: ElementInputTraits?, context: ActionRunContext) -> [InputDeliveryTier] {
        let targetIsFrontmostNow = context.targetIsFrontmost
            && NSWorkspace.shared.frontmostApplication?.processIdentifier == context.targetApplication.processIdentifier
        return InputTierPlanner.backgroundTiers(for: InputTierPlanningRequest(
            actionKind: actionKind, applicationKind: applicationKind, elementTraits: elementTraits,
            capabilities: windowServerBridge.capabilities, enhancedUserInterfaceIsActive: enhancedUserInterfaceIsActive,
            windowIdentifierIsKnown: context.taskWindow != nil, targetIsFrontmost: targetIsFrontmostNow,
            windowServerKeyboardEventsAreApproved: targetIsFrontmostNow,
            accessibilityValueTypingIsUnreliable: accessibilityValueTypingIsUnreliable))
    }

    func menuItemsWithCommandCharacters(of application: TargetApplicationReference) -> [MenuItemWithCommandCharacter] {
        if let cachedMenuItems { return cachedMenuItems }
        let menuItems = elementReader.menuItemsWithCommandCharacters(of: application)
        cachedMenuItems = menuItems
        return menuItems
    }

    private static func actionIsPlainReturnPress(_ action: AgentAction) -> Bool {
        guard case .pressKey(let keyName, let modifiers) = action else { return false }
        return modifiers.isEmpty && SafetyGate.canonicalKeyName(keyName) == "return"
    }

    private func clearCachedState() {
        accessibilityValueTypingIsUnreliable = false
        pendingAccessibilityValueCommit = nil
        latestElementReferencesByIdentifier = [:]
        latestSnapshot = nil
        latestSnapshotApplication = nil
        latestScreenshot = nil
        cachedMenuItems = nil
        currentTaskWindow = nil
    }
}
