import Foundation

/// Whether a task may temporarily activate and raise its target app. The app snapshots this when the task starts.
enum TaskFocusPolicy: String, Codable, Sendable {
    case backgroundOnly = "background_only"
    case allowApprovedAssist = "allow_approved_assist"

    var allowsForegroundAssist: Bool { self == .allowApprovedAssist }
}
