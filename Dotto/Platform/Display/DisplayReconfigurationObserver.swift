import AppKit
import CoreGraphics

/// Listens to Quartz's display reconfiguration callback (displays added, removed, moved, mirrored, resized, or the menu
/// bar moved to another display). It marks the primary display height as unsettled while displays are changing, records
/// the new height once they have, and posts `didFinishNotification` once per finished reconfiguration. It only reads:
/// Dotto never configures, captures or fades a display.
@MainActor final class DisplayReconfigurationObserver {
    static let didFinishNotification = Notification.Name("com.sryo.dotto.displayReconfigurationDidFinish")
    /// Quartz sends the after-change callbacks promptly; a reconfiguration that never reports finishing (a display
    /// unplugged mid-change) must not leave the height frozen at its old value for good.
    private static let unfinishedReconfigurationTimeoutSeconds: TimeInterval = 3

    private var tracker = DisplayReconfigurationTracker()
    private var isRegistered = false
    private var finishIsScheduled = false
    private var reconfigurationWatchdogTask: Task<Void, Never>?

    func start() {
        guard !isRegistered else { return }
        PrimaryDisplayHeightCache.shared.recordSettledHeight(CGDisplayBounds(CGMainDisplayID()).height)
        let registrationResult = CGDisplayRegisterReconfigurationCallback(Self.reconfigurationCallback,
                                                                          Unmanaged.passUnretained(self).toOpaque())
        isRegistered = registrationResult == .success
    }

    func stop() {
        guard isRegistered else { return }
        CGDisplayRemoveReconfigurationCallback(Self.reconfigurationCallback, Unmanaged.passUnretained(self).toOpaque())
        isRegistered = false
        reconfigurationWatchdogTask?.cancel()
    }

    /// Quartz delivers these on the thread that runs the event loop, which for Dotto is the main thread.
    private static let reconfigurationCallback: CGDisplayReconfigurationCallBack = { displayIdentifier, changeFlags, userInfo in
        guard let userInfo else { return }
        let observer = Unmanaged<DisplayReconfigurationObserver>.fromOpaque(userInfo).takeUnretainedValue()
        MainActor.assumeIsolated {
            observer.handleCallback(displayIdentifier: displayIdentifier, changeFlags: changeFlags.rawValue)
        }
    }

    private func handleCallback(displayIdentifier: CGDirectDisplayID, changeFlags: UInt32) {
        switch tracker.handleCallback(displayIdentifier: displayIdentifier, flags: changeFlags) {
        case .began:
            PrimaryDisplayHeightCache.shared.setDisplaysAreReconfiguring(true)
            startWatchdog()
        case .finished:
            scheduleFinish()
        case nil:
            break
        }
    }

    /// Several displays report in the same burst; everyone downstream hears about it once, on the next turn.
    private func scheduleFinish() {
        guard !finishIsScheduled else { return }
        finishIsScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.finishReconfiguration() }
        }
    }

    private func finishReconfiguration() {
        finishIsScheduled = false
        reconfigurationWatchdogTask?.cancel()
        reconfigurationWatchdogTask = nil
        PrimaryDisplayHeightCache.shared.recordSettledHeight(CGDisplayBounds(CGMainDisplayID()).height)
        PrimaryDisplayHeightCache.shared.setDisplaysAreReconfiguring(false)
        NotificationCenter.default.post(name: Self.didFinishNotification, object: self)
    }

    private func startWatchdog() {
        reconfigurationWatchdogTask?.cancel()
        reconfigurationWatchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.unfinishedReconfigurationTimeoutSeconds * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.tracker = DisplayReconfigurationTracker()
            self.finishReconfiguration()
        }
    }
}
