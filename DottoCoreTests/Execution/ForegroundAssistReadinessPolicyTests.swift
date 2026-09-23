import Foundation

private func inputs(idleSeconds: TimeInterval?, secureInput: Bool?, secureInputProcess: Int32? = nil) -> ForegroundAssistReadinessInputs {
    ForegroundAssistReadinessInputs(secondsSinceLastRealUserInput: idleSeconds, secureEventInputIsEnabled: secureInput,
                                    secureEventInputProcessIdentifier: secureInputProcess)
}

let foregroundAssistReadinessPolicyTestSuite = CoreTestSuite(name: "ForegroundAssistReadinessPolicy", testCases: [
    CoreTestCase(name: "ready only after 1.5 s without real input") {
        let policy = ForegroundAssistReadinessPolicy()
        try expectEqual(policy.readiness(for: inputs(idleSeconds: 1.49, secureInput: false), targetProcessIdentifier: 42), .userIsActive)
        try expectEqual(policy.readiness(for: inputs(idleSeconds: 1.5, secureInput: false), targetProcessIdentifier: 42), .ready)
    },
    CoreTestCase(name: "unknown input or secure input state fails closed") {
        let policy = ForegroundAssistReadinessPolicy()
        try expectEqual(policy.readiness(for: inputs(idleSeconds: nil, secureInput: false), targetProcessIdentifier: 42), .userIsActive)
        try expectEqual(policy.readiness(for: inputs(idleSeconds: 10, secureInput: nil), targetProcessIdentifier: 42),
                        .secureInputHeldByAnotherProcess)
    },
    CoreTestCase(name: "secure input held by another or an unknown process blocks; held by the target doesn't") {
        let policy = ForegroundAssistReadinessPolicy()
        try expectEqual(policy.readiness(for: inputs(idleSeconds: 10, secureInput: true, secureInputProcess: 7), targetProcessIdentifier: 42),
                        .secureInputHeldByAnotherProcess)
        try expectEqual(policy.readiness(for: inputs(idleSeconds: 10, secureInput: true), targetProcessIdentifier: 42),
                        .secureInputHeldByAnotherProcess)
        try expectEqual(policy.readiness(for: inputs(idleSeconds: 10, secureInput: true, secureInputProcess: 42), targetProcessIdentifier: 42),
                        .ready)
        try expectEqual(policy.readiness(for: inputs(idleSeconds: 10, secureInput: true, secureInputProcess: 42), targetProcessIdentifier: nil),
                        .secureInputHeldByAnotherProcess)
    },
    CoreTestCase(name: "the re-ask names the cause and the app only") {
        let reason = ForegroundAssistReadinessPolicy.reaskReason(after: .userIsActive, targetApplicationName: "Arc")
        try expectTrue(reason.contains("bring Arc forward") && reason.contains("still using your Mac"), reason)
    },
])
