import Foundation

private typealias Paths = SummonGesturePathFixtures

private func configuration(direction: SummonGestureDirection = .clockwise,
                           maximumReversalFraction: Double = SummonGestureConfiguration.standard.maximumReversalFraction)
    -> SummonGestureConfiguration {
    var configuration = SummonGestureConfiguration.standard
    configuration.direction = direction
    configuration.maximumReversalFraction = maximumReversalFraction
    return configuration
}

private func recognitionIndices(feeding samples: [SummonGesturePointerSample],
                                configuration: SummonGestureConfiguration) -> [Int] {
    var recognizer = CircleSummonGestureRecognizer(configuration: configuration)
    let updates = Paths.feedAll(samples, into: &recognizer)
    return updates.indices.filter { updateIndex in updates[updateIndex].recognized }
}

/// Moves each sample of a circle centered at (500, 400) by up to `jitterPoints` across the path and, optionally, along it.
private func handJittered(_ samples: [SummonGesturePointerSample], jitterPoints: Double, alsoAlongThePath: Bool,
                          seed: UInt64) -> [SummonGesturePointerSample] {
    var jitter = Paths.SeededJitter(seed: seed)
    return samples.map { sample in
        let offsetX = sample.x - 500
        let offsetY = sample.y - 400
        let distanceFromCenter = max(hypot(offsetX, offsetY), 1)
        let acrossThePath = jitterPoints * jitter.nextSignedUnit()
        let alongThePath = alsoAlongThePath ? jitterPoints * jitter.nextSignedUnit() : 0
        return SummonGesturePointerSample(
            x: sample.x + (acrossThePath * offsetX - alongThePath * offsetY) / distanceFromCenter,
            y: sample.y + (acrossThePath * offsetY + alongThePath * offsetX) / distanceFromCenter,
            timestamp: sample.timestamp)
    }
}

private let lopsidedFigureEightLobeRadii: [(upper: Double, lower: Double)] = [(60, 40), (70, 40), (80, 20)]

private var positivePaths: [(label: String, samples: [SummonGesturePointerSample])] {
    var jitter = Paths.SeededJitter(seed: 7)
    return [
        ("radius 30", Paths.circle(radius: 30, turns: 2, durationSeconds: 1.0)),
        ("radius 60", Paths.circle(radius: 60, turns: 2, durationSeconds: 1.0)),
        ("radius 200", Paths.circle(radius: 200, turns: 2, durationSeconds: 1.0)),
        ("2 turns in 1.3 s", Paths.circle(radius: 60, turns: 2, durationSeconds: 1.3)),
        ("1.8 turns in 0.9 s", Paths.circle(radius: 60, turns: 1.8, durationSeconds: 0.9)),
        ("1.7 turns in 0.45 s", Paths.circle(radius: 60, turns: 1.7, durationSeconds: 0.45)),
        ("1.7 turns in 0.3 s at 120 Hz", Paths.circle(radius: 60, turns: 1.7, durationSeconds: 0.3, samplesPerSecond: 120)),
        ("2 turns in 1 s at 120 Hz", Paths.circle(radius: 60, turns: 2, durationSeconds: 1.0, samplesPerSecond: 120)),
        ("2 turns at 240 Hz", Paths.circle(radius: 60, turns: 2, durationSeconds: 1.0, samplesPerSecond: 240)),
        ("off-screen start angle", Paths.circle(radius: 60, turns: 2, durationSeconds: 1.0, centerX: -900, centerY: 300, startAngle: 4.5)),
        ("wobbly", Paths.circle(radius: 70, turns: 2, durationSeconds: 1.0) { angle in 70 * (1 + 0.18 * sin(3 * angle)) }),
        ("jittery radius", Paths.circle(radius: 60, turns: 2, durationSeconds: 1.0) { _ in 60 + 8 * jitter.nextSignedUnit() }),
        ("mild ellipse", Paths.ellipse(horizontalRadius: 80, verticalRadius: 55, turns: 2, durationSeconds: 1.0)),
    ]
}

