import CoreGraphics
import Foundation

/// One pointer position in top-left screen coordinates (y grows downward), with a monotonic timestamp in seconds.
struct SummonGesturePointerSample: Equatable, Sendable {
    var x: Double
    var y: Double
    var timestamp: TimeInterval

    init(x: Double, y: Double, timestamp: TimeInterval) {
        self.x = x
        self.y = y
        self.timestamp = timestamp
    }
}

/// How the buffered path relates to a circle around its own centroid.
struct SummonGestureAnalysis: Equatable, Sendable {
    /// `abs(winding) / 2π`.
    var loops: Double
    var meanRadius: Double
    /// Standard deviation of the radii divided by their mean: 0 for a perfect circle.
    var roundness: Double
    /// Signed radians swept around the centroid; positive is clockwise on screen.
    var winding: Double
    /// Share of the absolute angular travel that went against the net winding: 0 for a clean loop.
    var reversalFraction: Double
    /// nil until there are enough samples to analyze.
    var centroid: CGPoint?
    var directionMatches: Bool
    var sizeFits: Bool
    /// `loops / loopsNeeded` when the direction matches, else 0. Not clamped to 1.
    var progress: Double
    /// Direction, size, strict roundness and the reversal limit all hold.
    var isValid: Bool
    /// Direction, size and the reversal limit hold and roundness is within the loose tolerance the ring uses.
    var looksLikeACircle: Bool

    static let empty = SummonGestureAnalysis(loops: 0, meanRadius: 0, roundness: 1, winding: 0, reversalFraction: 0, centroid: nil,
                                             directionMatches: false, sizeFits: false, progress: 0,
                                             isValid: false, looksLikeACircle: false)
}

enum SummonGestureSampleDisposition: Equatable, Sendable {
    case analyzed
    /// The buffer is cleared, as when observation stops.
    case ignoredGestureDisabled
    /// Drags, selections and drawing never count. The buffer is kept and the previous state repeated.
    case ignoredWhileButtonHeld
    case ignoredDuringCooldown
    /// The buffer is kept and the previous state repeated.
    case ignoredTooCloseToPreviousSample
}

/// What the ring should show after a pointer sample, and whether the gesture just fired.
struct SummonGestureUpdate: Equatable, Sendable {
    /// Same as `analysis.progress`; clamp to 1 when drawing the ring.
    var progress: Double
    var ringVisible: Bool
    /// 0.35 where the ring appears up to 1 as the gesture fires; 0 while hidden.
    var ringOpacity: Double
    var glyphVisible: Bool
    /// True on exactly the sample that completes the gesture; the recognizer has already cleared and cooled down.
    var recognized: Bool
    var analysis: SummonGestureAnalysis
    var disposition: SummonGestureSampleDisposition

    static let idle = SummonGestureUpdate(progress: 0, ringVisible: false, ringOpacity: 0, glyphVisible: false, recognized: false,
                                          analysis: .empty, disposition: .analyzed)
}
