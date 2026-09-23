import Foundation

struct DirectRouteExecutionDependencies {
    var fileSystem: FileSystemMutating
    var fileSystemReader: DirectRouteFileSystemReading
    var journalStore: FileOperationJournalStore
    var scriptRunner: ScriptRunning
    var shortcutRunner: ShortcutRunning
    var homeDirectoryPath: String = NSHomeDirectory()
}

struct DirectRouteRunSummary: Equatable, Sendable {
    var taskRunSummary: TaskRunSummary
    var report: DirectRouteRunReport
}

/// Runs an approved direct-route plan (file operations, one script or one shortcut) without the agent loop, routines
/// or the action backend: no model call, no accessibility modes, no focus taken, and the cursor stays parked. A
/// sibling of TaskExecutor that reports through the same observer and confirmation protocols.
final class DirectRouteExecutor {
    static let maximumOutputTextLength = 2_000
    static let maximumFailureReasonLength = 300
    /// What `userFacingReason` starts with when the live file system no longer matches the plan; the UI offers
    /// "Plan again" for it.
    static let folderChangedSincePlanningPrefix = "The folder changed since the plan was made"

    private let dependencies: DirectRouteExecutionDependencies
    private let confirmationRequester: UserConfirmationRequesting
    private let observer: TaskExecutionObserving
    private let auditLogWriter: AuditLogWriter
    private let taskResourceBudget: TaskResourceBudget
    private let runControl: TaskRunControl?
    private let safetyLimits: SafetyLimits
    private let currentDate: () -> Date
    private let focusPolicy: TaskFocusPolicy

    init(dependencies: DirectRouteExecutionDependencies, confirmationRequester: UserConfirmationRequesting,
         observer: TaskExecutionObserving, auditLogWriter: AuditLogWriter, taskResourceBudget: TaskResourceBudget,
         runControl: TaskRunControl?, focusPolicy: TaskFocusPolicy = .allowApprovedAssist,
         safetyLimits: SafetyLimits = .standard, currentDate: @escaping () -> Date = Date.init) {
        self.dependencies = dependencies
        self.confirmationRequester = confirmationRequester
        self.observer = observer
        self.auditLogWriter = auditLogWriter
        self.taskResourceBudget = taskResourceBudget
        self.runControl = runControl
        self.safetyLimits = safetyLimits
        self.currentDate = currentDate
        self.focusPolicy = focusPolicy
    }

    /// The run's outcome before it is folded into the checklist's items.
    private struct RouteOutcome {
        var stopReason: TaskStopReason
        var report: DirectRouteRunReport
    }

