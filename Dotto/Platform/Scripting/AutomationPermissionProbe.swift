import AppKit
import CoreServices

/// Whether macOS lets Dotto send Apple Events to an app (Privacy & Security › Automation). With `mayPromptUser` the
/// call can show the system prompt and blocks until the user answers, so it runs off the main thread and only after
/// the user asked for the script to run; planning always passes false.
enum AutomationPermissionProbe {
    private static let eventWouldRequireUserConsentStatus: OSStatus = -1744
    private static let eventNotPermittedStatus: OSStatus = -1743
    private static let processNotFoundStatus: OSStatus = -600

    static func permissionState(forBundleIdentifier bundleIdentifier: String, mayPromptUser: Bool) async -> AutomationPermissionState {
        await Task.detached(priority: .userInitiated) {
            permissionStateBlocking(forBundleIdentifier: bundleIdentifier, mayPromptUser: mayPromptUser)
        }.value
    }

    private static func permissionStateBlocking(forBundleIdentifier bundleIdentifier: String, mayPromptUser: Bool) -> AutomationPermissionState {
        let targetDescriptor = NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier)
        guard let targetAddress = targetDescriptor.aeDesc else { return .unknown }
        // A real event, the core suite's "get data" that scripts send first: with typeWildCard for class and id,
        // macOS often answers -1744 (would need consent) without ever showing its prompt.
        let permissionStatus = AEDeterminePermissionToAutomateTarget(
            targetAddress, AEEventClass(kAECoreSuite), AEEventID(kAEGetData), mayPromptUser)
        switch permissionStatus {
        case noErr: return .granted
        case eventWouldRequireUserConsentStatus: return .notYetAsked
        case eventNotPermittedStatus: return .denied
        case processNotFoundStatus: return .targetNotRunning
        default: return .unknown
        }
    }
}
