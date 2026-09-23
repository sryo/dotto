import AppKit
import SwiftUI

/// What the circle summon gesture reads from the rest of the app. Closures, so the start/stop rule can be exercised
/// without a live session.
struct SummonGestureControllerEnvironment {
    var configuration: () -> SummonGestureConfiguration
    var excludedBundleIdentifiers: () -> [String]
    /// Planning, running, waiting on the user mid-run, reviewing a checklist or teaching.
    var taskIsInProgress: () -> Bool
    /// The command bar or the command pill.
    var commandPanelIsOpen: () -> Bool
    var frontmostApplicationBundleIdentifier: () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    /// Whether the frontmost app fills the display holding this top-left global point.
    var frontmostApplicationIsFullScreenOnDisplay: (CGPoint) -> Bool = { topLeftGlobalPoint in
        PointerTargetApplicationResolver.frontmostApplicationIsFullScreen(onDisplayContainingTopLeftGlobalPoint: topLeftGlobalPoint)
    }
    var currentTopLeftGlobalPointerLocation: () -> CGPoint = { PointerTargetApplicationResolver.currentTopLeftGlobalPointerLocation() }
    var screenIsLockedOrSessionIsInactive: () -> Bool = { SessionScreenLockReader.screenIsLockedOrSessionIsInactive() }
    var taskColor: () -> Color
    var reducesMotion: () -> Bool
    /// The gesture was recognized at this top-left global point. Returns whether the pill opened: the app under the
    /// pointer may be excluded, blocked or Dotto itself, and then nothing happens.
    var onGestureRecognized: (_ topLeftGlobalPoint: CGPoint, _ displayUnderPointerIsFullScreen: Bool,
                              _ screenIsLockedOrAsleep: Bool) -> Bool
}

/// Runs the circle summon gesture: observes pointer moves only while `SummonGestureEligibility` allows it, feeds them
/// to Core's recognizer, draws the ring around the pointer and fires the pill. Eligibility is re-read whenever one
/// of its inputs can change (the frontmost app, the Space, the session state, the command panel, the settings, the
/// lock screen, the screen saver, display sleep and display changes), never per move.
@MainActor
final class SummonGestureController {
    private let pointerMovementObserver: PointerMovementObserver
    private let ringPanelController: SummonGestureRingPanelController
    private let environment: SummonGestureControllerEnvironment
    private var circleRecognizer: CircleSummonGestureRecognizer
    private var workspaceNotificationObservers: [NSObjectProtocol] = []
    private var distributedNotificationObservers: [NSObjectProtocol] = []
    private var applicationNotificationObservers: [NSObjectProtocol] = []
    private var isStarted = false

    private var screenIsLocked = false
    private var screenSaverIsRunning = false
    private var displaysAreAsleep = false
    /// Fast user switching moved another login session to the console.
    private var sessionIsInactive = false

    /// The ring hides once the pointer has been still for the recognizer's pause limit, since the next move will
    /// start the loop over anyway. Uptime of the latest move, and the one task waiting out the stillness.
    private var latestPointerMovementUptime: TimeInterval = 0
    private var ringHideAfterStillnessTask: Task<Void, Never>?

    init(pointerMovementObserver: PointerMovementObserver, ringPanelController: SummonGestureRingPanelController,
         environment: SummonGestureControllerEnvironment) {
        self.pointerMovementObserver = pointerMovementObserver
        self.ringPanelController = ringPanelController
        self.environment = environment
        self.circleRecognizer = CircleSummonGestureRecognizer(configuration: environment.configuration())
    }

    var isObservingPointer: Bool { pointerMovementObserver.isObserving }

