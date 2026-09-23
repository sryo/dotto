import Foundation

enum TargetApplicationKindClassifier {
    static let webKitBrowserBundleIdentifiers: Set<String> = ["com.apple.safari", "com.apple.safaritechnologypreview"]
    static let chromiumBrowserBundleIdentifiers: Set<String> = [
        "com.google.chrome", "com.google.chrome.canary", "com.google.chrome.beta", "com.google.chrome.dev",
        "org.chromium.chromium", "company.thebrowser.browser", "company.thebrowser.dia",
        "com.brave.browser", "com.microsoft.edgemac", "com.vivaldi.vivaldi", "com.operasoftware.opera",
    ]

    /// `embeddedFrameworkNames` are the entries of the bundle's Contents/Frameworks, which catch Electron apps and
    /// Chromium browsers missing from the list.
    static func classify(bundleIdentifier: String?, embeddedFrameworkNames: [String]) -> TargetApplicationKind {
        let lowercasedBundleIdentifier = bundleIdentifier?.lowercased() ?? ""
        if webKitBrowserBundleIdentifiers.contains(lowercasedBundleIdentifier) { return .webKitBrowser }
        if chromiumBrowserBundleIdentifiers.contains(lowercasedBundleIdentifier) { return .chromiumBrowser }
        if embeddedFrameworkNames.contains(where: { ["Electron Framework.framework", "Chromium Embedded Framework.framework"].contains($0) }) {
            return .electron
        }
        if embeddedFrameworkNames.contains(where: { $0.contains("Chromium") || $0.contains("Chrome") }) { return .chromiumBrowser }
        return .cocoa
    }
}
