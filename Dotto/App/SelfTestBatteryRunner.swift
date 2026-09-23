#if DEBUG
import AppKit

/// Debug builds only. Runs a battery of real chores end to end (the real planner on the user's key, then the approved
/// direct plan through `DirectRouteExecutor` on the real file system), without any UI, focus or real app windows, so
/// planning and direct routes can be checked for speed and correctness without the owner trying each one by hand.
///
/// Scenarios with an `application` run through the real session instead (cursor route): the harness opens a throwaway
/// document in that app beforehand, the runner submits the command against it, approves the checklist, allows only
/// the step confirmations that can't reach beyond that document, and never lets an app come forward. Their result
/// includes the document's text, read through Accessibility.
///
/// Triggered by the distributed notification `com.sryo.dotto.selfTest.run`. Scenarios come from
/// `~/DottoEvals/battery.json` and results go to `~/DottoEvals/results.json`. Every scope folder must be inside
/// `~/DottoEvals`, the planner sees a stand-in Finder window instead of the user's real one, and every confirmation
/// is answered "skip", so nothing is trashed and no script or shortcut runs.
@MainActor
final class SelfTestBatteryRunner {
    static let runNotificationName = Notification.Name("com.sryo.dotto.selfTest.run")

    struct Scenario: Decodable {
        var identifier: String
        var command: String
        /// Relative to ~/DottoEvals; becomes the scope root as if the user summoned Dotto over that Finder window.
        var folder: String?
        /// Relative to the folder: items "selected" in that stand-in Finder window.
        var selectedItems: [String]?
        /// Sent when the planner asks a question.
        var reply: String?
        /// Undo the task from its journal right after it ran, to check the folder comes back as it was.
        var undoAfter: Bool?
        /// Bundle identifier of the app holding the throwaway document, for a cursor-route scenario.
        var application: String?
    }

    struct ScenarioResult: Encodable {
        var identifier: String
        var taskIdentifier: String
        var outcome: String
        var route: String?
        var operationCount: Int?
        var planningSeconds: Double
        var runSeconds: Double?
        var completedOperationCount: Int?
        var failedOperationCount: Int?
        var questions: [String]
        var planTitle: String?
        var messageToUser: String?
        var failures: [String]
        var undoRevertedCount: Int?
        var undoSkippedCount: Int?
        var itemCount: Int?
        var completedItemCount: Int?
        var failedItemCount: Int?
        var confirmationsAllowed: [String] = []
        var confirmationsSkipped: [String] = []
        var pauses: [String] = []
        var documentText: String?
        var error: String?
    }

    weak var taskSessionController: TaskSessionController?

    private let claudeTransport: ClaudeTransport
    private let directRouteExecutionDependencies: DirectRouteExecutionDependencies
    private let evalsFolderPath = (NSHomeDirectory() as NSString).appendingPathComponent("DottoEvals")
    private var isRunning = false
    private var notificationObserver: NSObjectProtocol?

    init(claudeTransport: ClaudeTransport, directRouteExecutionDependencies: DirectRouteExecutionDependencies) {
        self.claudeTransport = claudeTransport
        self.directRouteExecutionDependencies = directRouteExecutionDependencies
    }

