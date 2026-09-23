import Foundation

enum PermissionRequestPresentationDestination: Equatable {
    case alreadyGranted
    case systemPrompt
    case systemSettings
}

/// Pure decisions behind the Accessibility and Screen Recording request flows, kept free of
/// AppKit so they can be unit-tested. `SystemPermissions` performs the side effects.
enum PermissionRequestPolicy {
    /// macOS shows its one-time permission alert only once per launch, so a repeated request
    /// goes to System Settings instead of silently doing nothing.
    static func presentationDestination(
        hasPermissionNow: Bool,
        hasAttemptedSystemPrompt: Bool
    ) -> PermissionRequestPresentationDestination {
        if hasPermissionNow {
            return .alreadyGranted
        }

        if hasAttemptedSystemPrompt {
            return .systemSettings
        }

        return .systemPrompt
    }

    /// CGPreflightScreenCaptureAccess() can return a false negative after the user already
    /// approved the app, so a previously confirmed grant is trusted.
    static func shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch(
        hasScreenRecordingPermissionNow: Bool,
        hasPreviouslyConfirmedScreenRecordingPermission: Bool
    ) -> Bool {
        hasScreenRecordingPermissionNow || hasPreviouslyConfirmedScreenRecordingPermission
    }
}
