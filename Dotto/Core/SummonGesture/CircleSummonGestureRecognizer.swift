import CoreGraphics
import Foundation

/// Recognizes the pointer circling over a short rolling buffer of samples. The winding of the path around its own
/// centroid decides the gesture, so the loop can be drawn anywhere and at any size within the limits. Roundness rules
/// out scribbles, straight moves and balanced figure-eights; the reversal limit rules out lopsided figure-eights.
struct CircleSummonGestureRecognizer: Sendable {
    var configuration: SummonGestureConfiguration {
        didSet { reset() }
    }
    private(set) var bufferedSamples: [SummonGesturePointerSample] = []
    private(set) var cooldownEndsAtTimestamp: TimeInterval?
    private var latestUpdate = SummonGestureUpdate.idle

    init(configuration: SummonGestureConfiguration = .standard) {
        self.configuration = configuration
    }

    mutating func feed(pointerSample: SummonGesturePointerSample, anyButtonHeld: Bool) -> SummonGestureUpdate {
        guard configuration.isEnabled else {
            reset()
            return updateRepeatingLatest(disposition: .ignoredGestureDisabled)
        }
        if anyButtonHeld {
            return updateRepeatingLatest(disposition: .ignoredWhileButtonHeld)
        }
        if let cooldownEndsAtTimestamp, pointerSample.timestamp < cooldownEndsAtTimestamp {
            return updateRepeatingLatest(disposition: .ignoredDuringCooldown)
        }

        if let previousSample = bufferedSamples.last {
            if pointerSample.timestamp - previousSample.timestamp > configuration.maximumPauseBetweenSamplesSeconds {
                bufferedSamples.removeAll()
            } else if Self.distance(from: previousSample, to: pointerSample) < configuration.minimumSampleSpacingPoints {
                return updateRepeatingLatest(disposition: .ignoredTooCloseToPreviousSample)
            }
        }
        bufferedSamples.append(pointerSample)
        while let oldestSample = bufferedSamples.first,
              pointerSample.timestamp - oldestSample.timestamp > configuration.effectiveWindowSeconds {
            bufferedSamples.removeFirst()
        }

        let analysis = Self.analyze(samples: bufferedSamples, configuration: configuration)
        let ringVisible = latestUpdate.ringVisible
            ? analysis.looksLikeACircle && analysis.progress >= configuration.ringStaysVisibleAboveProgress
            : analysis.isValid && analysis.progress >= configuration.ringAppearsAtProgress
        let recognized = analysis.isValid && analysis.progress >= 1
        let update = SummonGestureUpdate(progress: analysis.progress,
                                         ringVisible: ringVisible,
                                         ringOpacity: ringVisible ? Self.ringOpacity(atProgress: analysis.progress, configuration: configuration) : 0,
                                         glyphVisible: ringVisible && analysis.progress > configuration.glyphAppearsAtProgress,
                                         recognized: recognized,
                                         analysis: analysis,
                                         disposition: .analyzed)
        if recognized {
            bufferedSamples.removeAll()
            cooldownEndsAtTimestamp = pointerSample.timestamp + configuration.cooldownSeconds
            latestUpdate = .idle
        } else {
            latestUpdate = update
        }
        return update
    }

    /// Faint where the ring appears, full as the gesture fires, so a near-circle drawn by accident barely registers.
    static let ringOpacityWhenAppearing = 0.35
    static func ringOpacity(atProgress progress: Double, configuration: SummonGestureConfiguration) -> Double {
        let remainingProgressWhenAppearing = max(0.01, 1 - configuration.ringAppearsAtProgress)
        let shareOfRemainingDrawn = min(1, max(0, (progress - configuration.ringAppearsAtProgress) / remainingProgressWhenAppearing))
        return ringOpacityWhenAppearing + (1 - ringOpacityWhenAppearing) * shareOfRemainingDrawn
    }

    /// Clears the buffer when observation stops. The cooldown survives, so a reset can't re-fire right away.
    mutating func reset() {
        bufferedSamples.removeAll()
        latestUpdate = .idle
    }

