import Foundation

private func expectSeconds(_ actualSeconds: Double, _ expectedSeconds: Double) throws {
    try expectTrue(abs(actualSeconds - expectedSeconds) < 0.000_001, "\(actualSeconds) is not \(expectedSeconds)")
}

let commandPillMorphTimelineTestSuite = CoreTestSuite(name: "CommandPillMorphTimeline", testCases: [
    CoreTestCase(name: "the submitted text is gone before the status text starts to show") {
        let timeline = CommandPillMorphTimeline.standard
        try expectTrue(timeline.keepsTextsApart)
        try expectSeconds(timeline.outgoingContentFadeEndSeconds, 0.12)
        try expectSeconds(timeline.incomingContentFadeEndSeconds, 0.28)
    },
    CoreTestCase(name: "the capsule starts changing while the submitted text leaves, not before and not after") {
        let timeline = CommandPillMorphTimeline.standard
        try expectTrue(timeline.capsuleMorphStartSeconds > timeline.outgoingContentFadeStartSeconds)
        try expectTrue(timeline.capsuleMorphStartSeconds < timeline.outgoingContentFadeEndSeconds)
        try expectTrue(timeline.capsuleMorphStartSeconds < timeline.incomingContentFadeStartSeconds)
    },
    CoreTestCase(name: "the handoff waits for both the status text and the capsule's spring") {
        let timeline = CommandPillMorphTimeline.standard
        try expectSeconds(timeline.handoffSeconds(capsuleMorphSettlingSeconds: 0.1), 0.28)
        try expectSeconds(timeline.handoffSeconds(capsuleMorphSettlingSeconds: 0.5), 0.58)
        try expectSeconds(timeline.handoffSeconds(capsuleMorphSettlingSeconds: -1), 0.28)
    },
])
