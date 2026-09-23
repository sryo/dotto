import Foundation

/// Which app a script may tell, and whether a script plan may run at all.
enum ScriptTargetPolicy {
    static let thisAppBundleIdentifier = "com.sryo.dotto"

    /// On top of TargetApplicationPolicy's blocked apps: apps that would hand a script the whole Mac (UI scripting,
    /// other scripting hosts, remote control) or that have their own route (Shortcuts is route 3).
    private static let additionallyBlockedLowercasedBundleIdentifiers: Set<String> = [
        "com.apple.systemevents", "com.apple.scripteditor2", "com.apple.automator", "com.apple.shortcuts",
        "com.apple.console", "com.apple.screensharing", thisAppBundleIdentifier,
    ]
    private static let additionallyBlockedLowercasedBundleIdentifierPrefixes = ["com.apple.remotedesktop"]

    /// TargetApplicationPolicy's blocked apps plus System Events, Script Editor, Automator, Shortcuts, Console, Screen
    /// Sharing, Remote Desktop and Dotto itself. Finder is allowed.
    static func isBlockedScriptTarget(bundleIdentifier: String) -> Bool {
        let lowercasedBundleIdentifier = bundleIdentifier.lowercased()
        let targetApplication = TargetApplicationReference(processIdentifier: 0, applicationName: "", bundleIdentifier: bundleIdentifier)
        return lowercasedBundleIdentifier.isEmpty
            || TargetApplicationPolicy.isBlockedTargetApplication(targetApplication)
            || additionallyBlockedLowercasedBundleIdentifiers.contains(lowercasedBundleIdentifier)
            || additionallyBlockedLowercasedBundleIdentifierPrefixes.contains { lowercasedBundleIdentifier.hasPrefix($0) }
    }

    /// deny: blocked target, a source too long, denied constructs, no app named, or any app named but the declared one
    /// (by name or bundle id). The source is inspected again here rather than trusting `scriptPlan.inspection`.
    static func evaluate(_ scriptPlan: ScriptPlan) -> SafetyVerdict {
        if isBlockedScriptTarget(bundleIdentifier: scriptPlan.targetBundleIdentifier) {
            return .deny(reasonForModel: "Scripts can't tell \(scriptPlan.targetApplicationName). Use submit_plan instead.")
        }
        if scriptPlan.source.count > ScriptPlan.maximumSourceLength {
            return .deny(reasonForModel: "The script is longer than \(ScriptPlan.maximumSourceLength) characters.")
        }
        let inspection = ScriptSourceInspector.inspect(source: scriptPlan.source, language: scriptPlan.language)
        if !inspection.deniedConstructs.isEmpty {
            return .deny(reasonForModel: "The script uses what scripts may not use: \(inspection.deniedConstructs.joined(separator: ", ")). "
                + "Remove it, or use submit_plan instead.")
        }
        guard !inspection.referencedApplicationSpecifiers.isEmpty else {
            return .deny(reasonForModel: "The script must tell \(scriptPlan.targetApplicationName) by name: "
                + "tell application \"\(scriptPlan.targetApplicationName)\" (AppleScript) or Application(\"\(scriptPlan.targetApplicationName)\") (JXA).")
        }
        let allowedLowercasedSpecifiers: Set<String> = [scriptPlan.targetApplicationName.lowercased(),
                                                        scriptPlan.targetBundleIdentifier.lowercased()]
        let otherSpecifiers = inspection.referencedApplicationSpecifiers.filter { !allowedLowercasedSpecifiers.contains($0.lowercased()) }
        if !otherSpecifiers.isEmpty {
            return .deny(reasonForModel: "The script may tell only \(scriptPlan.targetApplicationName), but it also names "
                + otherSpecifiers.map { "“\($0)”" }.joined(separator: ", ") + ".")
        }
        return .allow
    }
}
