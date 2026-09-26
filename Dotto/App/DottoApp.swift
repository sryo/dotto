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
    private var actionBackend: AccessibilityActionBackend?
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
        let claudeTransport = AnthropicMessagesTransport(apiKeyStore: anthropicAPIKeyStore)

        // First, so every coordinate flip from here on has a settled primary display height.
        displayReconfigurationObserver.start()
        let windowServerBridge = PrivateWindowServerBridge()
        let windowCapturer = TargetWindowCapturer()
        let cursorController = CursorController(frameStreamer: windowCapturer)
        let elementReader = AccessibilityElementReader()
        let inputSynthesizer = InputSynthesizer(windowServerBridge: windowServerBridge)
        let userInputObserver = UserInputObserver()
        let automatedTargetActivityRelay = AutomatedTargetActivityRelay()
        let actionBackend = AccessibilityActionBackend(
            elementReader: elementReader,
            inputSynthesizer: inputSynthesizer,
            windowCapturer: windowCapturer,
            windowServerBridge: windowServerBridge,
            accessibilityModes: TargetApplicationAccessibilityModes(),
            openPanelDriver: NativeOpenPanelDriver(inputSynthesizer: inputSynthesizer,
                                                   realUserInputCounter: userInputObserver.realUserInputCounter),
            cursorPresenter: cursorController,
            automatedActivityRelay: automatedTargetActivityRelay
        )
        self.actionBackend = actionBackend
        let directRouteExecutionDependencies = Self.makeDirectRouteExecutionDependencies()
        let taskSessionController = TaskSessionController(dependencies: TaskSessionControllerDependencies(
            claudeTransport: claudeTransport,
            anthropicAPIKeyStore: anthropicAPIKeyStore,
            actionBackend: actionBackend,
            keyboardMonitor: GlobalKeyboardMonitor(),
            pointerMovementObserver: PointerMovementObserver(),
            cursorController: cursorController,
            userInputObserver: userInputObserver,
            targetWindowObserver: TargetWindowObserver(windowServerBridge: windowServerBridge),
            automatedTargetActivityRelay: automatedTargetActivityRelay,
            visibilityMonitor: TargetWindowVisibilityMonitor(),
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
        guard let actionBackend else { return }
        let restoreFinished = DispatchSemaphore(value: 0)
        Task.detached {
            await actionBackend.restoreTargetAccessibilityModes()
            restoreFinished.signal()
        }
        _ = restoreFinished.wait(timeout: .now() + 0.5)
    }
}