    private var screenIsLockedOrAsleep: Bool {
        screenIsLocked || screenSaverIsRunning || displaysAreAsleep || sessionIsInactive
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        pointerMovementObserver.onPointerMoved = { [weak self] observedPointerMovement in
            self?.handlePointerMovement(observedPointerMovement)
        }
        pointerMovementObserver.onMouseButtonPressed = { [weak self] in
            self?.circleRecognizer.reset()
            self?.hideRing()
        }
        screenIsLocked = environment.screenIsLockedOrSessionIsInactive()
        observeWorkspaceNotifications()
        observeDistributedNotifications()
        applicationNotificationObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshObservation() }
        })
        refreshObservation()
    }

    func stop() {
        isStarted = false
        for workspaceNotificationObserver in workspaceNotificationObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceNotificationObserver)
        }
        workspaceNotificationObservers.removeAll()
        for distributedNotificationObserver in distributedNotificationObservers {
            DistributedNotificationCenter.default().removeObserver(distributedNotificationObserver)
        }
        distributedNotificationObservers.removeAll()
        for applicationNotificationObserver in applicationNotificationObservers {
            NotificationCenter.default.removeObserver(applicationNotificationObserver)
        }
        applicationNotificationObservers.removeAll()
        stopObservingPointer()
    }

    /// Settings changed: the recognizer starts over with the new ones, and a ring from the old ones goes away.
    func configurationDidChange() {
        circleRecognizer.configuration = environment.configuration()
        hideRing()
        refreshObservation()
    }

    /// Starts or stops the one global pointer observation to match `SummonGestureEligibility`. Full screen is judged
    /// on the display the pointer is on now.
    func refreshObservation() {
        let observationAllowed = isStarted && SummonGestureEligibility.allowsObservation(
            gestureEnabled: environment.configuration().isEnabled,
            taskIsRunning: environment.taskIsInProgress(),
            commandPillIsOpen: environment.commandPanelIsOpen(),
            frontmostApplicationBundleIdentifier: environment.frontmostApplicationBundleIdentifier(),
            frontmostApplicationIsFullScreen: environment.frontmostApplicationIsFullScreenOnDisplay(
                environment.currentTopLeftGlobalPointerLocation()),
            screenIsLockedOrAsleep: screenIsLockedOrAsleep,
            excludedBundleIdentifiers: environment.excludedBundleIdentifiers())
        if observationAllowed {
            pointerMovementObserver.startObserving()
        } else {
            stopObservingPointer()
        }
    }

    // MARK: - Eligibility inputs

    private func observeWorkspaceNotifications() {
        let workspaceNotificationCenter = NSWorkspace.shared.notificationCenter
        let stateChangeByNotificationName: [(NSNotification.Name, ((SummonGestureController) -> Void)?)] = [
            (NSWorkspace.didActivateApplicationNotification, nil),
            (NSWorkspace.activeSpaceDidChangeNotification, nil),
            (NSWorkspace.sessionDidResignActiveNotification, { controller in controller.sessionIsInactive = true }),
            // Coming back through the login window may not announce an unlock, so the lock state is read afresh.
            (NSWorkspace.sessionDidBecomeActiveNotification, { controller in
                controller.sessionIsInactive = false
                controller.screenIsLocked = controller.environment.screenIsLockedOrSessionIsInactive()
            }),
            (NSWorkspace.screensDidSleepNotification, { controller in controller.displaysAreAsleep = true }),
            (NSWorkspace.screensDidWakeNotification, { controller in controller.displaysAreAsleep = false }),
        ]
        for (notificationName, applyStateChange) in stateChangeByNotificationName {
            workspaceNotificationObservers.append(workspaceNotificationCenter.addObserver(
                forName: notificationName, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    applyStateChange?(self)
                    self.refreshObservation()
                }
            })
        }
    }

    /// The lock screen and the screen saver announce themselves only as distributed notifications.
    private func observeDistributedNotifications() {
        let stateChangeByNotificationName: [(String, (SummonGestureController) -> Void)] = [
            ("com.apple.screenIsLocked", { controller in controller.screenIsLocked = true }),
            ("com.apple.screenIsUnlocked", { controller in controller.screenIsLocked = false }),
            ("com.apple.screensaver.didstart", { controller in controller.screenSaverIsRunning = true }),
            ("com.apple.screensaver.didstop", { controller in controller.screenSaverIsRunning = false }),
        ]
        for (notificationName, applyStateChange) in stateChangeByNotificationName {
            distributedNotificationObservers.append(DistributedNotificationCenter.default().addObserver(
                forName: NSNotification.Name(notificationName), object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    applyStateChange(self)
                    self.refreshObservation()
                }
            })
        }
    }

    // MARK: - Pointer moves

    private func stopObservingPointer() {
        pointerMovementObserver.stopObserving()
        circleRecognizer.reset()
        hideRing()
    }

    private func hideRing() {
        ringHideAfterStillnessTask?.cancel()
        ringHideAfterStillnessTask = nil
        ringPanelController.hideRingUnlessFiring()
    }

    private func handlePointerMovement(_ observedPointerMovement: ObservedPointerMovement) {
        latestPointerMovementUptime = ProcessInfo.processInfo.systemUptime
        let pointerLocation = observedPointerMovement.topLeftGlobalLocation
        let gestureUpdate = circleRecognizer.feed(
            pointerSample: SummonGesturePointerSample(x: Double(pointerLocation.x), y: Double(pointerLocation.y),
                                                      timestamp: observedPointerMovement.timestampSeconds),
            anyButtonHeld: observedPointerMovement.anyMouseButtonHeld)
        if gestureUpdate.recognized {
            handleRecognizedGesture(atTopLeftGlobalPoint: pointerLocation)
            return
        }
        if gestureUpdate.ringVisible {
            ringPanelController.showRing(atTopLeftGlobalPoint: pointerLocation, progress: min(1, gestureUpdate.progress),
                                         glyphVisible: gestureUpdate.glyphVisible, taskColor: environment.taskColor(),
                                         ringOpacity: gestureUpdate.ringOpacity)
            hideRingOnceThePointerIsStill()
        } else {
            hideRing()
        }
    }

    /// The lock and full-screen state are read again here: eligibility was last read when something changed, and the
    /// pointer may since have moved to a display where a full-screen app runs.
    private func handleRecognizedGesture(atTopLeftGlobalPoint pointerLocation: CGPoint) {
        hideRing()
        let screenIsLockedOrAsleepNow = screenIsLockedOrAsleep || environment.screenIsLockedOrSessionIsInactive()
        let displayUnderPointerIsFullScreen = environment.frontmostApplicationIsFullScreenOnDisplay(pointerLocation)
        let pillOpened = environment.onGestureRecognized(pointerLocation, displayUnderPointerIsFullScreen, screenIsLockedOrAsleepNow)
        guard pillOpened else { return }
        ringPanelController.fireRing(atTopLeftGlobalPoint: pointerLocation, taskColor: environment.taskColor(),
                                     reducesMotion: environment.reducesMotion())
    }

    /// One waiting task per visible ring, not one per move: it sleeps until the pause limit after the latest move and
    /// hides the ring only if no move came in meanwhile.
    private func hideRingOnceThePointerIsStill() {
        guard ringHideAfterStillnessTask == nil else { return }
        ringHideAfterStillnessTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                let stillnessLimitSeconds = self.circleRecognizer.configuration.maximumPauseBetweenSamplesSeconds
                let secondsUntilStill = self.latestPointerMovementUptime + stillnessLimitSeconds - ProcessInfo.processInfo.systemUptime
                if secondsUntilStill <= 0 {
                    self.ringHideAfterStillnessTask = nil
                    self.ringPanelController.hideRingUnlessFiring()
                    return
                }
                try? await Task.sleep(nanoseconds: UInt64(secondsUntilStill * 1_000_000_000) + 1_000_000)
            }
        }
    }
}
