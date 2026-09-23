import Foundation

/// The one line the cursor's pill shows for a presentation state. The state's own status text is an item label or
/// a mapper constant; this adds the target app's name, the item position and the question being asked.
enum CursorPillText {
    /// Two lines of the pill's 420-point cap at 12.5 points: the pill wraps a question rather than cut it short.
    static let maximumLength = 120

    /// `pausedStatusText` is the takeover wording for the current pause ("Paused · you clicked in Finder"), when known.
    /// `itemPosition` and `itemCount` are the running item's place in the checklist, once an item has started.
    static func text(for presentationState: CursorPresentationState, targetApplicationName: String,
                     pausedStatusText: String?, itemPosition: Int?, itemCount: Int?) -> String {
        let unlimitedPillText = unlimitedText(for: presentationState, targetApplicationName: targetApplicationName,
                                              pausedStatusText: pausedStatusText, itemPosition: itemPosition,
                                              itemCount: itemCount)
        return UserFacingTextSanitizing.singleLine(unlimitedPillText, maximumLength: maximumLength)
    }

    private static func unlimitedText(for presentationState: CursorPresentationState, targetApplicationName: String,
                                      pausedStatusText: String?, itemPosition: Int?, itemCount: Int?) -> String {
        let statusText = presentationState.statusText ?? ""
        switch presentationState.activity {
        case .paused:
            return pausedStatusText ?? statusText
        case .waiting:
            guard let attentionRequest = presentationState.attentionRequest else { return statusText }
            if attentionRequest.kind == .needsBringForward, !targetApplicationName.isEmpty {
                return CursorPresentationStateMapper.bringAppForwardQuestionText(targetApplicationName: targetApplicationName)
            }
            // "Dotto needs your OK · Delete “Q3 draft”": the item the question is about.
            if attentionRequest.kind == .needsDecision, let itemLabel = presentationState.statusTextBeforeInterruption,
               !itemLabel.isEmpty {
                return "\(attentionRequest.title) · \(itemLabel)"
            }
            return attentionRequest.title
        case .replaying:
            // "12 / 23 · Moving IMG_2041": a direct route counts operations, not checklist items.
            if let directOperationProgress = presentationState.directOperationProgress {
                let progressText = "\(directOperationProgress.completedStepCount) / \(directOperationProgress.stepCount)"
                return statusText.isEmpty ? progressText : "\(progressText) · \(statusText)"
            }
            if let itemPosition, let itemCount { return "Replaying · \(itemPosition) / \(itemCount)" }
            return statusText.isEmpty ? "Replaying" : statusText
        case .done:
            return statusText.isEmpty || statusText == "Done" ? "Done" : "Done · \(statusText)"
        case .pointing, .reading, .thinking, .clicking, .typing:
            if let bringForwardText = bringForwardText(for: statusText, targetApplicationName: targetApplicationName) {
                return bringForwardText
            }
            // "2 / 5 · Rename IMG_2042": with the checklist folded into the pill, the pill carries the progress.
            guard let itemPosition, let itemCount else { return statusText }
            let progressText = "\(itemPosition) / \(itemCount)"
            return statusText.isEmpty ? progressText : "\(progressText) · \(statusText)"
        case .error, .hidden:
            return bringForwardText(for: statusText, targetApplicationName: targetApplicationName) ?? statusText
        }
    }

    /// The bring-forward statuses name the target app when it is known.
    private static func bringForwardText(for statusText: String, targetApplicationName: String) -> String? {
        guard !targetApplicationName.isEmpty else { return nil }
        switch statusText {
        case CursorPresentationStateMapper.bringingAppForwardStatusText:
            return "Bringing \(targetApplicationName) forward for a moment"
        case CursorPresentationStateMapper.waitingForUserBeforeBringingAppForwardStatusText:
            return "Waiting for you to pause before bringing \(targetApplicationName) forward"
        case CursorPresentationStateMapper.bringingAppForwardCountdownStatusText:
            return "Bringing \(targetApplicationName) forward…"
        default:
            return nil
        }
    }
}
