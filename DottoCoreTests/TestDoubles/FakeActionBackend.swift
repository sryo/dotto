import Foundation
import CoreGraphics

final class FakeActionBackend: ActionBackend {
    var snapshotRootNodes: [AccessibilityElementNode]
    var performedActions: [AgentAction] = []
    var readRequests: [ReadUserInterfaceRequest] = []
    var didFinishTask = false
    var actionHookAfterPerform: ((AgentAction) -> Void)?
    /// What perform reports to the model instead of "performed <action>".
    var scriptedActionOutcomeDescription: String?
    /// Every background perform reports that its input changed nothing visible.
    var reportsNoVisibleChange = false
    /// Thrown by the next perform (then cleared), before the action counts as performed.
    var errorForNextPerform: Error?
    var preparedTaskConfigurations: [ActionBackendTaskConfiguration] = []
    var actionsPerformedWithForegroundAssist: [AgentAction] = []
    /// Thrown by the next performWithForegroundAssist (then cleared).
    var errorForNextForegroundAssist: Error?
    /// Called with the 1-based number of each read; an error it returns is thrown instead of the snapshot.
    var errorForRead: ((_ readNumber: Int) -> Error?)?

    init(snapshotRootNodes: [AccessibilityElementNode]) { self.snapshotRootNodes = snapshotRootNodes }

    private var resolvableElementIdentifiers: Set<String> {
        var collectedIdentifiers = Set<String>()
        func collect(_ nodes: [AccessibilityElementNode]) {
            for node in nodes {
                collectedIdentifiers.insert(node.elementIdentifier)
                collect(node.children)
            }
        }
        collect(snapshotRootNodes)
        return collectedIdentifiers
    }

    func prepareForTask(_ taskConfiguration: ActionBackendTaskConfiguration) async throws {
        preparedTaskConfigurations.append(taskConfiguration)
    }

    func readUserInterface(_ request: ReadUserInterfaceRequest, abortSignal: TaskAbortSignal) async throws -> AccessibilityTreeSnapshot {
        readRequests.append(request)
        if let readError = errorForRead?(readRequests.count) { throw readError }
        return makeFixtureSnapshot(snapshotRootNodes, scope: request.scope, windowTitle: "Documents", generation: readRequests.count)
    }

    func captureScreenshot() async throws -> ScreenshotCapture {
        ScreenshotCapture(jpegData: Data([0xFF, 0xD8, 0xFF]), pixelWidth: 1280, pixelHeight: 800,
                          capturedWindow: TargetWindowReference(processIdentifier: fixtureTargetApplication.processIdentifier,
                                                                windowIdentifier: 42, frameInTopLeftGlobalPoints: CGRect(x: 0, y: 0, width: 1440, height: 900)),
                          capturedAt: Date())
    }

    func perform(_ action: AgentAction, abortSignal: TaskAbortSignal) async throws -> ActionOutcome {
        try abortSignal.throwIfAborted()
        if let errorForNextPerform {
            self.errorForNextPerform = nil
            throw errorForNextPerform
        }
        if case .clickElement(let elementIdentifier, _) = action, !resolvableElementIdentifiers.contains(elementIdentifier) {
            throw ActionBackendError.staleOrUnknownElementIdentifier(elementIdentifier)
        }
        performedActions.append(action)
        actionHookAfterPerform?(action)
        return ActionOutcome(descriptionForModel: (scriptedActionOutcomeDescription ?? "performed \(action)")
                                + (reportsNoVisibleChange ? ActionOutcome.noVisibleChangeNote : ""),
                             deliveryTier: .accessibilityAction, noVisibleChangeWasSeen: reportsNoVisibleChange)
    }

    func performWithForegroundAssist(_ action: AgentAction, abortSignal: TaskAbortSignal) async throws -> ActionOutcome {
        try abortSignal.throwIfAborted()
        if let errorForNextForegroundAssist {
            self.errorForNextForegroundAssist = nil
            throw errorForNextForegroundAssist
        }
        actionsPerformedWithForegroundAssist.append(action)
        performedActions.append(action)
        actionHookAfterPerform?(action)
        return ActionOutcome(descriptionForModel: "performed in front \(action)", deliveryTier: .processPointerEvents,
                             usedForegroundAssist: true)
    }

    /// Runs inside finishTask, so a test can see what was reported before the backend wound down.
    var finishTaskHook: (() async -> Void)?

    func finishTask() async {
        await finishTaskHook?()
        didFinishTask = true
    }
}