    func startListening() {
        notificationObserver = DistributedNotificationCenter.default().addObserver(
            forName: Self.runNotificationName, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.runBatteryIfIdle() }
        }
    }

    private func runBatteryIfIdle() {
        guard !isRunning else { return }
        isRunning = true
        Task {
            await runBattery()
            isRunning = false
        }
    }

    private func runBattery() async {
        let batteryFileURL = URL(fileURLWithPath: evalsFolderPath).appendingPathComponent("battery.json")
        let resultsFileURL = URL(fileURLWithPath: evalsFolderPath).appendingPathComponent("results.json")
        guard let batteryData = try? Data(contentsOf: batteryFileURL),
              let scenarios = try? JSONDecoder().decode([Scenario].self, from: batteryData) else {
            writeResults([["error": "couldn't read battery.json"]], to: resultsFileURL)
            return
        }
        var scenarioResults: [ScenarioResult] = []
        for scenario in scenarios {
            scenarioResults.append(scenario.application == nil ? await run(scenario) : await runThroughSession(scenario))
            writeResults(scenarioResults, to: resultsFileURL)
        }
        writeResults(scenarioResults, to: resultsFileURL)
    }

    private func run(_ scenario: Scenario) async -> ScenarioResult {
        let taskIdentifier = "selftest-" + TaskSessionController.makeNewTaskIdentifier() + "-" + scenario.identifier
        var scenarioResult = ScenarioResult(identifier: scenario.identifier, taskIdentifier: taskIdentifier, outcome: "error",
                                            planningSeconds: 0, questions: [], failures: [])
        let finderReference = TargetApplicationReference(
            processIdentifier: NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.processIdentifier ?? 0,
            applicationName: "Finder", bundleIdentifier: "com.apple.finder")
        guard let auditLogWriter = try? AuditLogWriter(taskIdentifier: taskIdentifier) else {
            scenarioResult.error = "couldn't create the audit log"
            return scenarioResult
        }
        auditLogWriter.append(eventKind: .taskStarted, itemIdentifier: nil, message: scenario.command,
                              details: ["targetApplication": "Finder", "selfTest": scenario.identifier])

        var scopeRoots: [DirectRouteScopeRoot] = []
        var folderPath: String?
        if let folder = scenario.folder {
            let candidateFolderPath = (evalsFolderPath as NSString).appendingPathComponent(folder)
            let resolution = TaskSessionController.resolveDirectRouteScope(
                fromCandidates: [DirectRouteScopeRootCandidate(path: candidateFolderPath, source: .finderWindowUnderSummonPoint)],
                fileSystemReader: directRouteExecutionDependencies.fileSystemReader,
                homeDirectoryPath: directRouteExecutionDependencies.homeDirectoryPath)
            guard let acceptedRoot = resolution.scope.roots.first,
                  acceptedRoot.canonicalPath.hasPrefix(evalsFolderPath + "/") else {
                scenarioResult.error = "scope folder refused or outside ~/DottoEvals"
                return scenarioResult
            }
            scopeRoots = [acceptedRoot]
            folderPath = acceptedRoot.canonicalPath
        }
        let selectedItemPaths = (scenario.selectedItems ?? []).compactMap { selectedItem in
            folderPath.map { ($0 as NSString).appendingPathComponent(selectedItem) }
        }

        let taskResourceBudget = TaskResourceBudget(safetyLimits: .standard)
        let abortSignal = TaskAbortSignal()
        let standInBackend = SelfTestFinderStandInBackend(
            finderReference: finderReference,
            windowTitle: folderPath.map { ($0 as NSString).lastPathComponent } ?? "Recientes")
        let checklistPlanner = ChecklistPlanner(transport: claudeTransport, actionBackend: standInBackend,
                                                auditLogWriter: auditLogWriter, taskResourceBudget: taskResourceBudget)
        checklistPlanner.directRouteContext = PlannerDirectRouteContext(
            scope: DirectRouteScope(roots: scopeRoots), targetApplicationIsScriptable: true,
            targetApplicationAutomationState: .granted, directRoutesAreEnabled: true,
            targetApplicationIsFinder: true, finderSelectionPaths: selectedItemPaths)
        checklistPlanner.directRouteFileSystemReader = directRouteExecutionDependencies.fileSystemReader
        checklistPlanner.shortcutRunner = directRouteExecutionDependencies.shortcutRunner

        let planningStartDate = Date()
        var planningResult: ChecklistPlanningResult
        do {
            planningResult = try await checklistPlanner.produceChecklist(
                command: scenario.command, targetApplication: finderReference, taskIdentifier: taskIdentifier,
                abortSignal: abortSignal, onProgress: { _ in })
            var repliesSent = 0
            while case .question(let plannerQuestion) = planningResult {
                scenarioResult.questions.append(plannerQuestion.text)
                guard let reply = scenario.reply, repliesSent == 0 else { break }
                repliesSent += 1
                planningResult = try await checklistPlanner.continuePlanning(withUserReply: reply, abortSignal: abortSignal,
                                                                            onProgress: { _ in })
            }
        } catch {
            scenarioResult.planningSeconds = Date().timeIntervalSince(planningStartDate)
            scenarioResult.error = "planning failed: \(error)"
            return scenarioResult
        }
        scenarioResult.planningSeconds = Date().timeIntervalSince(planningStartDate)

        switch planningResult {
        case .question:
            scenarioResult.outcome = "question"
            return scenarioResult
        case .cannotPlan(let messageToUser):
            scenarioResult.outcome = "cannotPlan"
            scenarioResult.messageToUser = messageToUser
            return scenarioResult
        case .checklist(let producedChecklist):
            scenarioResult.planTitle = producedChecklist.title
                        scenarioResult.route = DirectRouteExecutor.routeName(of: producedChecklist.directRoutePlan)
            guard let directRoutePlan = producedChecklist.directRoutePlan else {
                scenarioResult.outcome = "cursorChecklist"
                scenarioResult.operationCount = producedChecklist.items.count
                return scenarioResult
            }
            if case .fileOperations(let fileOperationsPlan) = directRoutePlan {
                scenarioResult.operationCount = fileOperationsPlan.operations.count
            }
            let confirmationRecorder = SelfTestConfirmationRecorder()
            let directRouteExecutor = DirectRouteExecutor(
                dependencies: directRouteExecutionDependencies, confirmationRequester: confirmationRecorder,
                observer: confirmationRecorder, auditLogWriter: auditLogWriter, taskResourceBudget: taskResourceBudget,
                runControl: TaskRunControl())
            let runSummary = await directRouteExecutor.run(approvedChecklist: producedChecklist, abortSignal: abortSignal)
            scenarioResult.outcome = "ran"
            scenarioResult.runSeconds = runSummary.report.durationSeconds
            scenarioResult.completedOperationCount = runSummary.report.completedOperationCount
            scenarioResult.failedOperationCount = runSummary.report.failedOperationCount
            scenarioResult.failures = runSummary.report.failures.map { "\($0)" }
                + confirmationRecorder.confirmationReasons.map { "confirmation skipped: " + $0 }
            if scenario.undoAfter == true, let undoJournalIdentifier = runSummary.report.undoJournalIdentifier {
                let undoRunner = FileOperationUndoRunner(fileSystem: directRouteExecutionDependencies.fileSystem,
                                                         journalStore: directRouteExecutionDependencies.journalStore,
                                                         auditLogWriter: auditLogWriter,
                                                         homeDirectoryPath: directRouteExecutionDependencies.homeDirectoryPath)
                do {
                    let undoReport = try await undoRunner.undo(journalIdentifier: undoJournalIdentifier, abortSignal: TaskAbortSignal(),
                                                               onProgress: { _ in })
                    scenarioResult.undoRevertedCount = undoReport.revertedCount
                    scenarioResult.undoSkippedCount = undoReport.skippedCount
                } catch {
                    scenarioResult.error = "undo failed: \(error)"
                }
            }
            return scenarioResult
        }
    }

    // MARK: - Cursor route, through the real session

    private static let categoriesAllowedInsideTheThrowawayDocument: Set<SafetyRiskCategory> = [
        .pressingReturn, .unverifiableClick, .pastingClipboard, .irreversibleItem, .unrecognizedShortcut,
    ]
    private static let sessionScenarioTimeoutSeconds: TimeInterval = 300

    private func runThroughSession(_ scenario: Scenario) async -> ScenarioResult {
        var scenarioResult = ScenarioResult(identifier: scenario.identifier, taskIdentifier: "", outcome: "error",
                                            planningSeconds: 0, questions: [], failures: [])
        guard let taskSessionController, let applicationBundleIdentifier = scenario.application,
              let runningApplication = NSRunningApplication.runningApplications(withBundleIdentifier: applicationBundleIdentifier).first else {
            scenarioResult.error = "the scenario's app isn't running"
            return scenarioResult
        }
        guard !taskSessionController.sessionState.isBusy else {
            scenarioResult.error = "Dotto is busy with another task"
            return scenarioResult
        }
        taskSessionController.targetApplication = TargetApplicationReference(
            processIdentifier: runningApplication.processIdentifier,
            applicationName: runningApplication.localizedName ?? applicationBundleIdentifier,
            bundleIdentifier: applicationBundleIdentifier)
        // A scriptable app would get a script plan, and running it would raise macOS's Automation prompt.
        taskSessionController.directRouteSessionState.directRoutesAreDisabledForNextPlanning = true
        let startDate = Date()
        var runStartDate: Date?
        var repliesSent = 0
        taskSessionController.submitCommand(scenario.command)
        scenarioResult.taskIdentifier = taskSessionController.currentAuditLogFileURL?.deletingPathExtension().lastPathComponent ?? ""

        scenarioLoop: while Date().timeIntervalSince(startDate) < Self.sessionScenarioTimeoutSeconds {
            try? await Task.sleep(for: .milliseconds(250))
            switch taskSessionController.sessionState {
            case .idle:
                if Date().timeIntervalSince(startDate) > 3 {
                    scenarioResult.error = "the command didn't start: " + taskSessionController.statusLine
                    break scenarioLoop
                }
            case .planning, .executing, .demonstrating:
                continue
            case .plannerNeedsInput(_, let plannerQuestion):
                scenarioResult.questions.append(plannerQuestion.text)
                if let reply = scenario.reply, repliesSent == 0, plannerQuestion.acceptsReply {
                    repliesSent += 1
                    taskSessionController.sendPlannerReply(reply)
                } else {
                    scenarioResult.outcome = "question"
                    break scenarioLoop
                }
            case .awaitingApproval(let checklist):
                scenarioResult.planningSeconds = Date().timeIntervalSince(startDate)
                scenarioResult.planTitle = checklist.title
                scenarioResult.itemCount = checklist.includedItems.count
                scenarioResult.route = DirectRouteExecutor.routeName(of: checklist.directRoutePlan)
                runStartDate = Date()
                taskSessionController.approveChecklistAndRun()
            case .awaitingSafetyConfirmation(_, let request):
                let description = "\(request.riskCategory.rawValue): \(request.reason)"
                if Self.categoriesAllowedInsideTheThrowawayDocument.contains(request.riskCategory) {
                    scenarioResult.confirmationsAllowed.append(description)
                    taskSessionController.answerPendingSafetyConfirmation(.allowOnce)
                } else {
                    scenarioResult.confirmationsSkipped.append(description)
                    taskSessionController.answerPendingSafetyConfirmation(.skipItem)
                }
            case .awaitingItemFailureDecision(_, let request):
                scenarioResult.failures.append("\(request)")
                taskSessionController.answerPendingItemFailureDecision(.skipItem)
            case .paused(_, _, let reason):
                scenarioResult.pauses.append("\(reason)")
                taskSessionController.stopTask()
            case .finished(let checklist, let summary):
                scenarioResult.outcome = "finished"
                scenarioResult.completedItemCount = summary.completedItemCount
                scenarioResult.failedItemCount = summary.failedItemCount + summary.needsUserItemCount
                scenarioResult.failures += checklist.includedItems.filter { $0.runStatus != .completed }
                    .map { "\($0.runStatus.rawValue): \($0.label)" }
                break scenarioLoop
            case .failed(_, let reason):
                scenarioResult.outcome = "failed"
                scenarioResult.error = reason
                break scenarioLoop
            case .aborted:
                scenarioResult.outcome = scenarioResult.pauses.isEmpty ? "aborted" : "paused"
                break scenarioLoop
            }
        }
        if taskSessionController.sessionState.isBusy {
            scenarioResult.outcome = "timedOut"
            taskSessionController.stopTask()
        }
        if let runStartDate { scenarioResult.runSeconds = Date().timeIntervalSince(runStartDate) }
        else { scenarioResult.planningSeconds = Date().timeIntervalSince(startDate) }
        // Let the executor finish unwinding before the document is read and the next task starts.
        try? await Task.sleep(for: .seconds(1))
        scenarioResult.documentText = Self.firstTextAreaValue(ofProcessIdentifier: runningApplication.processIdentifier)
        taskSessionController.dismissFinishedTask()
        if case .plannerNeedsInput = taskSessionController.sessionState { taskSessionController.dismissFinishedTask() }
        return scenarioResult
    }

    /// The text of the first text area in the app's first window: the throwaway document's contents.
    private static func firstTextAreaValue(ofProcessIdentifier processIdentifier: Int32) -> String? {
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        guard let firstWindow = AccessibilityElementReader.elementArrayAttribute(kAXWindowsAttribute, of: applicationElement).first else { return nil }
        var elementsToVisit = [firstWindow]
        var visitedCount = 0
        while !elementsToVisit.isEmpty && visitedCount < 400 {
            let element = elementsToVisit.removeFirst()
            visitedCount += 1
            if AccessibilityElementReader.stringAttribute(kAXRoleAttribute, of: element) == (kAXTextAreaRole as String) {
                return AccessibilityElementReader.stringAttribute(kAXValueAttribute, of: element)
            }
            elementsToVisit += AccessibilityElementReader.elementArrayAttribute(kAXChildrenAttribute, of: element)
        }
        return nil
    }

    private func writeResults<ResultValue: Encodable>(_ results: ResultValue, to resultsFileURL: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try? encoder.encode(results).write(to: resultsFileURL, options: .atomic)
    }
}