    /// Precondition: approvedChecklist.directRoutePlan != nil. Runs off the main actor: file operations are blocking
    /// system calls, and while they run the pill must keep drawing progress and Pause and Stop must stay clickable.
    /// The observer and confirmation callbacks are main-actor isolated, so each one hops there on its own.
    @concurrent
    func run(approvedChecklist: Checklist, abortSignal: TaskAbortSignal) async -> DirectRouteRunSummary {
        let runStartDate = currentDate()
        var workingChecklist = approvedChecklist
        auditLogWriter.append(eventKind: .checklistApproved, itemIdentifier: nil, message: workingChecklist.title,
                              details: ["route": Self.routeName(of: approvedChecklist.directRoutePlan),
                                        "item_count": String(workingChecklist.items.count)])
        taskResourceBudget.startRunWallClock()
        await observer.taskExecutionDidReportCursorActivity(.runStarted(targetWindow: nil))

        var outcome: RouteOutcome
        if abortSignal.isAborted {
            outcome = RouteOutcome(stopReason: .userAborted, report: emptyReport(since: runStartDate))
        } else {
            do {
                try taskResourceBudget.throwIfExhausted()
                switch approvedChecklist.directRoutePlan {
                case .fileOperations(let fileOperationsPlan):
                    outcome = await runFileOperations(fileOperationsPlan, checklist: &workingChecklist, abortSignal: abortSignal)
                case .script(let scriptPlan):
                    if focusPolicy.allowsForegroundAssist {
                        outcome = await runScript(scriptPlan, checklist: &workingChecklist, abortSignal: abortSignal)
                    } else {
                        outcome = RouteOutcome(stopReason: .unrecoverableError("This script may bring an app forward. Dotto kept the target in the background."),
                                               report: emptyReport(since: runStartDate))
                    }
                case .shortcut(let shortcutPlan):
                    if focusPolicy.allowsForegroundAssist {
                        outcome = await runShortcut(shortcutPlan, checklist: &workingChecklist, abortSignal: abortSignal)
                    } else {
                        outcome = RouteOutcome(stopReason: .unrecoverableError("This Shortcut may bring an app forward. Dotto kept the target in the background."),
                                               report: emptyReport(since: runStartDate))
                    }
                case nil:
                    outcome = RouteOutcome(stopReason: .unrecoverableError("This task has no direct plan to run."),
                                           report: emptyReport(since: runStartDate))
                }
            } catch let ceilingError as TaskCeilingReachedError {
                outcome = RouteOutcome(stopReason: .taskCeilingReached(ceilingError.userFacingDescription), report: emptyReport(since: runStartDate))
            } catch {
                outcome = RouteOutcome(stopReason: .unrecoverableError(String(describing: error)), report: emptyReport(since: runStartDate))
            }
        }
        if abortSignal.isAborted { outcome.stopReason = .userAborted }

        // Items the route never reached: skipped after a Stop, otherwise they had nothing left to change.
        for pendingItem in workingChecklist.items where pendingItem.runStatus == .pending || pendingItem.runStatus == .running {
            let runStatus: ChecklistItemRunStatus
            let resultSummary: String
            switch outcome.stopReason {
            case .allItemsProcessed:
                runStatus = .completed
                resultSummary = "Nothing to change."
            case .userAborted:
                runStatus = .skipped
                resultSummary = TaskUserFacingMessages.itemStoppedByUserSummary
            case .unrecoverableError(let message), .taskCeilingReached(let message):
                runStatus = .failed
                resultSummary = message
            case .tooManyConsecutiveFailures, .taskActionLimitReached:
                runStatus = .skipped
                resultSummary = "Skipped."
            }
            await recordFinishedItem(pendingItem.itemIdentifier, runStatus: runStatus, resultSummary: resultSummary, in: &workingChecklist)
        }

        outcome.report.durationSeconds = currentDate().timeIntervalSince(runStartDate)
        let taskRunSummary = TaskRunSummary.summarize(checklist: workingChecklist, stopReason: outcome.stopReason)
        let runSucceeded = outcome.stopReason == .allItemsProcessed && taskRunSummary.failedItemCount == 0
            && taskRunSummary.needsUserItemCount == 0
        await observer.taskExecutionDidReportCursorActivity(.runFinished(succeeded: runSucceeded))
        auditLogWriter.append(eventKind: outcome.stopReason == .userAborted ? .taskAborted : .taskFinished,
                              itemIdentifier: nil, message: String(describing: outcome.stopReason),
                              details: ["completed": String(taskRunSummary.completedItemCount),
                                        "failed": String(taskRunSummary.failedItemCount),
                                        "skipped": String(taskRunSummary.skippedItemCount),
                                        "completed_operations": String(outcome.report.completedOperationCount),
                                        "failed_operations": String(outcome.report.failedOperationCount),
                                        "skipped_operations": String(outcome.report.skippedOperationCount)])
        return DirectRouteRunSummary(taskRunSummary: taskRunSummary, report: outcome.report)
    }

    // MARK: - File operations

