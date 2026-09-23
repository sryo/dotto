import Foundation

let targetApplicationKindClassifierTestSuite = CoreTestSuite(name: "TargetApplicationKindClassifier", testCases: [
    CoreTestCase(name: "known browser bundle identifiers") {
        try expectEqual(TargetApplicationKindClassifier.classify(bundleIdentifier: "com.apple.Safari", embeddedFrameworkNames: []), .webKitBrowser)
        try expectEqual(TargetApplicationKindClassifier.classify(bundleIdentifier: "company.thebrowser.Browser", embeddedFrameworkNames: []),
                        .chromiumBrowser)
        try expectEqual(TargetApplicationKindClassifier.classify(bundleIdentifier: "company.thebrowser.dia", embeddedFrameworkNames: []),
                        .chromiumBrowser)
        try expectEqual(TargetApplicationKindClassifier.classify(bundleIdentifier: "com.google.Chrome.canary", embeddedFrameworkNames: []),
                        .chromiumBrowser)
    },
    CoreTestCase(name: "unknown bundles are classified by their frameworks") {
        try expectEqual(TargetApplicationKindClassifier.classify(bundleIdentifier: "com.example.chat",
                                                                 embeddedFrameworkNames: ["Squirrel.framework", "Electron Framework.framework"]),
                        .electron)
        try expectEqual(TargetApplicationKindClassifier.classify(bundleIdentifier: "com.example.browser",
                                                                 embeddedFrameworkNames: ["Example Chromium Framework.framework"]),
                        .chromiumBrowser)
    },
    CoreTestCase(name: "everything else is Cocoa") {
        try expectEqual(TargetApplicationKindClassifier.classify(bundleIdentifier: "com.apple.TextEdit", embeddedFrameworkNames: []), .cocoa)
        try expectEqual(TargetApplicationKindClassifier.classify(bundleIdentifier: nil, embeddedFrameworkNames: ["Sparkle.framework"]), .cocoa)
    },
])
