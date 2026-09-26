import SwiftUI

/// Dotto: menu bar-only teach-once/replay companion. No dock icon, no main window — just a status item, a command
/// bar summoned with ⌃⌥Space (rebindable), and a floating checklist.
@main
struct DottoApp: App {
    @NSApplicationDelegateAdaptor(DottoAppDelegate.self) var appDelegate

    var body: some Scene {
        // The app lives entirely in panels managed by the AppDelegate.
        // This empty Settings scene satisfies SwiftUI's requirement for at least
        // one scene but is never shown (LSUIElement=true removes the app menu).
        Settings {
            EmptyView()
        }
    }
}

/// Composition root: builds the platform services, the controller and the menu bar panel.
@MainActor
final class DottoAppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarPanelController: MenuBarPanelController?
    private var taskSessionController: TaskSessionController?
    /// Shared by every task's backend: one record of changed modes (and one crash-recovery file) for all apps.
    private let accessibilityModes = TargetApplicationAccessibilityModes()
    private let displayReconfigurationObserver = DisplayReconfigurationObserver()

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("Dotto: version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])

        let anthropicAPIKeyStore = AnthropicAPIKeyStore()
        do {
            try anthropicAPIKeyStore.moveAPIKeySavedBeforeRenameIfNeeded()
        } catch {
            // The store's errors carry only the Keychain's status text, never the key.
            print("Dotto: \(error.localizedDescription)")
        }
        var claudeTransport: ClaudeTransport = AnthropicMessagesTransport(apiKeyStore: anthropicAPIKeyStore)
        var usesMockClaudeTransport = false
        #if DEBUG
        // Debug builds only: canned answers instead of the API, for trying Dotto without spending credits.
        if MockClaudeTransport.isEnabled {
            claudeTransport = MockClaudeTransport()
            usesMockClaudeTransport = true
            print("Dotto: using the mock Claude transport; no request reaches Anthropic")
        }
        #endif

        // First, so every coordinate flip from here on has a settled primary display height.
        displayReconfigurationObserver.start()
        let windowServerBridge = PrivateWindowServerBridge()
        let windowCapturer = TargetWindowCapturer()
        let elementReader = AccessibilityElementReader()
        let inputSynthesizer = InputSynthesizer(windowServerBridge: windowServerBridge)
        let userInputObserver = UserInputObserver()
        let automatedTargetActivityRelay = AutomatedTargetActivityRelay()
        let accessibilityModes = self.accessibilityModes
        let openPanelDriver = NativeOpenPanelDriver(inputSynthesizer: inputSynthesizer,
                                                    realUserInputCounter: userInputObserver.realUserInputCounter)
        // The reader, synthesizer, capturer and window-server bridge keep no per-task state, so every task's backend
        // shares them.
        let makeActionBackend: @MainActor (CursorPresenting) -> ActionBackend = { taskCursorPresenter in
            AccessibilityActionBackend(
                elementReader: elementReader,
                inputSynthesizer: inputSynthesizer,
                windowCapturer: windowCapturer,
                windowServerBridge: windowServerBridge,
                accessibilityModes: accessibilityModes,
                openPanelDriver: openPanelDriver,
                cursorPresenter: taskCursorPresenter,
                automatedActivityRelay: automatedTargetActivityRelay
            )
        }
        // Each task streams its own window into its own live view, so it gets its own capturer.
        let makeSessionServices: @MainActor () -> TaskSessionServices = {
            TaskSessionServices(cursorController: CursorController(frameStreamer: TargetWindowCapturer()),
                                visibilityMonitor: TargetWindowVisibilityMonitor(),
                                targetWindowObserver: TargetWindowObserver(windowServerBridge: windowServerBridge))
        }
        let directRouteExecutionDependencies = Self.makeDirectRouteExecutionDependencies()
        let taskSessionController = TaskSessionController(dependencies: TaskSessionControllerDependencies(
            claudeTransport: claudeTransport,
            usesMockClaudeTransport: usesMockClaudeTransport,
            anthropicAPIKeyStore: anthropicAPIKeyStore,
            makeActionBackend: makeActionBackend,
            makeSessionServices: makeSessionServices,
            keyboardMonitor: GlobalKeyboardMonitor(),
            pointerMovementObserver: PointerMovementObserver(),
            userInputObserver: userInputObserver,
            automatedTargetActivityRelay: automatedTargetActivityRelay,
            windowServerCapabilities: windowServerBridge.capabilities,
            attentionNotificationPoster: UserAttentionNotificationPoster(),
            demonstrationRecorder: DemonstrationRecorder(elementReader: elementReader, inputSynthesizer: inputSynthesizer),
            routineLibraryStore: RoutineLibraryStore(signingKeyProvider: KeychainRoutineSigningKeyProvider()),
            directRouteExecutionDependencies: directRouteExecutionDependencies
        ))
        self.taskSessionController = taskSessionController

        menuBarPanelController = MenuBarPanelController(taskSessionController: taskSessionController)
        taskSessionController.start()
        taskSessionController.reloadSavedRoutines()
        taskSessionController.refreshMostRecentUndoableJournal()
        // Open the panel on launch when setup is incomplete so the user sees what's
        // missing without hunting for the menu bar icon.
        if !taskSessionController.permissionStatus.allRequiredPermissionsGranted || !taskSessionController.hasAnthropicAPIKey {
            menuBarPanelController?.showPanelOnLaunch()
        }
    }

    /// One file system, one journal store (old journals pruned at launch) and one runner each for scripts and
    /// shortcuts. Without a journal folder nothing could be undone, so direct routes stay off instead.
    private static func makeDirectRouteExecutionDependencies() -> DirectRouteExecutionDependencies? {
        let fileManagerFileSystem = FileManagerFileSystem()
        let journalStore: FileOperationJournalStore
        do {
            journalStore = try FileOperationJournalStore()
        } catch {
            print("Dotto: direct routes are off, the undo journal folder couldn't be created (\(error.localizedDescription))")
            return nil
        }
        do {
            try journalStore.pruneOldJournals(now: Date())
        } catch {
            print("Dotto: old undo journals weren't pruned (\(error.localizedDescription))")
        }
        return DirectRouteExecutionDependencies(fileSystem: fileManagerFileSystem, fileSystemReader: fileManagerFileSystem,
                                                journalStore: journalStore, scriptRunner: OsascriptScriptRunner(),
                                                shortcutRunner: ShortcutsCommandRunner())
    }

    func applicationWillTerminate(_ notification: Notification) {
        taskSessionController?.stop()
        // A Chromium target keeps its enhanced accessibility mode on (slower) until someone turns it off. Quitting
        // can't wait on an actor from here, so the restore gets up to half a second on a background thread.
        let accessibilityModes = self.accessibilityModes
        let restoreFinished = DispatchSemaphore(value: 0)
        Task.detached {
            await accessibilityModes.restoreAll()
            restoreFinished.signal()
        }
        _ = restoreFinished.wait(timeout: .now() + 0.5)
    }
}
