import AppKit

/// Remembers the last app other than Dotto that the user brought to the front, so that after Dotto's own file
/// pickers or a click on its notification (which activate Dotto) the keyboard goes back to where the user was,
/// never to an app macOS happens to pick.
@MainActor
final class PreviousApplicationTracker {
    /// Activations to leave out, e.g. the target app coming forward for an approved assist.
    var shouldIgnoreActivation: ((NSRunningApplication) -> Bool)?
    private(set) var lastFrontmostApplicationOtherThanThisApp: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?

    func start() {
        guard activationObserver == nil else { return }
        if let frontmostApplication = NSWorkspace.shared.frontmostApplication { recordActivation(of: frontmostApplication) }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] activationNotification in
            guard let activatedApplication = activationNotification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            MainActor.assumeIsolated { self?.recordActivation(of: activatedApplication) }
        }
    }

    /// Only while Dotto is the active app: otherwise the user has already moved on, and activating anything would
    /// take their focus.
    func handActivationBackIfThisAppIsActive() {
        guard NSApp.isActive, let lastFrontmostApplicationOtherThanThisApp, !lastFrontmostApplicationOtherThanThisApp.isTerminated else { return }
        lastFrontmostApplicationOtherThanThisApp.activate()
    }

    /// A notification click can reach Dotto a moment before macOS finishes activating it, so this checks again shortly.
    func handActivationBackOnceThisAppIsActive() {
        handActivationBackIfThisAppIsActive()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            self?.handActivationBackIfThisAppIsActive()
        }
    }

    private func recordActivation(of activatedApplication: NSRunningApplication) {
        guard activatedApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              shouldIgnoreActivation?(activatedApplication) != true else { return }
        lastFrontmostApplicationOtherThanThisApp = activatedApplication
    }
}