    private func runFileOperations(_ approvedPlan: FileOperationsPlan, checklist workingChecklist: inout Checklist,
                                   abortSignal: TaskAbortSignal) async -> RouteOutcome {
        let runStartDate = currentDate()
        let maximumOperationCount = min(FileOperationsPlan.maximumOperationCount, safetyLimits.maximumFileOperationsPerTask)

        // Re-validated against the live file system: the user may have changed the folder while reviewing the plan.
        let fileSystemReader = dependencies.fileSystemReader
        let liveProbe = FileSystemProbe(
            existingItemKind: { fileSystemReader.existingItemKind(atCanonicalPath: $0) },
            volumeIdentifier: { fileSystemReader.volumeIdentifier(ofCanonicalPath: $0) },
            isInsidePackage: { Self.isInsidePackage($0, fileSystemReader: fileSystemReader) })
        let revalidatedPlan: FileOperationsPlan
        switch FileOperationPlanValidator.validate(operations: approvedPlan.operations, scope: approvedPlan.scope, probe: liveProbe,
                                                   homeDirectoryPath: dependencies.homeDirectoryPath,
                                                   maximumOperationCount: maximumOperationCount,
                                                   keepsOperationIdentifiers: true) {
        case .invalid(let problems):
            auditLogWriter.append(eventKind: .directRouteValidation, itemIdentifier: nil, message: "Plan no longer valid at run time",
                                  details: ["problem_count": String(problems.count),
                                            "first_problem": problems.first?.descriptionForModel ?? ""])
            let firstProblemText = problems.first?.descriptionForModel ?? ""
            let itemSummary = "\(Self.folderChangedSincePlanningPrefix): \(firstProblemText)"
            for item in workingChecklist.items {
                await recordFinishedItem(item.itemIdentifier, runStatus: .failed, resultSummary: itemSummary, in: &workingChecklist)
            }
            let failures = problems.prefix(FileOperationRunner.maximumReportedFailureCount).enumerated().map { problemOffset, problem in
                FileOperationFailure(operationIdentifier: problem.operationIndex.map { "op-\($0 + 1)" } ?? "plan-\(problemOffset + 1)",
                                     userFacingReason: "\(Self.folderChangedSincePlanningPrefix): \(problem.descriptionForModel)")
            }
            return RouteOutcome(stopReason: .allItemsProcessed,
                                report: DirectRouteRunReport(completedOperationCount: 0, failedOperationCount: 0,
                                                             skippedOperationCount: approvedPlan.operations.count, failures: failures,
                                                             undoJournalIdentifier: nil, outputText: nil,
                                                             durationSeconds: currentDate().timeIntervalSince(runStartDate)))
        case .valid(let operations, let collisionAdjustments):
            revalidatedPlan = FileOperationsPlan(scope: approvedPlan.scope, groups: approvedPlan.groups, operations: operations,
                                                 collisionAdjustments: Self.combinedCollisionAdjustments(
                                                     approvedAdjustments: approvedPlan.collisionAdjustments,
                                                     runTimeAdjustments: collisionAdjustments))
            if !collisionAdjustments.isEmpty {
                auditLogWriter.append(eventKind: .directRouteValidation, itemIdentifier: nil, message: "Names adjusted at run time",
                                      details: ["adjusted_count": String(collisionAdjustments.count)])
            }
        }

        if case .requireUserConfirmation(let reason, let riskCategory) = SafetyGate.evaluateFileOperationsPlan(revalidatedPlan) {
            let trashGroupIdentifier = revalidatedPlan.operations.first { $0.kind == .moveToTrash }?.groupIdentifier
            let confirmedItemIdentifier = trashGroupIdentifier.flatMap { itemIdentifier(forGroup: $0, plan: revalidatedPlan, checklist: workingChecklist) }
                ?? workingChecklist.items.first?.itemIdentifier ?? "item-1"
            switch await askConfirmation(reason: reason, riskCategory: riskCategory, itemIdentifier: confirmedItemIdentifier,
                                         checklist: workingChecklist, abortSignal: abortSignal) {
            case .allowed:
                break
            case .declined:
                for item in workingChecklist.items {
                    await recordFinishedItem(item.itemIdentifier, runStatus: .skipped,
                                             resultSummary: TaskUserFacingMessages.itemSkippedByUserSummary, in: &workingChecklist)
                }
                return RouteOutcome(stopReason: .allItemsProcessed,
                                    report: skippedReport(operationCount: revalidatedPlan.operations.count, since: runStartDate))
            case .stopped:
                return RouteOutcome(stopReason: .userAborted,
                                    report: skippedReport(operationCount: revalidatedPlan.operations.count, since: runStartDate))
            }
        }

        let fileOperationRunner = FileOperationRunner(fileSystem: dependencies.fileSystem, journalStore: dependencies.journalStore,
                                                      auditLogWriter: auditLogWriter,
                                                      homeDirectoryPath: dependencies.homeDirectoryPath, currentDate: currentDate)
        let observer = self.observer
        let auditLogWriter = self.auditLogWriter
        let itemIdentifierByGroupIdentifier = Dictionary(
            revalidatedPlan.groups.compactMap { group in
                itemIdentifier(forGroup: group.groupIdentifier, plan: revalidatedPlan, checklist: workingChecklist)
                    .map { (group.groupIdentifier, $0) }
            }, uniquingKeysWith: { firstItemIdentifier, _ in firstItemIdentifier })
        let itemLabelByIdentifier = Dictionary(workingChecklist.items.map { ($0.itemIdentifier, $0.label) },
                                               uniquingKeysWith: { firstLabel, _ in firstLabel })
        let groupFinishCollector = GroupFinishCollector()

        let report = await fileOperationRunner.run(
            revalidatedPlan, taskIdentifier: workingChecklist.taskIdentifier, taskTitle: workingChecklist.title,
            runControl: runControl, abortSignal: abortSignal,
            onGroupBoundary: { groupEvent in
                switch groupEvent {
                case .started(let groupIdentifier):
                    guard let itemIdentifier = itemIdentifierByGroupIdentifier[groupIdentifier] else { return }
                    await observer.taskExecutionDidStartItem(itemIdentifier: itemIdentifier)
                    auditLogWriter.append(eventKind: .itemStarted, itemIdentifier: itemIdentifier,
                                          message: itemLabelByIdentifier[itemIdentifier] ?? "", details: [:])
                case .finished(let groupIdentifier, _, let failed, let skipped, let summary):
                    guard let itemIdentifier = itemIdentifierByGroupIdentifier[groupIdentifier] else { return }
                    let runStatus: ChecklistItemRunStatus
                    if failed > 0 {
                        runStatus = .failed
                    } else if skipped == 0 {
                        runStatus = .completed
                    } else {
                        // None ran, or the user skipped the rest of the group.
                        runStatus = .skipped
                    }
                    groupFinishCollector.append((itemIdentifier, runStatus, summary))
                    await observer.taskExecutionDidFinishItem(itemIdentifier: itemIdentifier, runStatus: runStatus, resultSummary: summary)
                    auditLogWriter.append(eventKind: .itemFinished, itemIdentifier: itemIdentifier, message: summary,
                                          details: ["run_status": runStatus.rawValue])
                }
            },
            onProgress: { progress in
                await observer.taskExecutionDidReportCursorActivity(.directOperationProgressed(
                    completedCount: progress.completedCount, totalCount: progress.totalCount,
                    operationDescription: progress.currentOperationDescription))
            })
        for itemFinish in groupFinishCollector.finishedItems {
            workingChecklist = workingChecklist.updatingItem(withIdentifier: itemFinish.itemIdentifier) { finishedItem in
                finishedItem.runStatus = itemFinish.runStatus
                finishedItem.resultSummary = itemFinish.resultSummary
            }
        }
        return RouteOutcome(stopReason: abortSignal.isAborted ? .userAborted : .allItemsProcessed, report: report)
    }

