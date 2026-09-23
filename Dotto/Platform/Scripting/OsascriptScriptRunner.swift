import AppKit

enum ScriptRunnerError: Error, Equatable, LocalizedError {
    case targetNotRunning(applicationName: String)
    case automationNotAllowed(applicationName: String)
    case refusedByInspection(reason: String)

    var errorDescription: String? {
        switch self {
        case .targetNotRunning(let applicationName):
            return "Open \(applicationName), then run again."
        case .automationNotAllowed(let applicationName):
            return DirectRouteExecutor.automationDeniedSummary(applicationName: applicationName)
        case .refusedByInspection(let reason):
            return "Dotto won't run this script: \(reason)"
        }
    }
}

/// Runs an approved AppleScript or JXA plan out of process through `/usr/bin/osascript`, with the source on stdin
/// (never `-e`, never a shell), so Stop and the timeout can kill it. Before launching it re-checks that the target is
/// running (a `tell` would launch it, and Dotto never launches apps), asks for Automation permission (only now, after
/// the user clicked Run) and inspects the source again.
final class OsascriptScriptRunner: ScriptRunning, @unchecked Sendable {
    static let standardOutputByteLimit = 64 * 1024
    static let standardErrorByteLimit = 16 * 1024

    init() {}

    func automationPermission(forBundleIdentifier bundleIdentifier: String, mayPromptUser: Bool) async -> AutomationPermissionState {
        guard isApplicationRunning(bundleIdentifier: bundleIdentifier) else { return .targetNotRunning }
        return await AutomationPermissionProbe.permissionState(forBundleIdentifier: bundleIdentifier, mayPromptUser: mayPromptUser)
    }

    func isApplicationRunning(bundleIdentifier: String) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).contains { !$0.isTerminated }
    }

    func run(_ scriptPlan: ScriptPlan, abortSignal: TaskAbortSignal) async throws -> ScriptRunOutput {
        guard isApplicationRunning(bundleIdentifier: scriptPlan.targetBundleIdentifier) else {
            throw ScriptRunnerError.targetNotRunning(applicationName: scriptPlan.targetApplicationName)
        }
        // The plan could only have changed through a bug, but the source is what runs, so it is inspected again.
        var reinspectedScriptPlan = scriptPlan
        reinspectedScriptPlan.inspection = ScriptSourceInspector.inspect(source: scriptPlan.source, language: scriptPlan.language)
        if case .deny(let reasonForModel) = ScriptTargetPolicy.evaluate(reinspectedScriptPlan) {
            throw ScriptRunnerError.refusedByInspection(reason: reasonForModel)
        }
        let permissionState = await automationPermission(forBundleIdentifier: scriptPlan.targetBundleIdentifier, mayPromptUser: true)
        switch permissionState {
        case .granted, .notYetAsked, .unknown:
            // Only a provable denial stops the run here, as in DirectRouteExecutor. Otherwise osascript sends the
            // events, macOS asks if it still needs to, and a refusal comes back as -1743, reworded below.
            break
        case .targetNotRunning:
            throw ScriptRunnerError.targetNotRunning(applicationName: scriptPlan.targetApplicationName)
        case .denied:
            throw ScriptRunnerError.automationNotAllowed(applicationName: scriptPlan.targetApplicationName)
        }
        try abortSignal.throwIfAborted()

        let languageArgument = scriptPlan.language == .appleScript ? "AppleScript" : "JavaScript"
        let processResult = try await BoundedProcessRunner.run(
            executablePath: BoundedProcessRunner.osascriptExecutablePath,
            arguments: ["-l", languageArgument, "-"],
            standardInputData: Data(scriptPlan.source.utf8),
            workingDirectoryURL: FileManager.default.temporaryDirectory,
            timeoutSeconds: TimeInterval(min(max(scriptPlan.timeoutSeconds, 5), 300)),
            abortSignal: abortSignal,
            standardOutputByteLimit: Self.standardOutputByteLimit,
            standardErrorByteLimit: Self.standardErrorByteLimit)

        // A refusal from macOS stays in the text as "-1743": DirectRouteExecutor.scriptFailureSummary turns it into
        // where to allow Dotto, the one place that wording lives.
        let standardErrorText = String(decoding: processResult.standardErrorData, as: UTF8.self)
        return ScriptRunOutput(
            exitStatus: processResult.exitStatus,
            standardOutputText: String(decoding: processResult.standardOutputData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            standardErrorText: standardErrorText.trimmingCharacters(in: .whitespacesAndNewlines),
            timedOut: processResult.timedOut,
            wasStopped: processResult.wasStopped)
    }
}
