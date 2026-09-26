import Foundation
import CoreGraphics

/// One element boxed on a screenshot and labeled with its element id, so the model can click what it sees by id.
struct ScreenshotMark: Equatable, Sendable {
    var elementIdentifier: String
    var boxInImagePixels: CGRect
    var labelRectInImagePixels: CGRect
    /// Neighbouring marks get different colors so their boxes and labels can be told apart.
    var paletteIndex: Int

    static let paletteColorCount = 6
}

enum ScreenshotMarksUnavailableReason: Equatable, Sendable {
    /// The outline's window frame doesn't match the captured one: the window moved or resized in between.
    case windowChangedDuringCapture
    case outlineUnreadable
}

struct ScreenshotMarkLayout: Equatable, Sendable {
    var marks: [ScreenshotMark]
    /// Interactive elements that were visible but left unmarked because of the mark cap.
    var unmarkedCandidateCount: Int
    var unavailableReason: ScreenshotMarksUnavailableReason?

    static func unavailable(_ reason: ScreenshotMarksUnavailableReason) -> ScreenshotMarkLayout {
        ScreenshotMarkLayout(marks: [], unmarkedCandidateCount: 0, unavailableReason: reason)
    }
}

struct ScreenshotMarkLimits: Equatable, Sendable {
    var maximumMarkCount: Int
    /// Caps each text in the mark list, which is shorter than the outline's.
    var maximumListedTextLength: Int
    var minimumVisibleSideInPoints: CGFloat
    /// The share of an element's frame that must be inside its visible area for it to be marked.
    var minimumVisibleFraction: CGFloat
    /// Two candidates whose visible boxes overlap this much (intersection over union) get one mark.
    var duplicateBoxOverlapRatio: CGFloat

    static let executor = ScreenshotMarkLimits(maximumMarkCount: 60, maximumListedTextLength: 60, minimumVisibleSideInPoints: 4,
                                               minimumVisibleFraction: 0.3, duplicateBoxOverlapRatio: 0.8)
    static let planner = ScreenshotMarkLimits(maximumMarkCount: 100, maximumListedTextLength: 60, minimumVisibleSideInPoints: 4,
                                              minimumVisibleFraction: 0.3, duplicateBoxOverlapRatio: 0.8)
}

/// The label font's measurements in image pixels, supplied by whoever draws the labels.
struct ScreenshotLabelMetrics: Equatable, Sendable {
    var characterWidthInPixels: CGFloat
    var labelHeightInPixels: CGFloat
    var horizontalPaddingInPixels: CGFloat

    func labelSize(for labelText: String) -> CGSize {
        CGSize(width: (CGFloat(labelText.count) * characterWidthInPixels + 2 * horizontalPaddingInPixels).rounded(.up),
               height: labelHeightInPixels)
    }
}

/// A screenshot with its marks drawn in, and the snapshot the marks came from. That snapshot is the backend's latest,
/// so the marked ids are the ones `click` resolves.
struct MarkedScreenshotCapture: Equatable, Sendable {
    var screenshotCapture: ScreenshotCapture
    /// nil when the window's elements couldn't be read; the image then has no marks.
    var snapshot: AccessibilityTreeSnapshot?
    var markLayout: ScreenshotMarkLayout
}