    /// Operation identifiers are kept through the run-time re-check, so both lists name the same operations. A name
    /// adjusted again at run time keeps the name the model first asked for as its requested path.
    static func combinedCollisionAdjustments(approvedAdjustments: [FileOperationCollisionAdjustment],
                                             runTimeAdjustments: [FileOperationCollisionAdjustment]) -> [FileOperationCollisionAdjustment] {
        var combinedAdjustments = approvedAdjustments
        for runTimeAdjustment in runTimeAdjustments {
            if let approvedIndex = combinedAdjustments.firstIndex(where: { $0.operationIdentifier == runTimeAdjustment.operationIdentifier }) {
                combinedAdjustments[approvedIndex].adjustedDestinationPath = runTimeAdjustment.adjustedDestinationPath
            } else {
                combinedAdjustments.append(runTimeAdjustment)
            }
        }
        return combinedAdjustments
    }

    /// Group N is item N (`Checklist.fromDirectRoutePlan`); a title match covers a checklist built some other way.
    private func itemIdentifier(forGroup groupIdentifier: String, plan: FileOperationsPlan, checklist: Checklist) -> String? {
        guard let groupIndex = plan.groups.firstIndex(where: { $0.groupIdentifier == groupIdentifier }) else { return nil }
        if plan.groups.count == checklist.items.count { return checklist.items[groupIndex].itemIdentifier }
        return checklist.items.first { $0.label == plan.groups[groupIndex].title }?.itemIdentifier
    }

    /// Strict ancestors only: a package that is itself the operand is changed as a whole.
    private static func isInsidePackage(_ canonicalPath: String, fileSystemReader: DirectRouteFileSystemReading) -> Bool {
        var ancestorPath = FileOperationPathRules.parentPath(of: canonicalPath)
        while !ancestorPath.isEmpty && ancestorPath != "/" {
            if fileSystemReader.existingItemKind(atCanonicalPath: ancestorPath) == .package { return true }
            ancestorPath = FileOperationPathRules.parentPath(of: ancestorPath)
        }
        return false
    }

    // MARK: - Script