    static func analyze(samples: [SummonGesturePointerSample], configuration: SummonGestureConfiguration) -> SummonGestureAnalysis {
        guard samples.count >= SummonGestureConfiguration.minimumSampleCountForAnalysis else { return .empty }
        let sampleCount = Double(samples.count)
        let centroidX = samples.reduce(0) { runningSum, sample in runningSum + sample.x } / sampleCount
        let centroidY = samples.reduce(0) { runningSum, sample in runningSum + sample.y } / sampleCount

        var winding = 0.0
        var previousAngle = atan2(samples[0].y - centroidY, samples[0].x - centroidX)
        var radii: [Double] = []
        for sample in samples {
            let angle = atan2(sample.y - centroidY, sample.x - centroidX)
            winding += unwrappedAngleDelta(from: previousAngle, to: angle)
            previousAngle = angle
            radii.append(hypot(sample.x - centroidX, sample.y - centroidY))
        }
        let meanRadius = radii.reduce(0, +) / sampleCount
        let radiusVariance = radii.reduce(0) { runningSum, radius in runningSum + (radius - meanRadius) * (radius - meanRadius) } / sampleCount
        let roundness = meanRadius > 0 ? radiusVariance.squareRoot() / meanRadius : 1

        let reversalFraction = reversalFractionAlongPath(
            ofPathThrough: thinnedSamples(samples, minimumSpacingPoints: max(
                SummonGestureConfiguration.reversalPathMinimumSpacingPoints,
                SummonGestureConfiguration.reversalPathSpacingFractionOfMeanRadius * meanRadius)),
            aroundCentroidX: centroidX, centroidY: centroidY, netWinding: winding)
        let travelsOneWay = reversalFraction <= configuration.maximumReversalFraction

        let directionMatches: Bool
        switch configuration.direction {
        case .either: directionMatches = true
        case .clockwise: directionMatches = winding > 0
        case .counterClockwise: directionMatches = winding < 0
        }
        let loops = abs(winding) / (2 * Double.pi)
        let sizeFits = meanRadius >= configuration.minimumRadiusPoints && meanRadius <= configuration.maximumRadiusPoints
        return SummonGestureAnalysis(
            loops: loops,
            meanRadius: meanRadius,
            roundness: roundness,
            winding: winding,
            reversalFraction: reversalFraction,
            centroid: CGPoint(x: centroidX, y: centroidY),
            directionMatches: directionMatches,
            sizeFits: sizeFits,
            progress: directionMatches ? loops / configuration.loopsNeeded : 0,
            isValid: directionMatches && sizeFits && travelsOneWay && roundness <= configuration.roundnessTolerance,
            looksLikeACircle: directionMatches && sizeFits && travelsOneWay
                && roundness <= configuration.roundnessTolerance * configuration.looseRoundnessFactor
        )
    }

    /// Share of the angular travel around the centroid that runs against the net winding. Hand tremor on a small,
    /// finely sampled loop makes many tiny backward steps that are noise, not a second lobe, so the caller passes a
    /// thinned path; the small lobe of a lopsided figure-eight is tens of points long and survives the thinning.
    private static func reversalFractionAlongPath(ofPathThrough pathSamples: [SummonGesturePointerSample],
                                         aroundCentroidX centroidX: Double, centroidY: Double, netWinding: Double) -> Double {
        guard let firstSample = pathSamples.first else { return 0 }
        var previousAngle = atan2(firstSample.y - centroidY, firstSample.x - centroidX)
        var totalAngularTravel = 0.0
        var angularTravelAgainstWinding = 0.0
        for sample in pathSamples.dropFirst() {
            let angle = atan2(sample.y - centroidY, sample.x - centroidX)
            let angleDelta = unwrappedAngleDelta(from: previousAngle, to: angle)
            totalAngularTravel += abs(angleDelta)
            if angleDelta * netWinding < 0 { angularTravelAgainstWinding += abs(angleDelta) }
            previousAngle = angle
        }
        return totalAngularTravel > 0 ? angularTravelAgainstWinding / totalAngularTravel : 0
    }

    /// Keeps the first sample, then each sample at least `minimumSpacingPoints` from the last one kept.
    static func thinnedSamples(_ samples: [SummonGesturePointerSample], minimumSpacingPoints: Double) -> [SummonGesturePointerSample] {
        guard var lastKeptSample = samples.first else { return [] }
        var keptSamples = [lastKeptSample]
        for sample in samples.dropFirst() where distance(from: lastKeptSample, to: sample) >= minimumSpacingPoints {
            keptSamples.append(sample)
            lastKeptSample = sample
        }
        return keptSamples
    }

    /// The change from one angle to the next, unwrapped into (-π, π], so summing the steps counts whole turns.
    private static func unwrappedAngleDelta(from previousAngle: Double, to angle: Double) -> Double {
        var angleDelta = angle - previousAngle
        while angleDelta > Double.pi { angleDelta -= 2 * Double.pi }
        while angleDelta < -Double.pi { angleDelta += 2 * Double.pi }
        return angleDelta
    }

    private func updateRepeatingLatest(disposition: SummonGestureSampleDisposition) -> SummonGestureUpdate {
        var repeatedUpdate = latestUpdate
        repeatedUpdate.recognized = false
        repeatedUpdate.disposition = disposition
        return repeatedUpdate
    }

    private static func distance(from firstSample: SummonGesturePointerSample, to secondSample: SummonGesturePointerSample) -> Double {
        hypot(secondSample.x - firstSample.x, secondSample.y - firstSample.y)
    }
}
