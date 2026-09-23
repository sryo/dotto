import Foundation

/// Which way the pointer has to circle. Screen y grows downward, so clockwise on screen is a positive winding.
enum SummonGestureDirection: String, Codable, CaseIterable, Equatable, Sendable {
    case clockwise, counterClockwise, either
}

/// The circle summon gesture's settings, with the owner-approved defaults from the cursor lab.
struct SummonGestureConfiguration: Codable, Equatable, Sendable {
    var isEnabled = true
    var direction = SummonGestureDirection.clockwise
    var loopsNeeded = 1.5
    /// Samples older than this drop off the rolling buffer, so the loops have to be drawn within it.
    var windowSeconds = 1.2
    var minimumRadiusPoints = 28.0
    var maximumRadiusPoints = 240.0
    /// The largest accepted standard deviation of the radii divided by their mean.
    var roundnessTolerance = 0.38
    /// The ring appears only near the end of the gesture, and only for a path that would fire (strict roundness):
    /// curved pointer moves draw half a loop all the time, and a ring for each of them was noise.
    var ringAppearsAtProgress = 0.60
    /// Once shown, the ring stays down to this progress, on the loose roundness, so it doesn't flicker while the loop
    /// settles.
    var ringStaysVisibleAboveProgress = 0.45
    var glyphAppearsAtProgress = 0.85
    /// How much rounder than required a path may be for a ring that is already showing.
    var looseRoundnessFactor = 1.35
    var maximumPauseBetweenSamplesSeconds = 0.25
    var minimumSampleSpacingPoints = 1.5
    var cooldownSeconds = 0.7
    /// The largest share of the path's angular travel that may run against its net direction. A lopsided figure-eight
    /// winds around its big lobe like a loop and passes the roundness check, but its small lobe travels backwards.
    /// Measured on synthetic paths: clean, sloppy and hand-jittered circles stay at or below about 0.017 when they fire;
    /// lopsided eights fire at 0.06 to 0.10. So 0.15 would let every one through.
    var maximumReversalFraction = 0.03

    static let standard = SummonGestureConfiguration()
    /// A relaxed hand takes about this long per loop, so the window grows to fit the loops the user asked for:
    /// at 2.5 loops a fixed 1.2 s window would only accept loops drawn faster than about 0.5 s each.
    static let windowSecondsPerLoopNeeded = 0.85
    /// The reversal share is measured on a path thinned to steps of at least this many points, or this fraction of
    /// the mean radius when that is larger, so hand tremor on a small loop doesn't read as travelling backwards.
    /// Measured on simulated hands (32 pt loops, 1.5 pt tremor, 120 Hz): a tenth of the radius still lets 25% of them
    /// miss; 0.15 lets 94-95% fire, while lopsided figure-eights and random wandering fire no more than before.
    static let reversalPathMinimumSpacingPoints = 3.0
    static let reversalPathSpacingFractionOfMeanRadius = 0.15
    /// Fewer samples than this can't tell a loop from a flick.
    static let minimumSampleCountForAnalysis = 8

    static let loopsNeededRange = 1.0...2.5
    static let windowSecondsRange = 0.6...2.0
    static let minimumRadiusPointsRange = 12.0...90.0
    static let maximumRadiusPointsRange = 100.0...400.0
    static let roundnessToleranceRange = 0.15...0.7
    static let maximumReversalFractionRange = 0.02...0.4

    /// How long samples stay in the rolling buffer: `windowSeconds`, or longer when the loops needed take longer.
    var effectiveWindowSeconds: Double {
        max(windowSeconds, loopsNeeded * Self.windowSecondsPerLoopNeeded)
    }

    enum CodingKeys: String, CodingKey {
        case isEnabled = "enabled", direction, loopsNeeded, windowSeconds, minimumRadiusPoints, maximumRadiusPoints
        case roundnessTolerance, ringAppearsAtProgress, ringStaysVisibleAboveProgress, glyphAppearsAtProgress, looseRoundnessFactor
        case maximumPauseBetweenSamplesSeconds, minimumSampleSpacingPoints, cooldownSeconds, maximumReversalFraction
    }

    init() {}

    /// Missing keys keep their defaults, and the user-tunable values are clamped to the ranges the settings offer.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SummonGestureConfiguration()
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? defaults.isEnabled
        direction = try container.decodeIfPresent(SummonGestureDirection.self, forKey: .direction) ?? defaults.direction
        loopsNeeded = Self.clamped(try container.decodeIfPresent(Double.self, forKey: .loopsNeeded),
                                   to: Self.loopsNeededRange, fallback: defaults.loopsNeeded)
        windowSeconds = Self.clamped(try container.decodeIfPresent(Double.self, forKey: .windowSeconds),
                                     to: Self.windowSecondsRange, fallback: defaults.windowSeconds)
        minimumRadiusPoints = Self.clamped(try container.decodeIfPresent(Double.self, forKey: .minimumRadiusPoints),
                                           to: Self.minimumRadiusPointsRange, fallback: defaults.minimumRadiusPoints)
        maximumRadiusPoints = Self.clamped(try container.decodeIfPresent(Double.self, forKey: .maximumRadiusPoints),
                                           to: Self.maximumRadiusPointsRange, fallback: defaults.maximumRadiusPoints)
        roundnessTolerance = Self.clamped(try container.decodeIfPresent(Double.self, forKey: .roundnessTolerance),
                                          to: Self.roundnessToleranceRange, fallback: defaults.roundnessTolerance)
        ringAppearsAtProgress = try container.decodeIfPresent(Double.self, forKey: .ringAppearsAtProgress)
            ?? defaults.ringAppearsAtProgress
        ringStaysVisibleAboveProgress = try container.decodeIfPresent(Double.self, forKey: .ringStaysVisibleAboveProgress)
            ?? defaults.ringStaysVisibleAboveProgress
        glyphAppearsAtProgress = try container.decodeIfPresent(Double.self, forKey: .glyphAppearsAtProgress)
            ?? defaults.glyphAppearsAtProgress
        looseRoundnessFactor = try container.decodeIfPresent(Double.self, forKey: .looseRoundnessFactor)
            ?? defaults.looseRoundnessFactor
        maximumPauseBetweenSamplesSeconds = try container.decodeIfPresent(Double.self, forKey: .maximumPauseBetweenSamplesSeconds)
            ?? defaults.maximumPauseBetweenSamplesSeconds
        minimumSampleSpacingPoints = try container.decodeIfPresent(Double.self, forKey: .minimumSampleSpacingPoints)
            ?? defaults.minimumSampleSpacingPoints
        cooldownSeconds = try container.decodeIfPresent(Double.self, forKey: .cooldownSeconds) ?? defaults.cooldownSeconds
        maximumReversalFraction = Self.clamped(try container.decodeIfPresent(Double.self, forKey: .maximumReversalFraction),
                                               to: Self.maximumReversalFractionRange, fallback: defaults.maximumReversalFraction)
    }

    private static func clamped(_ decodedValue: Double?, to allowedRange: ClosedRange<Double>, fallback: Double) -> Double {
        guard let decodedValue, decodedValue.isFinite else { return fallback }
        return min(max(decodedValue, allowedRange.lowerBound), allowedRange.upperBound)
    }
}