    private func runScript(_ approvedScriptPlan: ScriptPlan, checklist workingChecklist: inout Checklist,
                           abortSignal: TaskAbortSignal) async -> RouteOutcome {
        let runStartDate = currentDate()
        let itemIdentifier = workingChecklist.items.first?.itemIdentifier ?? "item-1"
        let applicationName = approvedScriptPlan.targetApplicationName
        var scriptPlan = approvedScriptPlan
        scriptPlan.timeoutSeconds = min(max(scriptPlan.timeoutSeconds, 5), safetyLimits.maximumScriptTimeoutSeconds)
        scriptPlan.inspection = ScriptSourceInspector.inspect(source: scriptPlan.source, language: scriptPlan.language)

        switch SafetyGate.evaluateScriptPlan(scriptPlan, homeDirectoryPath: dependencies.homeDirectoryPath) {
        case .deny(let reasonForModel):
            auditLogWriter.append(eventKind: .safetyDecision, itemIdentifier: itemIdentifier, message: "script denied",
                                  details: ["reason": reasonForModel])
            return await finishSingleItem(itemIdentifier, runStatus: .failed, resultSummary: "Dotto won't run this script: \(reasonForModel)",
                                          outputText: nil, checklist: &workingChecklist, since: runStartDate)
        case .requireUserConfirmation(let reason, let riskCategory):
            switch await askConfirmation(reason: reason, riskCategory: riskCategory, itemIdentifier: itemIdentifier,
                                         checklist: workingChecklist, abortSignal: abortSignal) {
            case .allowed: break
            case .declined:
                return await finishSingleItem(itemIdentifier, runStatus: .skipped, resultSummary: TaskUserFacingMessages.itemSkippedByUserSummary,
                                              outputText: nil, checklist: &workingChecklist, since: runStartDate)
            case .stopped:
                return RouteOutcome(stopReason: .userAborted, report: skippedReport(operationCount: 1, since: runStartDate))
            }
        case .allow:
            break
        }
        if await waitAtCheckpoint(abortSignal: abortSignal) == .skipCurrentItem {
            return await finishSingleItem(itemIdentifier, runStatus: .skipped, resultSummary: TaskUserFacingMessages.itemSkippedByUserSummary,
                                          outputText: nil, checklist: &workingChecklist, since: runStartDate)
        }
        if abortSignal.isAborted { return RouteOutcome(stopReason: .userAborted, report: skippedReport(operationCount: 1, since: runStartDate)) }

        // Dotto never launches an app, and `tell application` would.
        let targetNotRunningSummary = "Open \(applicationName), then run the task again."
        guard dependencies.scriptRunner.isApplicationRunning(bundleIdentifier: scriptPlan.targetBundleIdentifier) else {
            return await finishSingleItem(itemIdentifier, runStatus: .failed, resultSummary: targetNotRunningSummary,
                                          outputText: nil, checklist: &workingChecklist, since: runStartDate)
        }
        // Asked only now, after the user chose Run, so a system prompt is one they started.
        switch await dependencies.scriptRunner.automationPermission(forBundleIdentifier: scriptPlan.targetBundleIdentifier, mayPromptUser: true) {
        case .denied:
            return await finishSingleItem(itemIdentifier, runStatus: .failed,
                                          resultSummary: Self.automationDeniedSummary(applicationName: applicationName),
                                          outputText: nil, checklist: &workingChecklist, since: runStartDate)
        case .targetNotRunning:
            return await finishSingleItem(itemIdentifier, runStatus: .failed, resultSummary: targetNotRunningSummary,
                                          outputText: nil, checklist: &workingChecklist, since: runStartDate)
        case .granted, .notYetAsked, .unknown:
            // Not provably denied: the script runs, and if macOS still refuses, osascript fails with -1743, which
            // `scriptFailureSummary` turns into where to allow it.
            break
        }
        if abortSignal.isAborted { return RouteOutcome(stopReason: .userAborted, report: skippedReport(operationCount: 1, since: runStartDate)) }

        await startSingleItem(itemIdentifier, cursorText: "Running script in \(applicationName)…", checklist: &workingChecklist)
        let scriptStartDate = currentDate()
        var auditDetails = ["target": scriptPlan.targetBundleIdentifier, "language": scriptPlan.language.rawValue,
                            "source_sha256": SHA256Digest.hexDigest(of: Data(scriptPlan.source.utf8)),
                            "source_length": String(scriptPlan.source.count),
                            "timeout_seconds": String(scriptPlan.timeoutSeconds)]
        let scriptRunOutput: ScriptRunOutput
        do {
            scriptRunOutput = try await dependencies.scriptRunner.run(scriptPlan, abortSignal: abortSignal)
        } catch {
            auditDetails["error"] = String(describing: error)
            auditLogWriter.append(eventKind: .scriptRun, itemIdentifier: itemIdentifier, message: "script could not run", details: auditDetails)
            if ClaudeToolResultBuilding.isAbort(error, abortSignal: abortSignal) {
                return await finishStoppedSingleItem(itemIdentifier, checklist: &workingChecklist, since: runStartDate)
            }
            return await finishSingleItem(itemIdentifier, runStatus: .failed,
                                          resultSummary: "The script couldn't start: \(Self.truncated(error.localizedDescription, toLength: Self.maximumFailureReasonLength))",
                                          outputText: nil, checklist: &workingChecklist, since: runStartDate)
        }
        auditDetails["exit_status"] = String(scriptRunOutput.exitStatus)
        auditDetails["duration_seconds"] = String(format: "%.2f", currentDate().timeIntervalSince(scriptStartDate))
        auditDetails["timed_out"] = String(scriptRunOutput.timedOut)
        auditDetails["stopped"] = String(scriptRunOutput.wasStopped)
        auditLogWriter.append(eventKind: .scriptRun, itemIdentifier: itemIdentifier, message: "script finished", details: auditDetails)

        let outputText = Self.boundedOutputText(scriptRunOutput.standardOutputText)
        if scriptRunOutput.wasStopped || abortSignal.isAborted {
            return await finishStoppedSingleItem(itemIdentifier, checklist: &workingChecklist, since: runStartDate)
        }
        if scriptRunOutput.timedOut {
            return await finishSingleItem(itemIdentifier, runStatus: .failed,
                                          resultSummary: "The script didn't finish within \(scriptPlan.timeoutSeconds) seconds, so Dotto stopped it. Check \(applicationName) for anything it changed.",
                                          outputText: outputText, checklist: &workingChecklist, since: runStartDate)
        }
        if scriptRunOutput.exitStatus != 0 {
            return await finishSingleItem(itemIdentifier, runStatus: .failed,
                                          resultSummary: Self.scriptFailureSummary(standardErrorText: scriptRunOutput.standardErrorText,
                                                                                   applicationName: applicationName),
                                          outputText: outputText, checklist: &workingChecklist, since: runStartDate)
        }
        return await finishSingleItem(itemIdentifier, runStatus: .completed, resultSummary: "The script finished in \(applicationName).",
                                      outputText: outputText, checklist: &workingChecklist, since: runStartDate)
    }

    static func automationDeniedSummary(applicationName: String) -> String {
        "Allow Dotto to control \(applicationName) in System Settings ▸ Privacy & Security ▸ Automation, then run the task again."
    }

