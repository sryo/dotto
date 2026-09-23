import Foundation

private typealias Paths = SummonGesturePathFixtures

private func configuration(direction: SummonGestureDirection) -> SummonGestureConfiguration {
    var configuration = SummonGestureConfiguration.standard
    configuration.direction = direction
    return configuration
}

let circleSummonGestureRecognizerShapeTestSuite = CoreTestSuite(name: "CircleSummonGestureRecognizer shapes", testCases: [
    CoreTestCase(name: "clean clockwise circles fire exactly once at radii 30, 60 and 200") {
        for radius in [30.0, 60.0, 200.0] {
            let circle = Paths.circle(radius: radius, turns: 2, durationSeconds: 1.0)
            try expectEqual(Paths.recognitionCount(feeding: circle), 1, "radius \(radius)")
        }
    },
    CoreTestCase(name: "clean clockwise circles fire at slow-ish, normal and fast speeds and at 120 Hz") {
        let drawings: [(turns: Double, durationSeconds: Double, samplesPerSecond: Double)] = [
            (2, 1.3, 60), (1.8, 0.9, 60), (1.7, 0.45, 60), (1.7, 0.3, 120), (2, 1.0, 120),
        ]
        for drawing in drawings {
            let circle = Paths.circle(radius: 60, turns: drawing.turns, durationSeconds: drawing.durationSeconds,
                                      samplesPerSecond: drawing.samplesPerSecond)
            try expectEqual(Paths.recognitionCount(feeding: circle), 1, "\(drawing)")
        }
    },
    CoreTestCase(name: "the loop fires wherever on screen and from whatever start angle it is drawn") {
        for (centerX, centerY, startAngle) in [(80.0, 90.0, 0.0), (2400.0, 1300.0, 2.0), (-900.0, 300.0, 4.5)] {
            let circle = Paths.circle(radius: 60, turns: 2, durationSeconds: 1.0, centerX: centerX, centerY: centerY,
                                      startAngle: startAngle)
            try expectEqual(Paths.recognitionCount(feeding: circle), 1, "center \(centerX),\(centerY) start \(startAngle)")
        }
    },
    CoreTestCase(name: "with y growing downward, an increasing angle winds positive: clockwise on screen") {
        let clockwiseSamples = Paths.circle(radius: 60, turns: 1, durationSeconds: 0.5)
        let counterClockwiseSamples = Paths.circle(radius: 60, turns: 1, durationSeconds: 0.5, clockwise: false)
        let clockwiseAnalysis = CircleSummonGestureRecognizer.analyze(samples: clockwiseSamples, configuration: .standard)
        let counterClockwiseAnalysis = CircleSummonGestureRecognizer.analyze(samples: counterClockwiseSamples,
                                                                            configuration: configuration(direction: .either))
        try expectTrue(clockwiseAnalysis.winding > 0, "\(clockwiseAnalysis)")
        try expectTrue(counterClockwiseAnalysis.winding < 0, "\(counterClockwiseAnalysis)")
        try expectTrue(abs(clockwiseAnalysis.loops - 1) < 0.02, "\(clockwiseAnalysis)")
        try expectTrue(abs(clockwiseAnalysis.meanRadius - 60) < 1, "\(clockwiseAnalysis)")
        try expectTrue(clockwiseAnalysis.roundness < 0.05, "\(clockwiseAnalysis)")
        let centroid = try unwrapOrFail(clockwiseAnalysis.centroid)
        try expectTrue(abs(centroid.x - 500) < 3 && abs(centroid.y - 400) < 3, "\(centroid)")
    },
    CoreTestCase(name: "clockwise (the default) ignores counter-clockwise circles: progress stays 0 and no ring shows") {
        var recognizer = CircleSummonGestureRecognizer()
        let updates = Paths.feedAll(Paths.circle(radius: 60, turns: 2.5, durationSeconds: 1.0, clockwise: false), into: &recognizer)
        try expectEqual(Paths.recognitionCount(updates), 0)
        try expectTrue(updates.allSatisfy { update in update.progress == 0 && !update.ringVisible && !update.glyphVisible })
        try expectTrue(updates.last?.analysis.loops ?? 0 > 1.5, "the loop itself was drawn")
    },
    CoreTestCase(name: "counter-clockwise setting fires only on counter-clockwise circles") {
        let counterClockwiseOnly = configuration(direction: .counterClockwise)
        try expectEqual(Paths.recognitionCount(feeding: Paths.circle(radius: 60, turns: 2, durationSeconds: 1.0, clockwise: false),
                                               configuration: counterClockwiseOnly), 1)
        try expectEqual(Paths.recognitionCount(feeding: Paths.circle(radius: 60, turns: 2, durationSeconds: 1.0),
                                               configuration: counterClockwiseOnly), 0)
    },
    CoreTestCase(name: "either direction fires on both") {
        let eitherDirection = configuration(direction: .either)
        for clockwise in [true, false] {
            let circle = Paths.circle(radius: 60, turns: 2, durationSeconds: 1.0, clockwise: clockwise)
            try expectEqual(Paths.recognitionCount(feeding: circle, configuration: eitherDirection), 1, "clockwise \(clockwise)")
        }
    },
    CoreTestCase(name: "it fires on the first sample whose measured loops reach 1.5, never at 1.49") {
        var recognizer = CircleSummonGestureRecognizer()
        let updates = Paths.feedAll(Paths.circle(radius: 60, turns: 2, durationSeconds: 1.0, samplesPerSecond: 240), into: &recognizer)
        let recognitionIndex = try unwrapOrFail(Paths.firstRecognitionIndex(updates))
        try expectTrue(updates[recognitionIndex].analysis.loops >= 1.5, "\(updates[recognitionIndex].analysis)")
        try expectTrue(updates[recognitionIndex].progress >= 1)
        let previousUpdate = updates[recognitionIndex - 1]
        try expectTrue(previousUpdate.analysis.loops < 1.5 && previousUpdate.analysis.loops > 1.45, "\(previousUpdate.analysis)")
        try expectTrue(updates[..<recognitionIndex].allSatisfy { update in !update.recognized && update.progress < 1 })
    },
    CoreTestCase(name: "the same path fires at exactly the needed loops and not at 1.49/1.5 of them") {
        let path = Paths.circle(radius: 60, turns: 1.3, durationSeconds: 0.7)
        let measuredLoops = CircleSummonGestureRecognizer.analyze(samples: path, configuration: .standard).loops
        var exactConfiguration = SummonGestureConfiguration.standard
        exactConfiguration.loopsNeeded = measuredLoops
        var shortConfiguration = SummonGestureConfiguration.standard
        shortConfiguration.loopsNeeded = measuredLoops * 1.5 / 1.49
        var exactRecognizer = CircleSummonGestureRecognizer(configuration: exactConfiguration)
        let exactUpdates = Paths.feedAll(path, into: &exactRecognizer)
        try expectEqual(Paths.firstRecognitionIndex(exactUpdates), path.count - 1)
        var shortRecognizer = CircleSummonGestureRecognizer(configuration: shortConfiguration)
        let shortUpdates = Paths.feedAll(path, into: &shortRecognizer)
        try expectEqual(Paths.recognitionCount(shortUpdates), 0)
        try expectTrue(abs((shortUpdates.last?.progress ?? 0) - 1.49 / 1.5) < 1e-9)
    },
    CoreTestCase(name: "loops needed is the sensitivity: 1.25 turns fire at 1.0 but not at 1.5") {
        let path = Paths.circle(radius: 60, turns: 1.25, durationSeconds: 0.7)
        var lenientConfiguration = SummonGestureConfiguration.standard
        lenientConfiguration.loopsNeeded = 1.0
        try expectEqual(Paths.recognitionCount(feeding: path, configuration: lenientConfiguration), 1)
        try expectEqual(Paths.recognitionCount(feeding: path), 0)
    },
    CoreTestCase(name: "sloppy but acceptable circles still fire: wobbly radius, jitter, a mild ellipse") {
        var jitter = Paths.SeededJitter(seed: 7)
        let wobbly = Paths.circle(radius: 70, turns: 2, durationSeconds: 1.0) { angle in 70 * (1 + 0.18 * sin(3 * angle)) }
        let jittery = Paths.circle(radius: 60, turns: 2, durationSeconds: 1.0) { _ in 60 + 8 * jitter.nextSignedUnit() }
        let mildEllipse = Paths.ellipse(horizontalRadius: 80, verticalRadius: 55, turns: 2, durationSeconds: 1.0)
        for (label, path) in [("wobbly", wobbly), ("jittery", jittery), ("mild ellipse", mildEllipse)] {
            try expectEqual(Paths.recognitionCount(feeding: path), 1, label)
        }
    },
    CoreTestCase(name: "too small and too large circles never fire, even when round") {
        for radius in [12.0, 20.0, 300.0, 500.0] {
            var recognizer = CircleSummonGestureRecognizer()
            let updates = Paths.feedAll(Paths.circle(radius: radius, turns: 2, durationSeconds: 1.0), into: &recognizer)
            try expectEqual(Paths.recognitionCount(updates), 0, "radius \(radius)")
            try expectTrue(updates.last?.analysis.sizeFits == false, "radius \(radius)")
            // A partial arc of a big circle sits closer to its own centroid, so only small circles never show the ring.
            if radius < 28 { try expectTrue(updates.allSatisfy { update in !update.ringVisible }, "radius \(radius)") }
        }
    },
    CoreTestCase(name: "a flat ellipse is too far from round to fire, so the ring never appears for it") {
        var recognizer = CircleSummonGestureRecognizer()
        let updates = Paths.feedAll(Paths.ellipse(horizontalRadius: 160, verticalRadius: 30, turns: 2, durationSeconds: 1.0),
                                    into: &recognizer)
        try expectEqual(Paths.recognitionCount(updates), 0)
        let finalRoundness = updates.last?.analysis.roundness ?? 0
        try expectTrue(finalRoundness > 0.38 && finalRoundness <= 0.38 * 1.35, "roundness \(finalRoundness)")
        try expectTrue(updates.allSatisfy { !$0.ringVisible }, "the ring appears only for a path that would fire")
    },
    CoreTestCase(name: "a lumpy loop beyond the looser tolerance shows no ring and never fires") {
        var recognizer = CircleSummonGestureRecognizer()
        let lumpyLoop = Paths.circle(radius: 80, turns: 2, durationSeconds: 1.0) { angle in 80 * (1 + 0.85 * sin(2 * angle)) }
        let updates = Paths.feedAll(lumpyLoop, into: &recognizer)
        try expectEqual(Paths.recognitionCount(updates), 0)
        try expectTrue((updates.last?.analysis.roundness ?? 0) > 0.38 * 1.35, "\(String(describing: updates.last?.analysis))")
        try expectTrue(updates.suffix(20).allSatisfy { update in !update.ringVisible })
    },
    CoreTestCase(name: "straight lines, one way or back and forth, never fire") {
        let diagonal = Paths.parametricPath(durationSeconds: 0.6) { fraction in (100 + 600 * fraction, 200 + 250 * fraction) }
        let backAndForth = Paths.parametricPath(durationSeconds: 1.2) { fraction in
            (400 + 150 * sin(fraction * 6 * Double.pi), 300 + 2 * fraction)
        }
        try expectEqual(Paths.recognitionCount(feeding: diagonal), 0)
        try expectEqual(Paths.recognitionCount(feeding: backAndForth), 0)
        try expectEqual(Paths.recognitionCount(feeding: backAndForth, configuration: configuration(direction: .either)), 0)
    },
    CoreTestCase(name: "zig-zags never fire") {
        let zigZag = Paths.parametricPath(durationSeconds: 1.2) { fraction in
            let zigPhase = (fraction * 10).truncatingRemainder(dividingBy: 1)
            return (200 + 500 * fraction, 300 + (zigPhase < 0.5 ? zigPhase : 1 - zigPhase) * 160)
        }
        try expectEqual(Paths.recognitionCount(feeding: zigZag, configuration: configuration(direction: .either)), 0)
    },
    CoreTestCase(name: "random scribbles never fire") {
        for seed in [1, 2, 3, 4, 5] as [UInt64] {
            var jitter = Paths.SeededJitter(seed: seed)
            var pointerX = 500.0
            var pointerY = 400.0
            let scribble = Paths.parametricPath(durationSeconds: 2.0) { _ in
                pointerX += 25 * jitter.nextSignedUnit()
                pointerY += 25 * jitter.nextSignedUnit()
                return (pointerX, pointerY)
            }
            try expectEqual(Paths.recognitionCount(feeding: scribble, configuration: configuration(direction: .either)), 0,
                            "seed \(seed)")
        }
    },
    CoreTestCase(name: "balanced figure-eights never fire: the path through the centroid is far from round") {
        // The centroid sits at the crossing, so the radii swing from 0 to the full lobe and roundness rules them out.
        let symmetricFigureEight = Paths.parametricPath(durationSeconds: 1.2) { fraction in
            let parameter = fraction * 2 * 2 * Double.pi
            return (500 + 90 * sin(parameter), 400 + 90 * sin(parameter) * cos(parameter))
        }
        let twoCircleFigureEight = Paths.figureEightOfTwoCircles(upperRadius: 50, lowerRadius: 50)
        let slightlyUnevenFigureEight = Paths.figureEightOfTwoCircles(upperRadius: 55, lowerRadius: 45)
        for (label, path) in [("symmetric", symmetricFigureEight), ("two circles", twoCircleFigureEight),
                              ("slightly uneven", slightlyUnevenFigureEight)] {
            var recognizer = CircleSummonGestureRecognizer(configuration: configuration(direction: .either))
            let updates = Paths.feedAll(path, into: &recognizer)
            try expectEqual(Paths.recognitionCount(updates), 0, label)
            try expectTrue((updates.last?.analysis.roundness ?? 0) > 0.38, "\(label): \(String(describing: updates.last?.analysis))")
        }
    },
    CoreTestCase(name: "slow drift with a small wobble never fires") {
        let drift = Paths.parametricPath(durationSeconds: 3.0) { fraction in
            (300 + 200 * fraction, 300 + 60 * fraction + 3 * sin(fraction * 40))
        }
        try expectEqual(Paths.recognitionCount(feeding: drift, configuration: configuration(direction: .either)), 0)
    },
    CoreTestCase(name: "fast flicks never fire") {
        var samples: [SummonGesturePointerSample] = []
        var timestamp = 100.0
        for flickIndex in 0..<6 {
            let flickDirection = flickIndex.isMultiple(of: 2) ? 1.0 : -1.0
            for stepIndex in 0...5 {
                samples.append(SummonGesturePointerSample(x: 500 + flickDirection * Double(stepIndex) * 60,
                                                          y: 400 + Double(stepIndex) * 12, timestamp: timestamp))
                timestamp += 1.0 / 120
            }
            timestamp += 0.08
        }
        try expectEqual(Paths.recognitionCount(feeding: samples, configuration: configuration(direction: .either)), 0)
    },
    CoreTestCase(name: "circling too slowly never fits enough loops in the window") {
        var recognizer = CircleSummonGestureRecognizer()
        let updates = Paths.feedAll(Paths.circle(radius: 60, turns: 3, durationSeconds: 3.0), into: &recognizer)
        try expectEqual(Paths.recognitionCount(updates), 0)
        try expectTrue(updates.allSatisfy { update in update.analysis.loops < 1.5 })
    },
    CoreTestCase(name: "fewer than 8 samples give the empty analysis") {
        let sevenSamples = Array(Paths.circle(radius: 60, turns: 1, durationSeconds: 0.5).prefix(7))
        try expectEqual(CircleSummonGestureRecognizer.analyze(samples: sevenSamples, configuration: .standard), .empty)
        try expectEqual(SummonGestureAnalysis.empty.roundness, 1)
        try expectEqual(SummonGestureAnalysis.empty.centroid, nil)
    },
])
