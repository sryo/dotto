import AppKit

/// Whether an app can be scripted, read from its bundle's Info.plist: `NSAppleScriptEnabled` or an
/// `OSAScriptingDefinition` (its sdef). Only a running app is checked, since Dotto never launches one.
enum ScriptabilityProbe {
    static func isRunningApplicationScriptable(bundleIdentifier: String) -> Bool {
        guard let runningApplication = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
                .first(where: { !$0.isTerminated }),
              let applicationBundleURL = runningApplication.bundleURL else { return false }
        return isApplicationScriptable(applicationBundleURL: applicationBundleURL)
    }

    static func isApplicationScriptable(applicationBundleURL: URL) -> Bool {
        guard let infoDictionary = Bundle(url: applicationBundleURL)?.infoDictionary else { return false }
        if infoDictionary["OSAScriptingDefinition"] is String { return true }
        switch infoDictionary["NSAppleScriptEnabled"] {
        case let enabledFlag as Bool: return enabledFlag
        case let enabledText as String: return ["yes", "true", "1"].contains(enabledText.lowercased())
        case let enabledNumber as NSNumber: return enabledNumber.boolValue
        default: return false
        }
    }
}
