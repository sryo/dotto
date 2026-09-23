import Foundation

/// Synthetic pointer paths in top-left screen coordinates (y grows downward), sampled at a steady rate.
enum SummonGesturePathFixtures {
    /// Samples `pointAtFraction` at `samplesPerSecond` from fraction 0 to 1 over `durationSeconds`, both ends included.
    static func parametricPath(durationSeconds: Double, samplesPerSecond: Double = 60, startTimestamp: TimeInterval = 100,
                               pointAtFraction: (Double) -> (x: Double, y: Double)) -> [SummonGesturePointerSample] {
        let intervalCount = max(1, Int((durationSeconds * samplesPerSecond).rounded()))
        return (0...intervalCount).map { intervalIndex in
            let fraction = Double(intervalIndex) / Double(intervalCount)
            let point = pointAtFraction(fraction)
            return SummonGesturePointerSample(x: point.x, y: point.y, timestamp: startTimestamp + fraction * durationSeconds)
        }
    }

    /// A circle drawn at constant angular speed. With y growing downward, an increasing angle is clockwise on screen.
    static func circle(radius: Double, turns: Double, durationSeconds: Double, clockwise: Bool = true,
                       centerX: Double = 500, centerY: Double = 400, startAngle: Double = 0,
                       samplesPerSecond: Double = 60, startTimestamp: TimeInterval = 100,
                       radiusAtAngle: ((Double) -> Double)? = nil) -> [SummonGesturePointerSample] {
        let directionSign = clockwise ? 1.0 : -1.0
        return parametricPath(durationSeconds: durationSeconds, samplesPerSecond: samplesPerSecond,
                              startTimestamp: startTimestamp) { fraction in
            let angle = startAngle + directionSign * fraction * turns * 2 * Double.pi
            let radiusHere = radiusAtAngle?(angle) ?? radius
            return (centerX + radiusHere * cos(angle), centerY + radiusHere * sin(angle))
        }
    }

    /// An ellipse whose semi-axes differ; roundness grows with the ratio between them.
    static func ellipse(horizontalRadius: Double, verticalRadius: Double, turns: Double, durationSeconds: Double,
                        startTimestamp: TimeInterval = 100) -> [SummonGesturePointerSample] {
        parametricPath(durationSeconds: durationSeconds, startTimestamp: startTimestamp) { fraction in
            let angle = fraction * turns * 2 * Double.pi
            return (500 + horizontalRadius * cos(angle), 400 + verticalRadius * sin(angle))
        }
    }

    /// Deterministic pseudo-random numbers in [-1, 1] (a linear congruential generator), so jittered paths repeat.
    struct SeededJitter {
        private var generatorState: UInt64

        init(seed: UInt64) { generatorState = seed }

        mutating func nextSignedUnit() -> Double {
            generatorState = generatorState &* 6364136223846793005 &+ 1442695040888963407
            return Double(generatorState >> 11) / Double(1 << 53) * 2 - 1
        }
    }

    /// Two tangent circles meeting at (500, 400): the upper one drawn clockwise, the lower one counter-clockwise, twice.
    static func figureEightOfTwoCircles(upperRadius: Double, lowerRadius: Double, durationSeconds: Double = 1.2,
                                        samplesPerSecond: Double = 60) -> [SummonGesturePointerSample] {
        parametricPath(durationSeconds: durationSeconds, samplesPerSecond: samplesPerSecond) { fraction in
            let lobeFraction = (fraction * 4).truncatingRemainder(dividingBy: 1)
            let drawingUpperLobe = Int(fraction * 4) % 2 == 0
            let angle = lobeFraction * 2 * Double.pi
            if drawingUpperLobe {
                return (500 - upperRadius * sin(angle), 400 - upperRadius + upperRadius * cos(angle))
            }
            return (500 - lowerRadius * sin(angle), 400 + lowerRadius - lowerRadius * cos(angle))
        }
    }

    static func shifted(_ samples: [SummonGesturePointerSample], bySeconds secondsOffset: Double) -> [SummonGesturePointerSample] {
        samples.map { sample in SummonGesturePointerSample(x: sample.x, y: sample.y, timestamp: sample.timestamp + secondsOffset) }
    }

    static func feedAll(_ samples: [SummonGesturePointerSample], into recognizer: inout CircleSummonGestureRecognizer,
                        anyButtonHeld: Bool = false) -> [SummonGestureUpdate] {
        samples.map { sample in recognizer.feed(pointerSample: sample, anyButtonHeld: anyButtonHeld) }
    }

    static func recognitionCount(_ updates: [SummonGestureUpdate]) -> Int {
        updates.filter(\.recognized).count
    }

    static func firstRecognitionIndex(_ updates: [SummonGestureUpdate]) -> Int? {
        updates.firstIndex(where: \.recognized)
    }

    static func recognitionCount(feeding samples: [SummonGesturePointerSample],
                                 configuration: SummonGestureConfiguration = .standard) -> Int {
        var recognizer = CircleSummonGestureRecognizer(configuration: configuration)
        return recognitionCount(feedAll(samples, into: &recognizer))
    }
}
