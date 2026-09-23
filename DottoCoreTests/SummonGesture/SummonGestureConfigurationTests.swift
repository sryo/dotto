import Foundation

let summonGestureConfigurationTestSuite = CoreTestSuite(name: "SummonGestureConfiguration", testCases: [
    CoreTestCase(name: "the defaults are the owner's") {
        let standard = SummonGestureConfiguration.standard
        try expectEqual(standard.isEnabled, true)
        try expectEqual(standard.direction, .clockwise)
        try expectEqual(standard.loopsNeeded, 1.5)
        try expectEqual(standard.windowSeconds, 1.2)
        try expectEqual(standard.minimumRadiusPoints, 28)
        try expectEqual(standard.maximumRadiusPoints, 240)
        try expectEqual(standard.roundnessTolerance, 0.38)
        try expectEqual(standard.ringAppearsAtProgress, 0.60)
        try expectEqual(standard.ringStaysVisibleAboveProgress, 0.45)
        try expectEqual(standard.glyphAppearsAtProgress, 0.85)
        try expectEqual(standard.looseRoundnessFactor, 1.35)
        try expectEqual(standard.maximumPauseBetweenSamplesSeconds, 0.25)
        try expectEqual(standard.minimumSampleSpacingPoints, 1.5)
        try expectEqual(standard.cooldownSeconds, 0.7)
        try expectEqual(standard.maximumReversalFraction, 0.03)
        try expectEqual(SummonGestureConfiguration.minimumSampleCountForAnalysis, 8)
        try expectEqual(CircleSummonGestureRecognizer().configuration, standard)
    },
    CoreTestCase(name: "it round-trips through JSON with the \"enabled\" key and direction raw values") {
        var configuration = SummonGestureConfiguration.standard
        configuration.isEnabled = false
        configuration.direction = .counterClockwise
        configuration.loopsNeeded = 2
        let encodedData = try JSONEncoder().encode(configuration)
        let encodedObject = try unwrapOrFail(try JSONSerialization.jsonObject(with: encodedData) as? [String: Any])
        try expectEqual(encodedObject["enabled"] as? Bool, false)
        try expectEqual(encodedObject["direction"] as? String, "counterClockwise")
        try expectEqual(try JSONDecoder().decode(SummonGestureConfiguration.self, from: encodedData), configuration)
        try expectEqual(SummonGestureDirection.allCases.map(\.rawValue), ["clockwise", "counterClockwise", "either"])
    },
    CoreTestCase(name: "missing keys keep their defaults") {
        let decoded = try JSONDecoder().decode(SummonGestureConfiguration.self, from: Data(#"{"direction":"either"}"#.utf8))
        var expected = SummonGestureConfiguration.standard
        expected.direction = .either
        try expectEqual(decoded, expected)
        try expectEqual(try JSONDecoder().decode(SummonGestureConfiguration.self, from: Data("{}".utf8)), .standard)
    },
    CoreTestCase(name: "user-tunable values are clamped to the settings' ranges on decode") {
        let outOfRangeJSON = #"{"loopsNeeded":0,"windowSeconds":9,"minimumRadiusPoints":1,"maximumRadiusPoints":5000,"roundnessTolerance":2,"maximumReversalFraction":0}"#
        let decoded = try JSONDecoder().decode(SummonGestureConfiguration.self, from: Data(outOfRangeJSON.utf8))
        try expectEqual(decoded.loopsNeeded, 1.0)
        try expectEqual(decoded.windowSeconds, 2.0)
        try expectEqual(decoded.minimumRadiusPoints, 12)
        try expectEqual(decoded.maximumRadiusPoints, 400)
        try expectEqual(decoded.roundnessTolerance, 0.7)
        try expectEqual(decoded.maximumReversalFraction, 0.02)
        let tooLooseReversal = try JSONDecoder().decode(SummonGestureConfiguration.self, from: Data(#"{"maximumReversalFraction":0.9}"#.utf8))
        try expectEqual(tooLooseReversal.maximumReversalFraction, 0.4)
        let savedBeforeTheReversalLimit = try JSONDecoder().decode(SummonGestureConfiguration.self, from: Data(#"{"loopsNeeded":2}"#.utf8))
        try expectEqual(savedBeforeTheReversalLimit.maximumReversalFraction, 0.03, "a missing key keeps the default")
        try expectTrue(SummonGestureConfiguration.loopsNeededRange.contains(SummonGestureConfiguration.standard.loopsNeeded))
        try expectTrue(SummonGestureConfiguration.windowSecondsRange.contains(SummonGestureConfiguration.standard.windowSeconds))
    },
    CoreTestCase(name: "an unknown direction fails to decode rather than guessing") {
        _ = try expectThrowsError {
            _ = try JSONDecoder().decode(SummonGestureConfiguration.self, from: Data(#"{"direction":"sideways"}"#.utf8))
        }
    },
])
