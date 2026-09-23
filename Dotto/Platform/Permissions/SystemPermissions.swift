import AppKit
import ApplicationServices

struct SystemPermissionStatus: Equatable {
    var hasAccessibilityPermission: Bool
    var hasScreenRecordingPermission: Bool

    var allRequiredPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission
    }
}

@MainActor
enum SystemPermissions {
    private static let accessibilitySettingsPaneAnchor = "Privacy_Accessibility"
    private static let screenRecordingSettingsPaneAnchor = "Privacy_ScreenCapture"

    private static var hasAttemptedAccessibilitySystemPromptDuringCurrentLaunch = false
    private static var hasAttemptedScreenRecordingSystemPromptDuringCurrentLaunch = false

    static func readCurrentStatus() -> SystemPermissionStatus {
        SystemPermissionStatus(hasAccessibilityPermission: AXIsProcessTrusted(),
                               hasScreenRecordingPermission: CGPreflightScreenCaptureAccess())
    }

    static func requestAccessibilityPermission() {
        requestPermission(hasPermissionNow: AXIsProcessTrusted(),
                          hasAttemptedSystemPrompt: &hasAttemptedAccessibilitySystemPromptDuringCurrentLaunch,
                          showSystemPrompt: {
                              let promptOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
                              _ = AXIsProcessTrustedWithOptions(promptOptions)
                          },
                          settingsPaneAnchor: accessibilitySettingsPaneAnchor)
    }

    static func requestScreenRecordingPermission() {
        requestPermission(hasPermissionNow: CGPreflightScreenCaptureAccess(),
                          hasAttemptedSystemPrompt: &hasAttemptedScreenRecordingSystemPromptDuringCurrentLaunch,
                          showSystemPrompt: { _ = CGRequestScreenCaptureAccess() },
                          settingsPaneAnchor: screenRecordingSettingsPaneAnchor)
    }

    /// Presents exactly one permission path per tap: the system prompt on the first attempt, then System Settings on
    /// later attempts, after macOS has already shown its one-time alert, so the user never gets both at once.
    private static func requestPermission(hasPermissionNow: Bool, hasAttemptedSystemPrompt: inout Bool,
                                          showSystemPrompt: () -> Void, settingsPaneAnchor: String) {
        switch PermissionRequestPolicy.presentationDestination(hasPermissionNow: hasPermissionNow,
                                                               hasAttemptedSystemPrompt: hasAttemptedSystemPrompt) {
        case .alreadyGranted:
            return
        case .systemPrompt:
            hasAttemptedSystemPrompt = true
            showSystemPrompt()
        case .systemSettings:
            guard let settingsPaneURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(settingsPaneAnchor)") else {
                return
            }
            NSWorkspace.shared.open(settingsPaneURL)
        }
    }
}
