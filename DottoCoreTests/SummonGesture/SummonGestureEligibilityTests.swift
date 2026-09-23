import Foundation

private func allowsObservation(gestureEnabled: Bool = true, taskIsRunning: Bool = false, commandPillIsOpen: Bool = false,
                               frontmostApplicationBundleIdentifier: String? = "com.apple.finder",
                               frontmostApplicationIsFullScreen: Bool = false,
                               screenIsLockedOrAsleep: Bool = false,
                               excludedBundleIdentifiers: [String] = SummonGestureEligibility.defaultExcludedBundleIdentifiers) -> Bool {
    SummonGestureEligibility.allowsObservation(gestureEnabled: gestureEnabled, taskIsRunning: taskIsRunning,
                                               commandPillIsOpen: commandPillIsOpen,
                                               frontmostApplicationBundleIdentifier: frontmostApplicationBundleIdentifier,
                                               frontmostApplicationIsFullScreen: frontmostApplicationIsFullScreen,
                                               screenIsLockedOrAsleep: screenIsLockedOrAsleep,
                                               excludedBundleIdentifiers: excludedBundleIdentifiers)
}

private let thisAppProcessIdentifier: Int32 = 4242

private func allowsSummoning(bundleIdentifier: String? = "com.apple.TextEdit", processIdentifier: Int32 = 777,
                             displayUnderPointerIsFullScreen: Bool = false, screenIsLockedOrAsleep: Bool = false,
                             excludedBundleIdentifiers: [String] = SummonGestureEligibility.defaultExcludedBundleIdentifiers,
                             hasTarget: Bool = true) -> Bool {
    let targetApplication = hasTarget
        ? TargetApplicationReference(processIdentifier: processIdentifier, applicationName: "Target", bundleIdentifier: bundleIdentifier)
        : nil
    return SummonGestureEligibility.allowsSummoning(targetApplication: targetApplication,
                                                    thisAppProcessIdentifier: thisAppProcessIdentifier,
                                                    thisAppBundleIdentifier: "com.sryo.dotto",
                                                    displayUnderPointerIsFullScreen: displayUnderPointerIsFullScreen,
                                                    screenIsLockedOrAsleep: screenIsLockedOrAsleep,
                                                    excludedBundleIdentifiers: excludedBundleIdentifiers)
}