    /// AppleScript errors name their number: -1743 is "not allowed to send Apple events", -600 "application isn't running".
    static func scriptFailureSummary(standardErrorText: String, applicationName: String) -> String {
        if standardErrorText.contains("-1743") { return automationDeniedSummary(applicationName: applicationName) }
        if standardErrorText.contains("-600") { return "\(applicationName) quit while the script ran. Open it, then run the task again." }
        let firstErrorLine = standardErrorText.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard !firstErrorLine.isEmpty else { return "The script failed in \(applicationName)." }
        return "The script failed in \(applicationName): \(truncated(firstErrorLine, toLength: maximumFailureReasonLength))"
    }

    // MARK: - Shortcut

    private func runShortcut(_ shortcutPlan: ShortcutPlan, checklist workingChecklist: inout Checklist,
                             abortSignal: TaskAbortSignal) async -> RouteOutcome {
        let runStartDate = currentDate()
        let itemIdentifier = workingChecklist.items.first?.itemIdentifier ?? "item-1"
        let displayedShortcutName = "“\(shortcutPlan.shortcutName)”"
        var boundedShortcutPlan = shortcutPlan
        boundedShortcutPlan.timeoutSeconds = min(max(shortcutPlan.timeoutSeconds, 5), safetyLimits.maximumScriptTimeoutSeconds)

        if let nameProblem = ShortcutNameRules.validate(shortcutPlan.shortcutName) {
            return await finishSingleItem(itemIdentifier, runStatus: .failed, resultSummary: nameProblem,
                                          outputText: nil, checklist: &workingChecklist, since: runStartDate)
        }
        if case .files(let inputFilePaths) = shortcutPlan.input {
            let homeDirectoryPath = dependencies.homeDirectoryPath
            let hasProtectedInput = inputFilePaths.isEmpty || inputFilePaths.contains { inputFilePath in
                guard let pathComponents = FileOperationScopePolicy.normalizedComponents(
                    ofCanonicalPath: UploadFileAllowlist.normalizedPath(inputFilePath)) else { return true }
                return ProtectedPathPolicy.isProtected(normalizedPathComponents: pathComponents, homeDirectoryPath: homeDirectoryPath)
            }
            if hasProtectedInput {
                return await finishSingleItem(itemIdentifier, runStatus: .failed,
                                              resultSummary: "Dotto won't pass these files to a shortcut: one is inside a protected folder.",
                                              outputText: nil, checklist: &workingChecklist, since: runStartDate)
            }
        }
        // Listed again at run time: the name must still match one of the user's shortcuts exactly.
        do {
            let listedShortcutNames = try await dependencies.shortcutRunner.listShortcutNames(abortSignal: abortSignal)
            guard ShortcutNameRules.isListed(shortcutPlan.shortcutName, inListedNames: listedShortcutNames) else {
                return await finishSingleItem(itemIdentifier, runStatus: .failed,
                                              resultSummary: "Dotto couldn't find your shortcut \(displayedShortcutName) any more.",
                                              outputText: nil, checklist: &workingChecklist, since: runStartDate)
            }
        } catch {
            if ClaudeToolResultBuilding.isAbort(error, abortSignal: abortSignal) {
                return RouteOutcome(stopReason: .userAborted, report: skippedReport(operationCount: 1, since: runStartDate))
            }
            return await finishSingleItem(itemIdentifier, runStatus: .failed, resultSummary: "Dotto couldn't list your shortcuts.",
                                          outputText: nil, checklist: &workingChecklist, since: runStartDate)
        }

        if case .requireUserConfirmation(let reason, let riskCategory) = SafetyGate.evaluateShortcutPlan(boundedShortcutPlan) {
            switch await askConfirmation(reason: reason, riskCategory: riskCategory, itemIdentifier: itemIdentifier,
                                         checklist: workingChecklist, abortSignal: abortSignal) {
            case .allowed: break
            case .declined:
                return await finishSingleItem(itemIdentifier, runStatus: .skipped, resultSummary: TaskUserFacingMessages.itemSkippedByUserSummary,
                                              outputText: nil, checklist: &workingChecklist, since: runStartDate)
            case .stopped:
                return RouteOutcome(stopReason: .userAborted, report: skippedReport(operationCount: 1, since: runStartDate))
            }
        }
        if await waitAtCheckpoint(abortSignal: abortSignal) == .skipCurrentItem {
            return await finishSingleItem(itemIdentifier, runStatus: .skipped, resultSummary: TaskUserFacingMessages.itemSkippedByUserSummary,
                                          outputText: nil, checklist: &workingChecklist, since: runStartDate)
        }
        if abortSignal.isAborted { return RouteOutcome(stopReason: .userAborted, report: skippedReport(operationCount: 1, since: runStartDate)) }

        await startSingleItem(itemIdentifier, cursorText: "Running \(displayedShortcutName)…", checklist: &workingChecklist)
        let shortcutStartDate = currentDate()
        var auditDetails = ["name": shortcutPlan.shortcutName, "input_kind": Self.inputKindName(shortcutPlan.input)]
        let shortcutRunOutput: ShortcutRunOutput
        do {
            shortcutRunOutput = try await dependencies.shortcutRunner.run(boundedShortcutPlan, abortSignal: abortSignal)
        } catch {
            auditDetails["error"] = String(describing: error)
            auditLogWriter.append(eventKind: .shortcutRun, itemIdentifier: itemIdentifier, message: "shortcut could not run", details: auditDetails)
            if ClaudeToolResultBuilding.isAbort(error, abortSignal: abortSignal) {
                return await finishStoppedSingleItem(itemIdentifier, checklist: &workingChecklist, since: runStartDate)
            }
            return await finishSingleItem(itemIdentifier, runStatus: .failed,
                                          resultSummary: "The shortcut couldn't start: \(Self.truncated(error.localizedDescription, toLength: Self.maximumFailureReasonLength))",
                                          outputText: nil, checklist: &workingChecklist, since: runStartDate)
        }
        auditDetails["exit_status"] = String(shortcutRunOutput.exitStatus)
        auditDetails["duration_seconds"] = String(format: "%.2f", currentDate().timeIntervalSince(shortcutStartDate))
        auditDetails["timed_out"] = String(shortcutRunOutput.timedOut)
        auditDetails["stopped"] = String(shortcutRunOutput.wasStopped)
        auditLogWriter.append(eventKind: .shortcutRun, itemIdentifier: itemIdentifier, message: "shortcut finished", details: auditDetails)

        let outputText = Self.boundedOutputText(shortcutRunOutput.outputText)
        if shortcutRunOutput.wasStopped || abortSignal.isAborted {
            // Stopping the `shortcuts` command doesn't always stop the shortcut inside the Shortcuts app.
            await recordFinishedItem(itemIdentifier, runStatus: .skipped,
                                     resultSummary: Self.shortcutStoppedSummary(displayedShortcutName: displayedShortcutName),
                                     in: &workingChecklist)
            return RouteOutcome(stopReason: .userAborted, report: skippedReport(operationCount: 1, since: runStartDate))
        }
        if shortcutRunOutput.timedOut {
            return await finishSingleItem(itemIdentifier, runStatus: .failed,
                                          resultSummary: "The shortcut didn't finish within \(boundedShortcutPlan.timeoutSeconds) seconds, so Dotto stopped waiting for it. It may still finish in the Shortcuts app.",
                                          outputText: outputText, checklist: &workingChecklist, since: runStartDate)
        }
        if shortcutRunOutput.exitStatus != 0 {
            let firstErrorLine = shortcutRunOutput.standardErrorText.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let failureSummary = firstErrorLine.isEmpty ? "The shortcut \(displayedShortcutName) failed."
                : "The shortcut \(displayedShortcutName) failed: \(Self.truncated(firstErrorLine, toLength: Self.maximumFailureReasonLength))"
            return await finishSingleItem(itemIdentifier, runStatus: .failed, resultSummary: failureSummary,
                                          outputText: outputText, checklist: &workingChecklist, since: runStartDate)
        }
        return await finishSingleItem(itemIdentifier, runStatus: .completed, resultSummary: "The shortcut \(displayedShortcutName) finished.",
                                      outputText: outputText, checklist: &workingChecklist, since: runStartDate)
    }

