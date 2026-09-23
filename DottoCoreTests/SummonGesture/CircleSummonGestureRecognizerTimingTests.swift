import Foundation

private typealias Paths = SummonGesturePathFixtures

/// A continuous 2.25-turn clockwise circle, with every sample from `pauseStartsAtIndex` on shifted later by `pauseSeconds`.
private func circleWithPause(pauseSeconds: Double, pauseStartsAtIndex: Int = 30) -> [SummonGesturePointerSample] {
    let circle = Paths.circle(radius: 60, turns: 2.25, durationSeconds: 1.1)
    return Array(circle[..<pauseStartsAtIndex]) + Paths.shifted(Array(circle[pauseStartsAtIndex...]), bySeconds: pauseSeconds)
}

let circleSummonGestureRecognizerTimingTestSuite = CoreTestSuite(name: "CircleSummonGestureRecognizer timing", testCases: [
    CoreTestCase(name: "a pause longer than 0.25 s between samples clears the buffer, so the loops start over") {
        try expectEqual(Paths.recognitionCount(feeding: circleWithPause(pauseSeconds: 0)), 1, "control")
        var recognizer = CircleSummonGestureRecognizer()
        let updates = Paths.feedAll(circleWithPause(pauseSeconds: 0.3), into: &recognizer)
        try expectEqual(Paths.recognitionCount(updates), 0)
        try expectEqual(updates[30].analysis, .empty, "the first sample after the pause starts a fresh buffer")
    },
    CoreTestCase(name: "a gap of exactly 0.25 s does not reset; a longer one does") {
        var recognizer = CircleSummonGestureRecognizer()
        _ = recognizer.feed(pointerSample: SummonGesturePointerSample(x: 0, y: 0, timestamp: 10), anyButtonHeld: false)
        _ = recognizer.feed(pointerSample: SummonGesturePointerSample(x: 5, y: 0, timestamp: 10.25), anyButtonHeld: false)
        try expectEqual(recognizer.bufferedSamples.count, 2)
        _ = recognizer.feed(pointerSample: SummonGesturePointerSample(x: 10, y: 0, timestamp: 10.5078125), anyButtonHeld: false)
        try expectEqual(recognizer.bufferedSamples.map(\.timestamp), [10.5078125])
    },
    CoreTestCase(name: "moves under 1.5 pt are ignored and don't refresh the pause clock") {
        var recognizer = CircleSummonGestureRecognizer()
        _ = recognizer.feed(pointerSample: SummonGesturePointerSample(x: 100, y: 100, timestamp: 10), anyButtonHeld: false)
        let tinyMove = recognizer.feed(pointerSample: SummonGesturePointerSample(x: 101, y: 101, timestamp: 10.1), anyButtonHeld: false)
        try expectEqual(tinyMove.disposition, .ignoredTooCloseToPreviousSample)
        try expectEqual(recognizer.bufferedSamples.count, 1)
        _ = recognizer.feed(pointerSample: SummonGesturePointerSample(x: 101.5, y: 100, timestamp: 10.2), anyButtonHeld: false)
        try expectEqual(recognizer.bufferedSamples.count, 2, "exactly 1.5 pt away counts")
        _ = recognizer.feed(pointerSample: SummonGesturePointerSample(x: 101.6, y: 100.1, timestamp: 10.3), anyButtonHeld: false)
        _ = recognizer.feed(pointerSample: SummonGesturePointerSample(x: 110, y: 100, timestamp: 10.46), anyButtonHeld: false)
        try expectEqual(recognizer.bufferedSamples.map(\.timestamp), [10.46], "0.26 s since the last kept sample")
    },
    CoreTestCase(name: "samples older than the window drop off, and one exactly as old as the window stays") {
        var configuration = SummonGestureConfiguration.standard
        configuration.windowSeconds = 1.25
        configuration.loopsNeeded = 1.0
        var recognizer = CircleSummonGestureRecognizer(configuration: configuration)
        for stepIndex in 0...10 {
            _ = recognizer.feed(pointerSample: SummonGesturePointerSample(x: Double(stepIndex) * 5, y: 0, timestamp: Double(stepIndex) * 0.125),
                                anyButtonHeld: false)
        }
        try expectEqual(recognizer.bufferedSamples.first?.timestamp, 0, "1.25 s old, exactly the window")
        _ = recognizer.feed(pointerSample: SummonGesturePointerSample(x: 55, y: 0, timestamp: 1.375), anyButtonHeld: false)
        try expectEqual(recognizer.bufferedSamples.first?.timestamp, 0.125)

        var standardRecognizer = CircleSummonGestureRecognizer()
        for sample in Paths.circle(radius: 60, turns: 3, durationSeconds: 3.0) {
            _ = standardRecognizer.feed(pointerSample: sample, anyButtonHeld: false)
            let oldestAge = sample.timestamp - (standardRecognizer.bufferedSamples.first?.timestamp ?? sample.timestamp)
            try expectTrue(oldestAge <= 1.275 + 1e-9, "oldest sample \(oldestAge) s old")
        }
        try expectTrue(standardRecognizer.bufferedSamples.count >= 70, "a full window is kept")
    },
    CoreTestCase(name: "the window grows with the loops needed: 0.85 s per loop, never below windowSeconds") {
        var configuration = SummonGestureConfiguration.standard
        try expectEqual(configuration.effectiveWindowSeconds, 1.5 * 0.85)
        configuration.loopsNeeded = 2.0
        try expectEqual(configuration.effectiveWindowSeconds, 2.0 * 0.85)
        configuration.loopsNeeded = 2.5
        try expectEqual(configuration.effectiveWindowSeconds, 2.5 * 0.85)
        configuration.loopsNeeded = 1.0
        try expectEqual(configuration.effectiveWindowSeconds, 1.2, "1 loop needs 0.85 s; the configured 1.2 s wins")
        configuration.windowSeconds = 2.0
        configuration.loopsNeeded = 2.0
        try expectEqual(configuration.effectiveWindowSeconds, 2.0)
    },
    CoreTestCase(name: "slow loops at 0.8 s each fire at 1.5, 2 and 2.5 loops needed, which a fixed 1.2 s window can't hold") {
        for loopsNeeded in [1.5, 2.0, 2.5] {
            var configuration = SummonGestureConfiguration.standard
            configuration.loopsNeeded = loopsNeeded
            let turns = loopsNeeded + 0.3
            let slowCircle = Paths.circle(radius: 50, turns: turns, durationSeconds: turns * 0.8, samplesPerSecond: 120)
            var recognizer = CircleSummonGestureRecognizer(configuration: configuration)
            let updates = Paths.feedAll(slowCircle, into: &recognizer)
            try expectEqual(Paths.recognitionCount(updates), 1, "\(loopsNeeded) loops needed")
            let oldestBufferedAgeAtRecognition = try unwrapOrFail(updates.first(where: \.recognized)).analysis.loops * 0.8
            try expectTrue(oldestBufferedAgeAtRecognition > 1.2, "\(loopsNeeded): the loops took \(oldestBufferedAgeAtRecognition) s")
        }
    },
    CoreTestCase(name: "moves while a mouse button is held never count and leave the buffer alone") {
        var recognizer = CircleSummonGestureRecognizer()
        let heldUpdates = Paths.feedAll(Paths.circle(radius: 60, turns: 2, durationSeconds: 1.0), into: &recognizer, anyButtonHeld: true)
        try expectEqual(Paths.recognitionCount(heldUpdates), 0)
        try expectTrue(heldUpdates.allSatisfy { update in update.disposition == .ignoredWhileButtonHeld && update == SummonGestureUpdate(
            progress: 0, ringVisible: false, ringOpacity: 0, glyphVisible: false, recognized: false, analysis: .empty,
            disposition: .ignoredWhileButtonHeld) })
        try expectTrue(recognizer.bufferedSamples.isEmpty)
    },
    CoreTestCase(name: "a short hold mid-loop repeats the ring's state and the loop can still finish") {
        let circle = Paths.circle(radius: 60, turns: 2, durationSeconds: 1.0)
        var recognizer = CircleSummonGestureRecognizer()
        let freeUpdates = Paths.feedAll(Array(circle[..<30]), into: &recognizer)
        let heldUpdates = Paths.feedAll(Array(circle[30..<36]), into: &recognizer, anyButtonHeld: true)
        try expectEqual(recognizer.bufferedSamples.count, 30)
        var expectedRepeatedUpdate = try unwrapOrFail(freeUpdates.last)
        expectedRepeatedUpdate.disposition = .ignoredWhileButtonHeld
        try expectTrue(heldUpdates.allSatisfy { update in update == expectedRepeatedUpdate })
        try expectEqual(Paths.recognitionCount(Paths.feedAll(Array(circle[36...]), into: &recognizer)), 1)
    },
    CoreTestCase(name: "a hold longer than the pause limit starts the loop over") {
        let circle = Paths.circle(radius: 60, turns: 2.4, durationSeconds: 1.2)
        var recognizer = CircleSummonGestureRecognizer()
        _ = Paths.feedAll(Array(circle[..<24]), into: &recognizer)
        _ = Paths.feedAll(Array(circle[24..<42]), into: &recognizer, anyButtonHeld: true)
        let updatesAfterRelease = Paths.feedAll(Array(circle[42...]), into: &recognizer)
        try expectEqual(Paths.recognitionCount(updatesAfterRelease), 0)
        try expectEqual(updatesAfterRelease.first?.analysis, .empty)
    },
    CoreTestCase(name: "recognition clears the buffer, starts a 0.7 s cooldown, and fires again only after it") {
        let circle = Paths.circle(radius: 60, turns: 5, durationSeconds: 2.5)
        var recognizer = CircleSummonGestureRecognizer()
        let updates = Paths.feedAll(circle, into: &recognizer)
        let recognitionIndices = updates.indices.filter { updateIndex in updates[updateIndex].recognized }
        try expectEqual(recognitionIndices.count, 2)
        let firstRecognitionTimestamp = circle[recognitionIndices[0]].timestamp
        let secondRecognitionTimestamp = circle[recognitionIndices[1]].timestamp
        try expectTrue(secondRecognitionTimestamp - firstRecognitionTimestamp >= 0.7 + 0.5, "cooldown, then loops drawn again")
        for updateIndex in (recognitionIndices[0] + 1)..<recognitionIndices[1] {
            let insideCooldown = circle[updateIndex].timestamp < firstRecognitionTimestamp + 0.7
            try expectEqual(updates[updateIndex].disposition == .ignoredDuringCooldown, insideCooldown, "sample \(updateIndex)")
            if insideCooldown { try expectEqual(updates[updateIndex], { var idle = SummonGestureUpdate.idle; idle.disposition = .ignoredDuringCooldown; return idle }()) }
        }
    },
    CoreTestCase(name: "right after firing the buffer is empty and the cooldown end is set; reset keeps the cooldown") {
        let circle = Paths.circle(radius: 60, turns: 2, durationSeconds: 1.0)
        var recognizer = CircleSummonGestureRecognizer()
        let updates = Paths.feedAll(circle, into: &recognizer)
        let recognitionIndex = try unwrapOrFail(Paths.firstRecognitionIndex(updates))
        let recognitionTimestamp = circle[recognitionIndex].timestamp
        try expectEqual(recognizer.cooldownEndsAtTimestamp, recognitionTimestamp + 0.7)
        recognizer.reset()
        try expectEqual(recognizer.cooldownEndsAtTimestamp, recognitionTimestamp + 0.7)
        let duringCooldown = recognizer.feed(pointerSample: SummonGesturePointerSample(x: 0, y: 0, timestamp: recognitionTimestamp + 0.69),
                                             anyButtonHeld: false)
        try expectEqual(duringCooldown.disposition, .ignoredDuringCooldown)
        try expectTrue(recognizer.bufferedSamples.isEmpty)
        let atCooldownEnd = recognizer.feed(pointerSample: SummonGesturePointerSample(x: 0, y: 0, timestamp: recognitionTimestamp + 0.7),
                                            anyButtonHeld: false)
        try expectEqual(atCooldownEnd.disposition, .analyzed)
        try expectEqual(recognizer.bufferedSamples.count, 1)
    },
    CoreTestCase(name: "recognition fires on one sample only; the recognized update still carries the ring at full progress") {
        var recognizer = CircleSummonGestureRecognizer()
        let updates = Paths.feedAll(Paths.circle(radius: 60, turns: 2, durationSeconds: 1.0), into: &recognizer)
        let recognizedUpdate = try unwrapOrFail(updates.first(where: \.recognized))
        try expectTrue(recognizedUpdate.ringVisible && recognizedUpdate.glyphVisible && recognizedUpdate.analysis.isValid)
        try expectEqual(recognizedUpdate.disposition, .analyzed)
    },
    CoreTestCase(name: "the ring appears at 0.60 on a path that would fire, stays down to 0.45, and the glyph shows above 0.85") {
        var recognizer = CircleSummonGestureRecognizer()
        let updates = Paths.feedAll(Paths.circle(radius: 60, turns: 2, durationSeconds: 1.0, samplesPerSecond: 120), into: &recognizer)
        var ringWasVisible = false
        for update in updates where update.disposition == .analyzed {
            let expectedRingVisible = ringWasVisible
                ? update.analysis.looksLikeACircle && update.progress >= 0.45
                : update.analysis.isValid && update.progress >= 0.60
            try expectEqual(update.ringVisible, expectedRingVisible, "\(update.progress)")
            try expectEqual(update.glyphVisible, update.ringVisible && update.progress > 0.85, "\(update.progress)")
            try expectEqual(update.progress, update.analysis.progress)
            ringWasVisible = update.ringVisible && !update.recognized
        }
        let firstRingUpdate = try unwrapOrFail(updates.first(where: \.ringVisible))
        try expectTrue(firstRingUpdate.progress >= 0.60)
        try expectTrue(firstRingUpdate.ringOpacity >= 0.35 && firstRingUpdate.ringOpacity < 0.5, "\(firstRingUpdate.ringOpacity)")
        let recognizedUpdate = try unwrapOrFail(updates.first(where: \.recognized))
        try expectEqual(recognizedUpdate.ringOpacity, 1)
        let firstGlyphIndex = try unwrapOrFail(updates.firstIndex(where: \.glyphVisible))
        try expectTrue(updates[firstGlyphIndex].progress > 0.85)
    },
    CoreTestCase(name: "half a loop or a curved move toward a button shows no ring; most of a loop does") {
        for arcTurns in [0.3, 0.5, 0.75] {
            var recognizer = CircleSummonGestureRecognizer()
            let updates = Paths.feedAll(Paths.circle(radius: 90, turns: arcTurns, durationSeconds: 0.5), into: &recognizer)
            try expectTrue(updates.allSatisfy { !$0.ringVisible }, "\(arcTurns) turns")
        }
        let curvedMoveTowardAButton = Paths.parametricPath(durationSeconds: 0.5) { fraction in
            (200 + 500 * fraction, 300 + 180 * sin(fraction * Double.pi))
        }
        var curvedMoveRecognizer = CircleSummonGestureRecognizer()
        try expectTrue(Paths.feedAll(curvedMoveTowardAButton, into: &curvedMoveRecognizer).allSatisfy { !$0.ringVisible })
        var nearlyFullLoopRecognizer = CircleSummonGestureRecognizer()
        let nearlyFullLoopUpdates = Paths.feedAll(Paths.circle(radius: 90, turns: 1.05, durationSeconds: 0.8),
                                                  into: &nearlyFullLoopRecognizer)
        try expectTrue(nearlyFullLoopUpdates.contains(where: \.ringVisible))
        try expectEqual(Paths.recognitionCount(nearlyFullLoopUpdates), 0)
    },
    CoreTestCase(name: "ring and glyph thresholds follow the configuration") {
        var configuration = SummonGestureConfiguration.standard
        configuration.ringAppearsAtProgress = 0.6
        configuration.glyphAppearsAtProgress = 0.9
        var recognizer = CircleSummonGestureRecognizer(configuration: configuration)
        let updates = Paths.feedAll(Paths.circle(radius: 60, turns: 2, durationSeconds: 1.0), into: &recognizer)
        try expectTrue(updates.filter(\.ringVisible).allSatisfy { update in update.progress >= 0.6 })
        try expectTrue(updates.filter(\.glyphVisible).allSatisfy { update in update.progress > 0.9 })
        try expectTrue(updates.contains(where: \.glyphVisible))
    },
    CoreTestCase(name: "turning the gesture off clears the buffer and ignores samples") {
        var recognizer = CircleSummonGestureRecognizer()
        _ = Paths.feedAll(Array(Paths.circle(radius: 60, turns: 2, durationSeconds: 1.0).prefix(30)), into: &recognizer)
        try expectEqual(recognizer.bufferedSamples.count, 30)
        recognizer.configuration.isEnabled = false
        try expectTrue(recognizer.bufferedSamples.isEmpty, "changing the configuration clears the buffer")
        let updates = Paths.feedAll(Paths.circle(radius: 60, turns: 2, durationSeconds: 1.0, startTimestamp: 200), into: &recognizer)
        try expectEqual(Paths.recognitionCount(updates), 0)
        try expectTrue(updates.allSatisfy { update in update.disposition == .ignoredGestureDisabled && !update.ringVisible })
        try expectTrue(recognizer.bufferedSamples.isEmpty)
    },
    CoreTestCase(name: "reset clears the buffer and the ring state") {
        var recognizer = CircleSummonGestureRecognizer()
        _ = Paths.feedAll(Array(Paths.circle(radius: 60, turns: 2, durationSeconds: 1.0).prefix(40)), into: &recognizer)
        recognizer.reset()
        try expectTrue(recognizer.bufferedSamples.isEmpty)
        try expectEqual(recognizer.cooldownEndsAtTimestamp, nil)
        let heldUpdate = recognizer.feed(pointerSample: SummonGesturePointerSample(x: 0, y: 0, timestamp: 101), anyButtonHeld: true)
        try expectTrue(!heldUpdate.ringVisible && heldUpdate.progress == 0)
    },
])