/// Answers every confirmation with "skip", so the battery never trashes, runs a script or runs a shortcut.
@MainActor
private final class SelfTestConfirmationRecorder: UserConfirmationRequesting, TaskExecutionObserving {
    private(set) var confirmationReasons: [String] = []

    func requestSafetyConfirmation(_ request: SafetyConfirmationRequest) async -> SafetyConfirmationAnswer {
        confirmationReasons.append(request.reason)
        return .skipItem
    }

    func taskExecutionDidStartItem(itemIdentifier: String) {}
    func taskExecutionDidReportProgress(itemIdentifier: String, progressDescription: String) {}
    func taskExecutionDidFinishItem(itemIdentifier: String, runStatus: ChecklistItemRunStatus, resultSummary: String) {}
    func taskExecutionDidReportCursorActivity(_ cursorActivityEvent: CursorActivityEvent) {}
}

/// What the planner reads instead of the user's real Finder: an empty window titled like the scope folder. It never
/// touches accessibility modes and refuses every action.
private final class SelfTestFinderStandInBackend: ActionBackend {
    private let finderReference: TargetApplicationReference
    private let windowTitle: String

    init(finderReference: TargetApplicationReference, windowTitle: String) {
        self.finderReference = finderReference
        self.windowTitle = windowTitle
    }

    func prepareForTask(_ taskConfiguration: ActionBackendTaskConfiguration) async throws {}

    func readUserInterface(_ request: ReadUserInterfaceRequest, abortSignal: TaskAbortSignal) async throws -> AccessibilityTreeSnapshot {
        AccessibilityTreeSnapshot(snapshotGeneration: 1, application: finderReference, windowTitle: windowTitle,
                                  scope: request.scope, rootNodes: [], rawNodeCount: 0, wasTruncatedDuringRead: false)
    }

    func captureScreenshot() async throws -> ScreenshotCapture {
        throw ActionBackendError.inputNotDelivered("No screenshots in the self-test.", foregroundAssistMayHelp: false)
    }

    func perform(_ action: AgentAction, abortSignal: TaskAbortSignal) async throws -> ActionOutcome {
        throw ActionBackendError.inputNotDelivered("No UI actions in the self-test.", foregroundAssistMayHelp: false)
    }

    func performWithForegroundAssist(_ action: AgentAction, abortSignal: TaskAbortSignal) async throws -> ActionOutcome {
        throw ActionBackendError.inputNotDelivered("No UI actions in the self-test.", foregroundAssistMayHelp: false)
    }

    func finishTask() async {}
}
#endif
