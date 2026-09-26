import Foundation
import CoreGraphics

/// Why a screenshot of the task window would show nothing useful. Dotto never un-minimizes, unhides or switches Spaces
/// to fix it, because each of those would disturb the user's screen.
enum ScreenshotUnavailableReason: Equatable, Sendable {
    case windowMinimized
    case applicationHidden
    case windowOnAnotherSpace
    case blankCapture

    var guidanceForModel: String {
        let explanation: String
        switch self {
        case .windowMinimized: explanation = "The window is minimized in the Dock, so a screenshot would show nothing."
        case .applicationHidden: explanation = "The app is hidden, so a screenshot of its window would show nothing."
        case .windowOnAnotherSpace: explanation = "The window is on another Space, so a screenshot would show nothing current."
        case .blankCapture: explanation = "The window's capture came back blank."
        }
        return explanation + " Use read_ui instead. If the item can't be done without seeing the window, call finish_item "
            + "with needs_user."
    }
}

enum WindowCaptureAssessment {
    /// A real window always shows some structure (a title bar, a toolbar, text), so a capture whose darkest and
    /// lightest cells are this close is empty rather than a window.
    static let maximumGrayLevelSpreadOfBlankCapture = 6

    static func isBlank(_ thumbnail: WindowImageThumbnail) -> Bool {
        guard let darkestCell = thumbnail.grayscaleCells.min(), let lightestCell = thumbnail.grayscaleCells.max() else { return true }
        return Int(lightestCell) - Int(darkestCell) <= maximumGrayLevelSpreadOfBlankCapture
    }

    /// Minimized and hidden are certain from their flags. Another Space only counts once the capture also came back
    /// blank, since some apps' windows still capture fine there.
    static func unavailableReason(windowIsMinimized: Bool, applicationIsHidden: Bool, windowIsOnAnotherSpace: Bool,
                                  captureIsBlank: Bool) -> ScreenshotUnavailableReason? {
        if windowIsMinimized { return .windowMinimized }
        if applicationIsHidden { return .applicationHidden }
        if windowIsOnAnotherSpace && captureIsBlank { return .windowOnAnotherSpace }
        if captureIsBlank { return .blankCapture }
        return nil
    }
}