    static func shortcutStoppedSummary(displayedShortcutName: String) -> String {
        "Stopped. Dotto stopped waiting for \(displayedShortcutName); it may keep running in the Shortcuts app until it finishes."
    }

    private static func inputKindName(_ shortcutInput: ShortcutInput) -> String {
        switch shortcutInput {
        case .none: return "none"
        case .text: return "text"
        case .files(let inputFilePaths): return "files(\(inputFilePaths.count))"
        }
    }

    // MARK: - Shared steps

    /// Asked through SafetyConfirmationFlow, so a rest-of-task grant covers only the category shown. A direct route
    /// asks at most once per run, so no grant is ever carried to a later question here.
    private func askConfirmation(reason: String, riskCategory: SafetyRiskCategory, itemIdentifier: String,
                                 checklist: Checklist, abortSignal: TaskAbortSignal) async -> SafetyConfirmationOutcome {
        var riskCategoriesAllowedForRestOfTask: Set<SafetyRiskCategory> = []
        let itemParameters = checklist.items.first { $0.itemIdentifier == itemIdentifier }?.parameters ?? []
        let confirmationOutcome = await SafetyConfirmationFlow.askUser(
            SafetyConfirmationRequest(itemIdentifier: itemIdentifier, itemLabel: checklist.title, reason: reason,
                                      isActionLevel: false, riskCategory: riskCategory, itemParameters: itemParameters),
            confirmationRequester: confirmationRequester, auditLogWriter: auditLogWriter,
            additionalAuditDetails: ["route": Self.routeName(of: checklist.directRoutePlan)],
            riskCategoriesAllowedForRestOfTask: &riskCategoriesAllowedForRestOfTask, abortSignal: abortSignal)
        if abortSignal.isAborted { return .stopped }
        return confirmationOutcome
    }

    private func waitAtCheckpoint(abortSignal: TaskAbortSignal) async -> TaskRunCheckpointOutcome {
        guard let runControl else { return .proceed }
        do {
            return try await runControl.checkpointBetweenItems(abortSignal: abortSignal)
        } catch {
            abortSignal.abort()
            return .proceed
        }
    }

