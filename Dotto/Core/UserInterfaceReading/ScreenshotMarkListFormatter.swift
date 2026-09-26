import Foundation
import CoreGraphics

/// The text that goes with a marked screenshot: Dotto's own note about the marks, and one line per mark in the
/// outline's format. The lines quote the app's labels, so callers fence them as untrusted.
enum ScreenshotMarkListFormatter {
    static func formatMarkList(_ markLayout: ScreenshotMarkLayout, snapshot: AccessibilityTreeSnapshot?,
                               limits: ScreenshotMarkLimits) -> (appAuthoredHeader: String, untrustedLines: String?) {
        switch markLayout.unavailableReason {
        case .windowChangedDuringCapture:
            return ("No elements are marked: the window moved or changed while it was captured. Take another screenshot, "
                        + "or use read_ui.", nil)
        case .outlineUnreadable:
            return ("No elements are marked: the window's elements couldn't be read.", nil)
        case nil:
            break
        }
        guard let snapshot, !markLayout.marks.isEmpty else {
            return ("No interactive elements are marked in this window. Use read_ui to find elements.", nil)
        }

        let lineLimits = AccessibilityOutlineLimits(maximumCharacterCount: .max, maximumChildrenShownPerNode: .max,
                                                    maximumTextLength: limits.maximumListedTextLength)
        let markLines = markLayout.marks.compactMap { mark -> String? in
            guard let markedNode = snapshot.node(withIdentifier: mark.elementIdentifier) else { return nil }
            return "[\(mark.elementIdentifier)] " + AccessibilityOutlineFormatter.elementDescription(for: markedNode, limits: lineLimits)
        }
        var header = "\(markLayout.marks.count) interactive elements are boxed and labeled with their ids (snapshot "
            + "\(snapshot.snapshotGeneration)). These ids replace the latest outline's: click them with click."
        if markLayout.unmarkedCandidateCount > 0 {
            header += " \(markLayout.unmarkedCandidateCount) more interactive elements have no mark; read_ui with a query finds them."
        }
        return (header, markLines.joined(separator: "\n"))
    }
}
