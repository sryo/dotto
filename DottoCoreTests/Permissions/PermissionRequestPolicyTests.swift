import Foundation

let permissionRequestPolicyTestSuite = CoreTestSuite(name: "PermissionRequestPolicy", testCases: [
    CoreTestCase(name: "the first request uses the system prompt only") {
        try expectEqual(PermissionRequestPolicy.presentationDestination(hasPermissionNow: false, hasAttemptedSystemPrompt: false),
                        .systemPrompt)
    },
    CoreTestCase(name: "a repeated request opens System Settings") {
        try expectEqual(PermissionRequestPolicy.presentationDestination(hasPermissionNow: false, hasAttemptedSystemPrompt: true),
                        .systemSettings)
    },
    CoreTestCase(name: "an already granted permission presents nothing") {
        try expectEqual(PermissionRequestPolicy.presentationDestination(hasPermissionNow: true, hasAttemptedSystemPrompt: true),
                        .alreadyGranted)
    },
    CoreTestCase(name: "a previously confirmed Screen Recording grant skips the gate") {
        try expectTrue(PermissionRequestPolicy.shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch(
            hasScreenRecordingPermissionNow: false, hasPreviouslyConfirmedScreenRecordingPermission: true))
        try expectTrue(!PermissionRequestPolicy.shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch(
            hasScreenRecordingPermissionNow: false, hasPreviouslyConfirmedScreenRecordingPermission: false))
    },
])
