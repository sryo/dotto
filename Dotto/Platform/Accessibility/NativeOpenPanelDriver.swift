import AppKit
import ApplicationServices

/// Drives the macOS open panel (NSOpenPanel) that a file control opens, through Accessibility plus real keyboard
/// events. Per-process keys never reach the panel (Chromium routes them to the browser window, and a sandboxed app's
/// panel runs in the system panel service), so this is the one place Dotto types focused keys (AGENTS.md invariant
/// 3c): only inside the user-approved assist, and only after FocusedKeyboardInputGuard, before every chunk, finds the
/// target (or the panel service drawing this panel) in front, the keyboard focus where the keys are meant to go (read
/// through Accessibility; unreadable focus refuses), the run live and the user idle.
/// The keys are "/" (which opens Go to Folder from the file list), the path, and Return. ⇧⌘G is never sent: it is a
/// key equivalent, and Chrome answers it with its own Find Previous.
/// Buttons are found by role attribute or AppKit identifier, never by title, so any UI language works.
final class NativeOpenPanelDriver {
    private static let pollIntervalNanoseconds: UInt64 = 100_000_000
    private static let goToFieldWaitSeconds: TimeInterval = 1.5
    private static let selectionWaitSeconds: TimeInterval = 1.5
    private static let panelCloseWaitSeconds: TimeInterval = 3
    static let maximumPanelSearchNodeCount = 3000
    /// Where "/" opens Go to Folder. A text field or the panel's search field would take it as text instead.
    static let fileListRoles: Set<String> = [kAXOutlineRole, kAXTableRole, kAXBrowserRole, kAXListRole]
    static let textEntryRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole]
    static let confirmButtonIdentifier = "OKButton"
    static let cancelButtonIdentifier = "CancelButton"

    private let inputSynthesizer: InputSynthesizer
    let realUserInputCounter: RealUserInputCounter

    init(inputSynthesizer: InputSynthesizer, realUserInputCounter: RealUserInputCounter) {
        self.inputSynthesizer = inputSynthesizer
        self.realUserInputCounter = realUserInputCounter
    }

    func waitForOpenPanel(of application: TargetApplicationReference, timeoutSeconds: TimeInterval,
                          abortSignal: TaskAbortSignal) async throws -> AXUIElement {
        var openPanel: AXUIElement?
        try await waitUntil(timeoutSeconds: timeoutSeconds, abortSignal: abortSignal) {
            openPanel = self.openPanelIfPresent(of: application)
            return openPanel != nil
        }
        guard let openPanel else {
            throw ActionBackendError.inputNotDelivered("the file dialog didn't open", foregroundAssistMayHelp: false)
        }
        return openPanel
    }

    /// AppKit tags the panel "open-panel", as a sheet on one of the app's windows or as a window of its own. A sheet
    /// or dialog with a confirm and a cancel button also counts.
    func openPanelIfPresent(of application: TargetApplicationReference) -> AXUIElement? {
        let applicationElement = AccessibilityElementReader.makeApplicationElement(for: application.processIdentifier)
        for applicationWindow in AccessibilityElementReader.elementArrayAttribute(kAXWindowsAttribute, of: applicationElement) {
            let sheetsAndDialogs = AccessibilityElementReader.elementArrayAttribute(kAXChildrenAttribute, of: applicationWindow)
                .filter { AccessibilityElementReader.role(of: $0) == kAXSheetRole } + [applicationWindow]
            if let openPanel = sheetsAndDialogs.first(where: Self.looksLikeOpenPanel) { return openPanel }
        }
        return nil
    }

    /// Runs inside the foreground assist: "/" in the file list, the path typed into Go to Folder, Return, then the
    /// selection is verified and confirmed through Accessibility. One file is typed as a full path, which selects it;
    /// several files (always from one folder) are selected as rows after going to their folder. The caller cancels
    /// the panel on any error, and the assist puts the user's app, window and cursor back.
    func chooseFiles(canonicalFilePaths: [String], in openPanel: AXUIElement, targetApplication: TargetApplicationReference,
                     realUserInputCountAtAssistStart: Int?, abortSignal: TaskAbortSignal) async throws {
        guard let firstFilePath = canonicalFilePaths.first else { return }
        let fileBasenames = canonicalFilePaths.map { ($0 as NSString).lastPathComponent }
        let pathToGoTo = canonicalFilePaths.count == 1 ? firstFilePath : (firstFilePath as NSString).deletingLastPathComponent
        // Only the service process drawing this very panel may be in front; any other panel it draws is not ours.
        let owningPanelServiceProcessIdentifiers = Self.panelServiceProcessIdentifiers(drawing: openPanel,
                                                                                       targetApplication: targetApplication)
        func verifyFocusedKeyboardInputIsSafe(_ expectedKeyboardFocus: ExpectedKeyboardFocus) async throws {
            try await self.verifyFocusedKeyboardInputIsSafe(
                openPanel: openPanel, targetApplication: targetApplication,
                owningPanelServiceProcessIdentifiers: owningPanelServiceProcessIdentifiers,
                expectedKeyboardFocus: expectedKeyboardFocus,
                realUserInputCountAtAssistStart: realUserInputCountAtAssistStart, abortSignal: abortSignal)
        }

        let goToFolderField = try await openGoToFolderField(in: openPanel, targetApplication: targetApplication,
                                                            abortSignal: abortSignal,
                                                            verifyFocusedKeyboardInputIsSafe: verifyFocusedKeyboardInputIsSafe)
        try await typePath(pathToGoTo, into: goToFolderField, abortSignal: abortSignal,
                           verifyFocusedKeyboardInputIsSafe: verifyFocusedKeyboardInputIsSafe)
        // Return goes exactly where the path went, and only while the field still holds exactly that path.
        try await verifyFocusedKeyboardInputIsSafe(.goToFolderField(goToFolderField))
        guard AccessibilityElementReader.stringAttribute(kAXValueAttribute, of: goToFolderField) == pathToGoTo else {
            throw ActionBackendError.inputNotDelivered("the file dialog's Go to Folder field changed before Dotto could confirm it",
                                                       foregroundAssistMayHelp: false)
        }
        try pressFocusedKey(named: "return", abortSignal: abortSignal)

        if canonicalFilePaths.count > 1 {
            try await waitUntil(timeoutSeconds: Self.selectionWaitSeconds, abortSignal: abortSignal) {
                Self.selectRows(named: Set(fileBasenames), in: openPanel)
            }
        }
        let selectionMatches = try await waitUntil(timeoutSeconds: Self.selectionWaitSeconds, abortSignal: abortSignal) {
            Set(Self.selectedRowTexts(in: openPanel).compactMap { rowTexts in fileBasenames.first(where: rowTexts.contains) })
                == Set(fileBasenames)
        }
        guard selectionMatches else {
            throw ActionBackendError.inputNotDelivered("the file dialog didn't select \(fileBasenames.joined(separator: ", "))",
                                                       foregroundAssistMayHelp: false)
        }

        try abortSignal.throwIfAborted()
        guard let defaultButton = Self.button(kAXDefaultButtonAttribute, identifier: Self.confirmButtonIdentifier, of: openPanel) else {
            throw ActionBackendError.inputNotDelivered("the file dialog has no confirm button", foregroundAssistMayHelp: false)
        }
        try inputSynthesizer.performAccessibilityAction(kAXPressAction, on: defaultButton, abortSignal: abortSignal)
        let panelClosed = try await waitUntil(timeoutSeconds: Self.panelCloseWaitSeconds, abortSignal: abortSignal) {
            AccessibilityElementReader.role(of: openPanel) == nil
        }
        guard panelClosed else {
            throw ActionBackendError.inputNotDelivered("the file dialog didn't close", foregroundAssistMayHelp: false)
        }
    }

    /// Presses the panel's cancel button, so an abort or error never leaves a modal sheet open in the user's app.
    func cancel(_ openPanel: AXUIElement) {
        guard let cancelButton = Self.button(kAXCancelButtonAttribute, identifier: Self.cancelButtonIdentifier, of: openPanel) else { return }
        _ = AXUIElementPerformAction(cancelButton, kAXPressAction as CFString)
    }

    // MARK: - Steps

    /// Typing "/" while the panel's file list has keyboard focus opens Go to Folder with "/" filled in. The list is
    /// focused through Accessibility first when focus sits in the panel's search field, where "/" would be text.
    private func openGoToFolderField(in openPanel: AXUIElement, targetApplication: TargetApplicationReference,
                                     abortSignal: TaskAbortSignal,
                                     verifyFocusedKeyboardInputIsSafe: (ExpectedKeyboardFocus) async throws -> Void) async throws -> AXUIElement {
        if let alreadyOpenGoToFolderField = Self.goToFolderField(in: openPanel) { return alreadyOpenGoToFolderField }
        if !Self.keyboardFocus(of: targetApplication, isOnFileListOf: openPanel),
           let fileList = Self.firstPanelElement(in: openPanel, where: { Self.fileListRoles.contains(AccessibilityElementReader.role(of: $0) ?? "") }) {
            try? inputSynthesizer.focusAccessibilityElement(fileList, abortSignal: abortSignal)
            try await waitUntil(timeoutSeconds: Self.goToFieldWaitSeconds, abortSignal: abortSignal) {
                Self.keyboardFocus(of: targetApplication, isOnFileListOf: openPanel)
            }
        }
        // A real key press of the layout's "/" key (with whatever Shift or Option the layout needs), as the user would
        // type it; no Command, so it is never a menu key equivalent.
        try await verifyFocusedKeyboardInputIsSafe(.fileListInsidePanel)
        try pressFocusedKey(named: "/", abortSignal: abortSignal)
        var goToFolderField: AXUIElement?
        try await waitUntil(timeoutSeconds: Self.goToFieldWaitSeconds, abortSignal: abortSignal) {
            goToFolderField = Self.goToFolderField(in: openPanel)
            return goToFolderField != nil
        }
        guard let goToFolderField else {
            throw ActionBackendError.inputNotDelivered("the file dialog's Go to Folder field didn't open", foregroundAssistMayHelp: false)
        }
        return goToFolderField
    }

    /// The field opens holding "/" or the last folder. Its text is selected through Accessibility and the path typed
    /// over it, but only once Accessibility shows the field itself has keyboard focus. The field may complete a path
    /// inline; Return is only pressed when its value is exactly the path, so a completion is taken back first.
    private func typePath(_ pathToGoTo: String, into goToFolderField: AXUIElement, abortSignal: TaskAbortSignal,
                          verifyFocusedKeyboardInputIsSafe: (ExpectedKeyboardFocus) async throws -> Void) async throws {
        try? inputSynthesizer.focusAccessibilityElement(goToFolderField, abortSignal: abortSignal)
        let fieldHasFocus = try await waitUntil(timeoutSeconds: Self.goToFieldWaitSeconds, abortSignal: abortSignal) {
            Self.goToFolderFieldHasKeyboardFocus(goToFolderField)
        }
        guard fieldHasFocus else {
            throw ActionBackendError.inputNotDelivered("Dotto couldn't confirm that the Go to Folder field has keyboard focus",
                                                       foregroundAssistMayHelp: false)
        }
        let existingFieldText = AccessibilityElementReader.stringAttribute(kAXValueAttribute, of: goToFolderField) ?? ""
        if !existingFieldText.isEmpty {
            let selectedThroughAccessibility = try inputSynthesizer.selectEntireText(
                of: goToFolderField, textLengthInUTF16CodeUnits: existingFieldText.utf16.count, abortSignal: abortSignal)
            if !selectedThroughAccessibility {
                // No ⌘A: a key equivalent can reach the app's own menus instead of the field.
                guard (try? inputSynthesizer.setAccessibilityValue("", on: goToFolderField, abortSignal: abortSignal)) != nil,
                      (AccessibilityElementReader.stringAttribute(kAXValueAttribute, of: goToFolderField) ?? "").isEmpty else {
                    throw ActionBackendError.inputNotDelivered("the Go to Folder field's old text couldn't be replaced",
                                                               foregroundAssistMayHelp: false)
                }
            }
        }
        try await inputSynthesizer.typeFocusedUnicodeText(pathToGoTo, abortSignal: abortSignal,
                                                          verifyFocusedTargetBeforeChunk: {
                                                              try await verifyFocusedKeyboardInputIsSafe(.goToFolderField(goToFolderField))
                                                          })
        var fieldValue = ""
        let pathArrived = try await waitUntil(timeoutSeconds: Self.goToFieldWaitSeconds, abortSignal: abortSignal) {
            fieldValue = AccessibilityElementReader.stringAttribute(kAXValueAttribute, of: goToFolderField) ?? ""
            return fieldValue.hasPrefix(pathToGoTo)
        }
        guard pathArrived else {
            throw ActionBackendError.inputNotDelivered("the path didn't arrive in the file dialog's Go to Folder field",
                                                       foregroundAssistMayHelp: false)
        }
        if fieldValue != pathToGoTo {
            try? inputSynthesizer.setAccessibilityValue(pathToGoTo, on: goToFolderField, abortSignal: abortSignal)
            let pathIsExact = try await waitUntil(timeoutSeconds: Self.goToFieldWaitSeconds, abortSignal: abortSignal) {
                AccessibilityElementReader.stringAttribute(kAXValueAttribute, of: goToFolderField) == pathToGoTo
            }
            guard pathIsExact else {
                throw ActionBackendError.inputNotDelivered("the Go to Folder field completed the path to something else",
                                                           foregroundAssistMayHelp: false)
            }
        }
    }

    /// Only the modifiers the layout needs to produce the key's character; never Command.
    private func pressFocusedKey(named keyName: String, abortSignal: TaskAbortSignal) throws {
        guard let keyStroke = inputSynthesizer.resolveKeyStroke(forKeyName: keyName) else {
            throw ActionBackendError.unknownKeyName(keyName)
        }
        try inputSynthesizer.postFocusedKeyPress(virtualKeyCode: keyStroke.virtualKeyCode, modifiers: keyStroke.requiredModifiers,
                                                 abortSignal: abortSignal)
    }

    @discardableResult
    private func waitUntil(timeoutSeconds: TimeInterval, abortSignal: TaskAbortSignal, condition: () -> Bool) async throws -> Bool {
        let deadlineUptime = ProcessInfo.processInfo.systemUptime + timeoutSeconds
        while ProcessInfo.processInfo.systemUptime < deadlineUptime {
            try abortSignal.throwIfAborted()
            if condition() { return true }
            try await Task.sleep(nanoseconds: Self.pollIntervalNanoseconds)
        }
        return condition()
    }
}
