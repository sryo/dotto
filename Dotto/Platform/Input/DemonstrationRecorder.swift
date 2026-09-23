import AppKit

/// Teach mode: turns the user's clicks, shortcuts and typing in one app into DemonstrationEvents.
/// Typed text is never captured keystroke by keystroke; the field's final AXValue is read when the entry is
/// committed (the next click, shortcut, focus change or Done), and never for password fields.
@MainActor final class DemonstrationRecorder {
    private static let editableRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]
    private static let commitKeyNames: Set<String> = ["return", "tab", "escape", "up", "down", "left", "right", "page_up", "page_down"]
    /// Long enough for a click or Tab to move keyboard focus, short enough to land before the user's first keystroke.
    private static let focusSettleNanoseconds: UInt64 = 150_000_000

    static let webPageTypingNote = "Dotto can't record typing in web pages yet."
    static let nonTextPasteNote = "Dotto only records pasting text. A paste of an image or file wasn't recorded."
    static let pasteOutsideTextFieldNote = "Dotto only records pasting into a text field. A paste elsewhere wasn't recorded."

    private struct PendingTextEntry {
        var accessibilityElement: AXUIElement
        var recordedContext: RecordedElementContext
        var valueBeforeTyping: String
    }

    /// The focused text field's value read when focus arrived (mouse-down on it, or shortly after a click or
    /// Tab), before any keystroke. Reading it at the first keydown can already include that key or an autocomplete.
    private struct FocusedFieldBaseline {
        var accessibilityElement: AXUIElement
        var valueBeforeTyping: String
    }

    private enum TextEntryStartResult { case recording, insideWebPage, notATextField }

    private let elementReader: AccessibilityElementReader
    private let inputSynthesizer: InputSynthesizer
    private var recordedApplication: TargetApplicationReference?
    private var recordedEvents: [DemonstrationEvent] = []
    private var pendingTextEntry: PendingTextEntry?
    private var focusedFieldBaseline: FocusedFieldBaseline?
    /// Remembered so typing in a web page doesn't walk up the (deep) web tree on every keystroke.
    private var lastFocusedElementInsideWebPage: AXUIElement?
    /// Bumped on start and stop so a delayed baseline read from an earlier recording is dropped.
    private var recordingGeneration = 0
    /// Things the user did that Dotto could not record, shown on the teaching card so nothing is dropped silently.
    private(set) var recordingNotes: [String] = []

    init(elementReader: AccessibilityElementReader, inputSynthesizer: InputSynthesizer) {
        self.elementReader = elementReader
        self.inputSynthesizer = inputSynthesizer
    }

    var isRecording: Bool { recordedApplication != nil }
    var recordedEventCount: Int { recordedEvents.count }

    func startRecording(application: TargetApplicationReference) {
        recordingGeneration += 1
        recordedApplication = application
        recordedEvents = []
        pendingTextEntry = nil
        focusedFieldBaseline = nil
        lastFocusedElementInsideWebPage = nil
        recordingNotes = []
        // The user may start typing straight into the field that already has focus.
        captureFocusedFieldBaseline(in: application)
    }

    func handleObservedUserInput(_ observedEvent: ObservedUserInputEvent) {
        guard let recordedApplication, !observedEvent.isSynthesizedByThisApp else { return }
        switch observedEvent.kind {
        case .mouseMoved, .scrollWheel:
            return
        case .mouseDown(let isRightButton, let clickCount):
            commitPendingTextEntry()
            scheduleFocusedFieldBaselineCapture()
            let clickPoint = observedEvent.topLeftGlobalLocation
            guard Self.isClickInsideRecordedApplication(atTopLeftGlobalPoint: clickPoint, application: recordedApplication,
                                                        elementReader: elementReader),
                  let (clickedElement, clickedTarget) = elementReader.elementWithRecordedContext(atTopLeftGlobalPoint: clickPoint,
                                                                                                 in: recordedApplication) else { return }
            captureBaselineIfEditableTextField(clickedElement, role: clickedTarget.element.role,
                                               isSecureTextField: clickedTarget.element.isSecureTextField)
            var clickType = AgentClickType.single
            if isRightButton {
                clickType = .right
            } else if clickCount == 2, case .click(let previousTarget, .single)? = recordedEvents.last,
                      Self.isSameElement(previousTarget, clickedTarget) {
                recordedEvents.removeLast()
                clickType = .double
            }
            recordedEvents.append(.click(target: clickedTarget, clickType: clickType))
        case .keyDown(let virtualKeyCode, let modifiers, _):
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == recordedApplication.processIdentifier else { return }
            recordKeyDown(virtualKeyCode: virtualKeyCode, modifiers: modifiers, application: recordedApplication)
        }
    }

    func stopRecording() -> DemonstrationRecording {
        commitPendingTextEntry()
        recordingGeneration += 1
        let application = recordedApplication ?? TargetApplicationReference(processIdentifier: 0, applicationName: "", bundleIdentifier: nil)
        var localElementNumber = 1
        let finalSnapshot = try? elementReader.readSnapshot(of: application, scope: .focusedWindow, snapshotGeneration: 0,
                                                            nextElementNumber: &localElementNumber, shouldAbortWalk: { false }).snapshot
        let recording = DemonstrationRecording(application: application, events: recordedEvents,
                                               finalWindowTitle: finalSnapshot?.windowTitle,
                                               finalWindowDocument: finalSnapshot?.focusedWindowDocument)
        recordedApplication = nil
        recordedEvents = []
        focusedFieldBaseline = nil
        lastFocusedElementInsideWebPage = nil
        return recording
    }

    // MARK: - Keys and typing

    private func recordKeyDown(virtualKeyCode: Int64, modifiers: [AgentKeyModifier], application: TargetApplicationReference) {
        let keyName = inputSynthesizer.keyName(forVirtualKeyCode: CGKeyCode(truncatingIfNeeded: virtualKeyCode))
        // Option (with or without shift) types characters such as "é", so only command/control make a shortcut.
        let isShortcut = modifiers.contains(.command) || modifiers.contains(.control)
        let isPasteShortcut = keyName == "v" && modifiers.contains(.command) && !modifiers.contains(.control)
        if isPasteShortcut {
            recordPaste(application: application)
            return
        }
        guard isShortcut || keyName.map(Self.commitKeyNames.contains) == true else {
            // A plain keystroke: remember which field is being edited and its value from before the edit.
            if beginOrContinueTextEntry(application: application) == .insideWebPage {
                addRecordingNote(Self.webPageTypingNote)
            }
            return
        }
        commitPendingTextEntry()
        guard let keyName else { return }
        recordedEvents.append(.keyChord(keyName: keyName, modifiers: modifiers))
        // Tab, Return and many shortcuts move focus to another field.
        scheduleFocusedFieldBaselineCapture()
    }

    /// A recorded cmd+V would paste whatever is on the clipboard at replay time. Instead the paste becomes part of
    /// the field's text entry, so the committed value (with the pasted text) is typed as a literal the user reviews.
    private func recordPaste(application: TargetApplicationReference) {
        guard NSPasteboard.general.string(forType: .string) != nil else {
            addRecordingNote(Self.nonTextPasteNote)
            return
        }
        switch beginOrContinueTextEntry(application: application) {
        case .recording: return
        case .insideWebPage: addRecordingNote(Self.webPageTypingNote)
        case .notATextField: addRecordingNote(Self.pasteOutsideTextFieldNote)
        }
    }

    /// Runs on every keystroke, so the common case (still typing in the same field) is a single AX read.
    private func beginOrContinueTextEntry(application: TargetApplicationReference) -> TextEntryStartResult {
        guard let focusedElement = elementReader.applicationFocusedElement(of: application) else { return .notATextField }
        if let pendingTextEntry {
            if CFEqual(pendingTextEntry.accessibilityElement, focusedElement) { return .recording }
            // Focus moved to another field mid-typing (auto-advance, a script): the previous field is finished.
            commitPendingTextEntry()
        }
        if let lastFocusedElementInsideWebPage, CFEqual(lastFocusedElementInsideWebPage, focusedElement) { return .insideWebPage }
        if elementReader.isInsideWebArea(focusedElement) {
            lastFocusedElementInsideWebPage = focusedElement
            return .insideWebPage
        }
        guard let focusedRole = AccessibilityElementReader.role(of: focusedElement), Self.editableRoles.contains(focusedRole),
              !elementReader.isSecureTextField(focusedElement),
              let focusedContext = elementReader.recordedElementContext(of: focusedElement, in: application),
              !focusedContext.element.isSecureTextField else { return .notATextField }
        let valueBeforeTyping: String
        if let focusedFieldBaseline, CFEqual(focusedFieldBaseline.accessibilityElement, focusedElement) {
            valueBeforeTyping = focusedFieldBaseline.valueBeforeTyping
        } else {
            // No baseline for this field (focus moved without a click or key Dotto saw); best effort.
            valueBeforeTyping = elementReader.untruncatedStringValue(of: focusedElement) ?? ""
        }
        focusedFieldBaseline = nil
        pendingTextEntry = PendingTextEntry(accessibilityElement: focusedElement, recordedContext: focusedContext,
                                            valueBeforeTyping: valueBeforeTyping)
        return .recording
    }

    private func commitPendingTextEntry() {
        guard let pendingTextEntry else { return }
        self.pendingTextEntry = nil
        guard !elementReader.isSecureTextField(pendingTextEntry.accessibilityElement),
              let finalValue = elementReader.untruncatedStringValue(of: pendingTextEntry.accessibilityElement),
              finalValue != pendingTextEntry.valueBeforeTyping else { return }
        recordedEvents.append(.textEntered(target: pendingTextEntry.recordedContext, finalValue: finalValue))
    }

    private func addRecordingNote(_ recordingNote: String) {
        if !recordingNotes.contains(recordingNote) { recordingNotes.append(recordingNote) }
    }

    // MARK: - Value baselines

    private func captureBaselineIfEditableTextField(_ accessibilityElement: AXUIElement, role: String, isSecureTextField: Bool) {
        guard Self.editableRoles.contains(role), !isSecureTextField,
              !elementReader.isSecureTextField(accessibilityElement) else { return }
        focusedFieldBaseline = FocusedFieldBaseline(
            accessibilityElement: accessibilityElement,
            valueBeforeTyping: elementReader.untruncatedStringValue(of: accessibilityElement) ?? "")
    }

    private func captureFocusedFieldBaseline(in application: TargetApplicationReference) {
        guard let focusedElement = elementReader.applicationFocusedElement(of: application),
              let focusedRole = AccessibilityElementReader.role(of: focusedElement) else { return }
        captureBaselineIfEditableTextField(focusedElement, role: focusedRole, isSecureTextField: false)
    }

    /// Mouse-down and key events reach the tap before the app moves focus, so the newly focused field is read a
    /// moment later. Skipped once the user has started typing, which already fixed the baseline.
    private func scheduleFocusedFieldBaselineCapture() {
        let recordingGenerationAtSchedule = recordingGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.focusSettleNanoseconds)
            guard let self, self.recordingGeneration == recordingGenerationAtSchedule, self.pendingTextEntry == nil,
                  let recordedApplication = self.recordedApplication else { return }
            self.captureFocusedFieldBaseline(in: recordedApplication)
        }
    }

    // MARK: - Click ownership

    /// The app-level hit test answers for the recorded app's element under the point even when another app's window
    /// covers it, so a click is only recorded when the recorded app is frontmost and owns what is actually on top.
    private static func isClickInsideRecordedApplication(atTopLeftGlobalPoint topLeftGlobalPoint: CGPoint,
                                                         application: TargetApplicationReference,
                                                         elementReader: AccessibilityElementReader) -> Bool {
        let recordedProcessIdentifier = application.processIdentifier
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == recordedProcessIdentifier else { return false }
        let topmostWindowOwnerProcessIdentifier = WindowListEntryClassification.topmostWindowOwnerProcessIdentifier(
            atTopLeftGlobalPoint: topLeftGlobalPoint)
        if let topmostWindowOwnerProcessIdentifier, topmostWindowOwnerProcessIdentifier != recordedProcessIdentifier { return false }
        var topmostElementProcessIdentifier = elementReader.processIdentifierOfElement(atTopLeftGlobalPoint: topLeftGlobalPoint)
        // Dotto's own windows are filtered by the controller before input reaches the recorder.
        if topmostElementProcessIdentifier == getpid() { topmostElementProcessIdentifier = nil }
        if let topmostElementProcessIdentifier, topmostElementProcessIdentifier != recordedProcessIdentifier { return false }
        return topmostWindowOwnerProcessIdentifier != nil || topmostElementProcessIdentifier != nil
    }

    /// Selection state changes on the first click of a double click, so identity is role, title and frame.
    private static func isSameElement(_ firstContext: RecordedElementContext, _ secondContext: RecordedElementContext) -> Bool {
        firstContext.element.role == secondContext.element.role && firstContext.element.title == secondContext.element.title
            && firstContext.element.frameInTopLeftGlobalPoints == secondContext.element.frameInTopLeftGlobalPoints
    }
}
