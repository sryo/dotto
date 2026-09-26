import AppKit

/// Pause, resume and skip from the checklist panel, and the takeover pause when the user clicks, scrolls or types in
/// the target app or moves or closes its window.
extension TaskSessionController {
    /// Only the session whose app the action went to hears about it; activity that names no app (a bring-forward
    /// assist and its restore) reaches every session.
    func routeAutomatedTargetActivity(_ automatedActivity: AutomatedTargetActivity, atTimestampSeconds timestampSeconds: TimeInterval,
                                      targetProcessIdentifier: pid_t?) {
        for session in [currentSession] where targetProcessIdentifier == nil
            || session.targetApplication?.processIdentifier == targetProcessIdentifier {
            session.userTakeoverDetector.noteAutomatedActivity(automatedActivity, atTimestampSeconds: timestampSeconds)
        }
    }

    func pauseTask(reason: TaskPauseReason = .requestedByUser) {
        guard case .executing = sessionState, let currentRunControl else { return }
        currentRunControl.requestPause(reason: reason)
        apply(.pauseRequested(reason))
        cursorController.handle(.paused(reason))
        statusLine = "Paused"
        showChecklistPanelIfCursorCannotCarryIt()
        currentAuditLogWriter?.append(eventKind: .pause, itemIdentifier: nil, message: reason.bannerText, details: [:])
    }

    func resumeTask() {
        guard case .paused = sessionState else { return }
        noteUserAnsweredThisAppPanel()
        leavePausedState()
        checklistPanelController?.resignKeyWithoutHiding()
        statusLine = TaskUserFacingMessages.continuingStatusLine
        currentAuditLogWriter?.append(eventKind: .resume, itemIdentifier: nil, message: "Resumed by the user", details: [:])
    }

    /// While running, only an item in progress can be skipped (a skip between items would be dropped). While
    /// paused between items, TaskRunControl keeps the skip for the item that starts next.
    func skipCurrentItem() {
        guard let currentRunControl else { return }
        let skipsNextItem: Bool
        switch sessionState {
        case .executing(_, let currentItemIdentifier):
            guard currentItemIdentifier != nil else { return }
            skipsNextItem = false
        case .paused(_, let currentItemIdentifier, _):
            skipsNextItem = currentItemIdentifier == nil
        default:
            return
        }
        // Requested before leaving the paused state, so TaskRunControl records it as a skip made while paused.
        currentRunControl.requestSkipCurrentItem()
        leavePausedState()
        statusLine = skipsNextItem ? "Skipping the next item…" : TaskUserFacingMessages.skippingThisItemStatusLine
    }

    /// Also runs when a confirmation or failure card arrives while paused: the executor can ask after the user
    /// paused but before it reached a checkpoint, and the card waits for the user anyway.
    func leavePausedState() {
        guard case .paused = sessionState else { return }
        currentRunControl?.resume()
        apply(.resumeRequested)
        // Whatever the user did to the window while paused is where the run goes on from; only a later move counts.
        // A task window closed during the pause gives way to the app's front window.
        let pinnedWindowFrameAfterPause = targetWindowObserver.pinnedTargetWindowFrameInTopLeftGlobalPoints
            ?? targetWindowObserver.pinFrontWindow()
        userTakeoverDetector.rebaselinePinnedTargetWindowFrame(pinnedWindowFrameAfterPause)
        cursorController.handle(.resumed)
    }

    /// Resume, Allow, Skip and the other pill answers: the click that answered must not come back as a takeover.
    func noteUserAnsweredThisAppPanel() {
        userTakeoverDetector.noteUserAnsweredThisAppPanel(atTimestampSeconds: UserInputObserver.currentMonotonicTimestampSeconds())
    }

    func routeObservedUserInput(_ observedEvent: ObservedUserInputEvent) {
        // Clicking Pause or Skip on Dotto's own panels is not a takeover, nor part of a demonstration.
        if userInputObserver.pointerEventWasDeliveredToThisApp(observedEvent) || Self.isPointerEventOverThisAppWindow(observedEvent) {
            return
        }
        switch sessionState {
        case .executing:
            guard let targetProcessIdentifier = targetApplication?.processIdentifier else { return }
            if let takeoverInputKind = userTakeoverDetector.takeoverKind(for: observedEvent,
                                                                         targetProcessIdentifier: targetProcessIdentifier) {
                pauseTask(reason: .userTookOver(takeoverInputKind))
            }
        case .demonstrating(_, _, false):
            demonstrationRecorder.handleObservedUserInput(observedEvent)
            recordedDemonstrationEventCount = demonstrationRecorder.recordedEventCount
            if demonstrationRecordingNotes != demonstrationRecorder.recordingNotes {
                demonstrationRecordingNotes = demonstrationRecorder.recordingNotes
            }
        default:
            break
        }
    }

    func routeTargetWindowEvent(_ targetWindowEvent: ObservedTargetWindowEvent) {
        guard case .executing = sessionState else { return }
        switch userTakeoverDetector.decision(for: targetWindowEvent) {
        case .ignore:
            if targetWindowEvent.isOnPinnedTargetWindow {
                print("Dotto takeover watch: the task window \(targetWindowEvent.kind) with no change or right after Dotto's own step; not a takeover")
            }
        case .takeover(let takeoverInputKind):
            pauseTask(reason: .userTookOver(takeoverInputKind))
        case .repinTargetWindowToFrontWindow:
            let repinnedWindowFrame = targetWindowObserver.pinFrontWindow()
            userTakeoverDetector.rebaselinePinnedTargetWindowFrame(repinnedWindowFrame)
            currentAuditLogWriter?.append(eventKind: .takeoverWatch, itemIdentifier: nil,
                                          message: "Dotto's own step closed the task window; following the app's front window",
                                          details: ["new_window_found": repinnedWindowFrame == nil ? "false" : "true"])
        }
    }

    /// Overlays ignore mouse events, panels don't: a click on Dotto's own panel is never a takeover. A click in a
    /// panel's transparent shadow margin goes to the app behind it, so it counts as the user's.
    private static func isPointerEventOverThisAppWindow(_ observedEvent: ObservedUserInputEvent) -> Bool {
        if case .keyDown = observedEvent.kind { return false }
        return DottoWindowPointerHitTest.isTopLeftGlobalPointOverThisAppWindowContent(observedEvent.topLeftGlobalLocation)
    }
}