    private func startSingleItem(_ itemIdentifier: String, cursorText: String, checklist workingChecklist: inout Checklist) async {
        workingChecklist = workingChecklist.updatingItem(withIdentifier: itemIdentifier) { $0.runStatus = .running }
        await observer.taskExecutionDidStartItem(itemIdentifier: itemIdentifier)
        await observer.taskExecutionDidReportCursorActivity(.itemStarted(itemLabel: cursorText, itemPosition: 1, itemCount: 1))
        auditLogWriter.append(eventKind: .itemStarted, itemIdentifier: itemIdentifier, message: cursorText, details: [:])
    }

    private func finishSingleItem(_ itemIdentifier: String, runStatus: ChecklistItemRunStatus, resultSummary: String, outputText: String?,
                                  checklist workingChecklist: inout Checklist, since runStartDate: Date) async -> RouteOutcome {
        await recordFinishedItem(itemIdentifier, runStatus: runStatus, resultSummary: resultSummary, in: &workingChecklist)
        let failures = runStatus == .failed ? [FileOperationFailure(operationIdentifier: itemIdentifier, userFacingReason: resultSummary)] : []
        return RouteOutcome(stopReason: .allItemsProcessed,
                            report: DirectRouteRunReport(completedOperationCount: runStatus == .completed ? 1 : 0,
                                                         failedOperationCount: runStatus == .failed ? 1 : 0,
                                                         skippedOperationCount: runStatus == .skipped ? 1 : 0,
                                                         failures: failures, undoJournalIdentifier: nil, outputText: outputText,
                                                         durationSeconds: currentDate().timeIntervalSince(runStartDate)))
    }

    private func finishStoppedSingleItem(_ itemIdentifier: String, checklist workingChecklist: inout Checklist,
                                         since runStartDate: Date) async -> RouteOutcome {
        await recordFinishedItem(itemIdentifier, runStatus: .skipped, resultSummary: TaskUserFacingMessages.itemStoppedByUserSummary,
                                 in: &workingChecklist)
        return RouteOutcome(stopReason: .userAborted, report: skippedReport(operationCount: 1, since: runStartDate))
    }

    private func recordFinishedItem(_ itemIdentifier: String, runStatus: ChecklistItemRunStatus, resultSummary: String,
                                    in workingChecklist: inout Checklist) async {
        workingChecklist = workingChecklist.updatingItem(withIdentifier: itemIdentifier) { finishedItem in
            finishedItem.runStatus = runStatus
            finishedItem.resultSummary = resultSummary
        }
        await observer.taskExecutionDidFinishItem(itemIdentifier: itemIdentifier, runStatus: runStatus, resultSummary: resultSummary)
        auditLogWriter.append(eventKind: .itemFinished, itemIdentifier: itemIdentifier, message: resultSummary,
                              details: ["run_status": runStatus.rawValue])
    }

    private func emptyReport(since runStartDate: Date) -> DirectRouteRunReport {
        DirectRouteRunReport(completedOperationCount: 0, failedOperationCount: 0, skippedOperationCount: 0, failures: [],
                             undoJournalIdentifier: nil, outputText: nil, durationSeconds: currentDate().timeIntervalSince(runStartDate))
    }

    private func skippedReport(operationCount: Int, since runStartDate: Date) -> DirectRouteRunReport {
        var report = emptyReport(since: runStartDate)
        report.skippedOperationCount = operationCount
        return report
    }

    /// Untrusted output: shown as plain monospaced text only, never sent to a model.
    private static func boundedOutputText(_ rawOutputText: String) -> String? {
        let trimmedOutputText = rawOutputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOutputText.isEmpty else { return nil }
        return truncated(trimmedOutputText, toLength: maximumOutputTextLength)
    }

    private static func truncated(_ text: String, toLength maximumLength: Int) -> String {
        text.count > maximumLength ? String(text.prefix(maximumLength)) + "…" : text
    }

    static func routeName(of directRoutePlan: DirectRoutePlan?) -> String {
        switch directRoutePlan {
        case .fileOperations: return "file_operations"
        case .script: return "script"
        case .shortcut: return "shortcut"
        case nil: return "none"
        }
    }
}

/// Collects group results reported from the runner's callbacks, so the executor can fold them into its checklist
/// once the run returns.
private final class GroupFinishCollector: @unchecked Sendable {
    private let collectorLock = NSLock()
    private var collectedItems: [(itemIdentifier: String, runStatus: ChecklistItemRunStatus, resultSummary: String)] = []

    func append(_ finishedItem: (itemIdentifier: String, runStatus: ChecklistItemRunStatus, resultSummary: String)) {
        collectorLock.withLock { collectedItems.append(finishedItem) }
    }

    var finishedItems: [(itemIdentifier: String, runStatus: ChecklistItemRunStatus, resultSummary: String)] {
        collectorLock.withLock { collectedItems }
    }
}