let summonGestureEligibilityTestSuite = CoreTestSuite(name: "SummonGestureEligibility", testCases: [
    CoreTestCase(name: "an idle Dotto over an ordinary windowed app observes") {
        try expectTrue(allowsObservation())
    },
    CoreTestCase(name: "off, during a run, or with the command pill open, nothing is observed") {
        try expectEqual(allowsObservation(gestureEnabled: false), false)
        try expectEqual(allowsObservation(taskIsRunning: true), false)
        try expectEqual(allowsObservation(commandPillIsOpen: true), false)
    },
    CoreTestCase(name: "full-screen apps are never observed, whatever the exclusion list") {
        try expectEqual(allowsObservation(frontmostApplicationIsFullScreen: true, excludedBundleIdentifiers: []), false)
    },
    CoreTestCase(name: "excluded apps are skipped, matched case-insensitively and ignoring whitespace") {
        try expectEqual(allowsObservation(frontmostApplicationBundleIdentifier: "com.figma.Desktop"), false)
        try expectEqual(allowsObservation(frontmostApplicationBundleIdentifier: "COM.FIGMA.DESKTOP"), false)
        try expectEqual(allowsObservation(frontmostApplicationBundleIdentifier: "com.example.paint",
                                          excludedBundleIdentifiers: ["  com.Example.Paint \n"]), false)
        try expectTrue(allowsObservation(frontmostApplicationBundleIdentifier: "com.figma.Desktop", excludedBundleIdentifiers: []),
                       "the user can remove a default")
        try expectTrue(allowsObservation(frontmostApplicationBundleIdentifier: "com.figma.DesktopHelper"), "no prefix matching")
    },
    CoreTestCase(name: "an app without a bundle id is observed unless another rule blocks it") {
        try expectTrue(allowsObservation(frontmostApplicationBundleIdentifier: nil))
        try expectEqual(allowsObservation(frontmostApplicationBundleIdentifier: nil, frontmostApplicationIsFullScreen: true), false)
    },
    CoreTestCase(name: "a locked, sleeping, screen-saver or switched-out session is never observed") {
        try expectEqual(allowsObservation(screenIsLockedOrAsleep: true, excludedBundleIdentifiers: []), false)
        try expectEqual(allowsObservation(frontmostApplicationBundleIdentifier: nil, screenIsLockedOrAsleep: true), false)
    },
    CoreTestCase(name: "at fire time an ordinary app under the pointer may be summoned") {
        try expectTrue(allowsSummoning())
        try expectTrue(allowsSummoning(bundleIdentifier: nil), "an app without a bundle id")
    },
    CoreTestCase(name: "at fire time an excluded app under the pointer is refused, matched like observation") {
        try expectEqual(allowsSummoning(bundleIdentifier: "com.figma.Desktop"), false)
        try expectEqual(allowsSummoning(bundleIdentifier: " COM.FIGMA.desktop\n"), false)
        try expectEqual(allowsSummoning(bundleIdentifier: "com.example.paint", excludedBundleIdentifiers: ["  com.Example.Paint "]), false)
        try expectTrue(allowsSummoning(bundleIdentifier: "com.figma.Desktop", excludedBundleIdentifiers: []))
    },
    CoreTestCase(name: "at fire time Dotto itself, blocked apps and no target at all are refused") {
        try expectEqual(allowsSummoning(processIdentifier: thisAppProcessIdentifier), false)
        try expectEqual(allowsSummoning(bundleIdentifier: "com.sryo.dotto"), false)
        try expectEqual(allowsSummoning(bundleIdentifier: "COM.SRYO.DOTTO"), false)
        try expectEqual(allowsSummoning(bundleIdentifier: "com.apple.Terminal", excludedBundleIdentifiers: []), false)
        try expectEqual(allowsSummoning(bundleIdentifier: "com.1password.1password", excludedBundleIdentifiers: []), false)
        try expectEqual(allowsSummoning(bundleIdentifier: "dev.warp.Warp-Stable", excludedBundleIdentifiers: []), false)
        try expectEqual(allowsSummoning(hasTarget: false), false)
    },
    CoreTestCase(name: "at fire time a full-screen display under the pointer or a locked screen is refused") {
        try expectEqual(allowsSummoning(displayUnderPointerIsFullScreen: true), false)
        try expectEqual(allowsSummoning(screenIsLockedOrAsleep: true), false)
    },
    CoreTestCase(name: "the default list covers drawing, design, 3D and game tools, and not everyday apps") {
        let defaults = SummonGestureEligibility.defaultExcludedBundleIdentifiers
        for drawingOrGameApp in ["com.figma.Desktop", "com.bohemiancoding.sketch3", "com.adobe.Photoshop", "com.adobe.illustrator",
                                 "com.adobe.InDesign", "com.seriflabs.affinitydesigner2", "com.seriflabs.affinityphoto2",
                                 "com.pixelmatorteam.pixelmator.x", "org.blenderfoundation.blender", "com.unity3d.UnityEditor5.x",
                                 "com.valvesoftware.steam"] {
            try expectTrue(defaults.contains(drawingOrGameApp), drawingOrGameApp)
        }
        for everydayApp in ["com.apple.finder", "com.apple.Safari", "com.apple.mail", "com.apple.Notes"] {
            try expectTrue(allowsObservation(frontmostApplicationBundleIdentifier: everydayApp), everydayApp)
        }
        try expectEqual(Set(defaults).count, defaults.count, "no duplicates")
        try expectTrue(defaults.count <= 20, "kept short")
    },
])
