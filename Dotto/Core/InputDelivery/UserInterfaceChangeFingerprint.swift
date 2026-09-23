import Foundation

/// What an event tier is judged by: input that may have landed but changed none of this is reported as not
/// delivered instead of being retried, because a retry could toggle something twice.
struct UserInterfaceChangeFingerprint: Equatable, Sendable {
    var focusedElementToken: Int?
    /// A hash of the focused element's value; the text itself is never stored.
    var focusedElementValueToken: Int?
    var selectedTextRangeToken: Int?
    /// Value, selection, expansion and existence of the acted-on element.
    var targetElementStateToken: Int?
    var windowCount: Int
    var focusedWindowTitle: String?
    var webAreaAddress: String?
    var focusedWindowChildCount: Int
    /// Filled only when every Accessibility part is equal, since capturing the window costs far more.
    var windowImageThumbnail: WindowImageThumbnail?

    static func showsObservableChange(from before: Self, to after: Self) -> Bool {
        var accessibilityPartsBefore = before
        var accessibilityPartsAfter = after
        accessibilityPartsBefore.windowImageThumbnail = nil
        accessibilityPartsAfter.windowImageThumbnail = nil
        if accessibilityPartsBefore != accessibilityPartsAfter { return true }
        guard let thumbnailBefore = before.windowImageThumbnail, let thumbnailAfter = after.windowImageThumbnail else {
            return false
        }
        return thumbnailBefore.showsChange(comparedWith: thumbnailAfter)
    }
}