let summonGestureReversalTestSuite = CoreTestSuite(name: "CircleSummonGestureRecognizer reversal limit", testCases: [
    CoreTestCase(name: "lopsided figure-eights no longer fire, and show no ring near completion") {
        for lobeRadii in lopsidedFigureEightLobeRadii {
            for samplesPerSecond in [60.0, 120.0] {
                let figureEight = Paths.figureEightOfTwoCircles(upperRadius: lobeRadii.upper, lowerRadius: lobeRadii.lower,
                                                                samplesPerSecond: samplesPerSecond)
                var recognizer = CircleSummonGestureRecognizer(configuration: configuration(direction: .either))
                let updates = Paths.feedAll(figureEight, into: &recognizer)
                let label = "\(lobeRadii) at \(samplesPerSecond) Hz"
                try expectEqual(Paths.recognitionCount(updates), 0, label)
                // The first big lobe alone is a clean loop, so the ring may show for it; it goes once the small lobe starts.
                try expectTrue(updates.allSatisfy { update in !update.glyphVisible && !(update.ringVisible && update.progress > 0.75) },
                               label)
            }
        }
    },
    CoreTestCase(name: "without the limit those figure-eights fire, with little reversal: why the default is 0.03, not 0.15") {
        for lobeRadii in lopsidedFigureEightLobeRadii {
            let figureEight = Paths.figureEightOfTwoCircles(upperRadius: lobeRadii.upper, lowerRadius: lobeRadii.lower)
            var permissiveRecognizer = CircleSummonGestureRecognizer(configuration: configuration(direction: .either,
                                                                                                   maximumReversalFraction: 0.15))
            let updates = Paths.feedAll(figureEight, into: &permissiveRecognizer)
            let recognizedUpdate = try unwrapOrFail(updates.first(where: \.recognized), "\(lobeRadii)")
            let reversalFraction = recognizedUpdate.analysis.reversalFraction
            try expectTrue(reversalFraction > 0.03 && reversalFraction < 0.15, "\(lobeRadii): \(reversalFraction)")
        }
    },
    CoreTestCase(name: "every positive circle fires at the same sample with or without the limit") {
        for positivePath in positivePaths {
            let withoutLimit = recognitionIndices(feeding: positivePath.samples, configuration: configuration(maximumReversalFraction: 1))
            let withDefaultLimit = recognitionIndices(feeding: positivePath.samples, configuration: .standard)
            try expectEqual(withDefaultLimit.count, 1, positivePath.label)
            try expectEqual(withDefaultLimit, withoutLimit, positivePath.label)
        }
    },
    CoreTestCase(name: "clean circles have no reversal; sloppy ones stay far under the limit when they fire") {
        let cleanAnalysis = CircleSummonGestureRecognizer.analyze(samples: Paths.circle(radius: 60, turns: 1.5, durationSeconds: 0.75),
                                                                  configuration: .standard)
        try expectEqual(cleanAnalysis.reversalFraction, 0)
        for positivePath in positivePaths {
            var recognizer = CircleSummonGestureRecognizer()
            let recognizedUpdate = try unwrapOrFail(Paths.feedAll(positivePath.samples, into: &recognizer).first(where: \.recognized))
            try expectTrue(recognizedUpdate.analysis.reversalFraction <= 0.02,
                           "\(positivePath.label): \(recognizedUpdate.analysis.reversalFraction)")
        }
    },
    CoreTestCase(name: "hand jitter of ±3 pt on a 60 pt circle still fires, across the path or in any direction") {
        for seed in 1...20 as ClosedRange<UInt64> {
            for samplesPerSecond in [60.0, 120.0] {
                let circle = Paths.circle(radius: 60, turns: 2, durationSeconds: 1.0, samplesPerSecond: samplesPerSecond)
                for alsoAlongThePath in [false, true] {
                    let jittered = handJittered(circle, jitterPoints: 3, alsoAlongThePath: alsoAlongThePath, seed: seed)
                    try expectEqual(Paths.recognitionCount(feeding: jittered), 1,
                                    "seed \(seed), \(samplesPerSecond) Hz, along the path \(alsoAlongThePath)")
                }
            }
        }
    },
    CoreTestCase(name: "the reversal share is read on a path thinned to steps of max(3 pt, 0.15 × mean radius)") {
        let samples = [(0.0, 0.0), (1.0, 0.0), (2.9, 0.0), (3.0, 0.0), (4.0, 0.0), (7.0, 0.0), (7.0, 2.0), (7.0, 4.0)]
            .enumerated().map { sampleIndex, point in
                SummonGesturePointerSample(x: point.0, y: point.1, timestamp: Double(sampleIndex) * 0.01)
            }
        let thinned = CircleSummonGestureRecognizer.thinnedSamples(samples, minimumSpacingPoints: 3)
        try expectEqual(thinned.map(\.x), [0, 3, 7, 7])
        try expectEqual(thinned.map(\.y), [0, 0, 0, 4])
        try expectTrue(CircleSummonGestureRecognizer.thinnedSamples([], minimumSpacingPoints: 3).isEmpty)
    },
    CoreTestCase(name: "32 pt loops with 1.5 pt hand tremor at 120 Hz fire at least 9 times in 10") {
        // Without thinning, half of these miss: at 120 Hz a 32 pt loop advances about 2 pt per sample, as little as the tremor.
        var firedCount = 0
        let seeds = 1...40 as ClosedRange<UInt64>
        let tremorPoints = 1.5
        let uniformToStandardDeviation = 3.0.squareRoot()
        for seed in seeds {
            var jitter = Paths.SeededJitter(seed: seed)
            // Tremor drifts rather than jumping sample to sample, so most of it is smoothed (each offset keeps 80% of the
            // last one), with a little independent noise on top and positions rounded to the half point macOS reports.
            var smoothedTremorX = 0.0
            var smoothedTremorY = 0.0
            let handDrawnLoop = Paths.parametricPath(durationSeconds: 2.2 * 0.65, samplesPerSecond: 120) { fraction in
                let angle = fraction * 2.2 * 2 * Double.pi
                return (500 + 32 * cos(angle), 400 + 0.8 * 32 * sin(angle))
            }
            let trembling = handDrawnLoop.map { sample in
                smoothedTremorX = 0.8 * smoothedTremorX + tremorPoints * uniformToStandardDeviation * jitter.nextSignedUnit()
                smoothedTremorY = 0.8 * smoothedTremorY + tremorPoints * uniformToStandardDeviation * jitter.nextSignedUnit()
                let noisyX = sample.x + smoothedTremorX + tremorPoints / 2 * uniformToStandardDeviation * jitter.nextSignedUnit()
                let noisyY = sample.y + smoothedTremorY + tremorPoints / 2 * uniformToStandardDeviation * jitter.nextSignedUnit()
                return SummonGesturePointerSample(x: (noisyX * 2).rounded() / 2, y: (noisyY * 2).rounded() / 2,
                                                  timestamp: sample.timestamp)
            }
            if Paths.recognitionCount(feeding: trembling) == 1 { firedCount += 1 }
        }
        try expectTrue(firedCount >= 36, "\(firedCount) of \(seeds.count) fired")
    },
    CoreTestCase(name: "the limit applies to the ring too: a loop that reverses too much never looks like a circle") {
        let figureEight = Paths.figureEightOfTwoCircles(upperRadius: 70, lowerRadius: 40)
        var recognizer = CircleSummonGestureRecognizer(configuration: configuration(direction: .either))
        for update in Paths.feedAll(figureEight, into: &recognizer) where update.analysis.reversalFraction > 0.03 {
            try expectTrue(!update.analysis.looksLikeACircle && !update.analysis.isValid && !update.ringVisible)
        }
    },
])
