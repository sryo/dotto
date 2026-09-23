import Foundation

private func application(bundleIdentifier: String?) -> TargetApplicationReference {
    TargetApplicationReference(processIdentifier: 4242, applicationName: "Fixture", bundleIdentifier: bundleIdentifier)
}

let targetApplicationPolicyTestSuite = CoreTestSuite(name: "TargetApplicationPolicy", testCases: [
    CoreTestCase(name: "terminals, settings and password managers are blocked") {
        for blockedBundleIdentifier in ["com.apple.Terminal", "com.googlecode.iterm2", "com.apple.systempreferences",
                                        "com.apple.keychainaccess", "com.1password.1password", "com.apple.Passwords"] {
            try expectTrue(TargetApplicationPolicy.isBlockedTargetApplication(application(bundleIdentifier: blockedBundleIdentifier)),
                           blockedBundleIdentifier)
        }
    },
    CoreTestCase(name: "every Warp channel is blocked by prefix") {
        for warpBundleIdentifier in ["dev.warp.Warp", "dev.warp.Warp-Stable", "dev.warp.Warp-Preview"] {
            try expectTrue(TargetApplicationPolicy.isBlockedTargetApplication(application(bundleIdentifier: warpBundleIdentifier)),
                           warpBundleIdentifier)
        }
    },
    CoreTestCase(name: "ordinary apps and apps without a bundle identifier are allowed") {
        try expectTrue(!TargetApplicationPolicy.isBlockedTargetApplication(application(bundleIdentifier: "com.apple.finder")))
        try expectTrue(!TargetApplicationPolicy.isBlockedTargetApplication(application(bundleIdentifier: "com.apple.terminalish")))
        try expectTrue(!TargetApplicationPolicy.isBlockedTargetApplication(application(bundleIdentifier: nil)))
    },
    CoreTestCase(name: "app switching, hiding, quitting and Force Quit shortcuts are blocked, including supersets") {
        try expectTrue(TargetApplicationPolicy.isBlockedSystemShortcut(keyName: "tab", modifiers: [.command]))
        try expectTrue(TargetApplicationPolicy.isBlockedSystemShortcut(keyName: "tab", modifiers: [.command, .shift]))
        try expectTrue(TargetApplicationPolicy.isBlockedSystemShortcut(keyName: "Q", modifiers: [.control, .command]))
        try expectTrue(TargetApplicationPolicy.isBlockedSystemShortcut(keyName: " ", modifiers: [.command]))
        try expectTrue(TargetApplicationPolicy.isBlockedSystemShortcut(keyName: "esc", modifiers: [.command, .option]))
    },
    CoreTestCase(name: "shortcuts missing a required modifier are allowed") {
        try expectTrue(!TargetApplicationPolicy.isBlockedSystemShortcut(keyName: "tab", modifiers: []))
        try expectTrue(!TargetApplicationPolicy.isBlockedSystemShortcut(keyName: "escape", modifiers: [.command]))
        try expectTrue(!TargetApplicationPolicy.isBlockedSystemShortcut(keyName: "c", modifiers: [.command]))
    },
])
