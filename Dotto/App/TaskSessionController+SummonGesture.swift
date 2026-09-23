import AppKit

/// Circle to summon: circling the pointer opens the command pill at the pointer, for the app that owns the window
/// under it. Only the user's choices are kept in UserDefaults: on/off, direction and loops needed, and the additions
/// to and removals from the default exclusion list. Every tuning value and the default list come from Core.
extension TaskSessionController {
    private static let summonGestureUserChoicesDefaultsKey = "dottoSummonGesture"
    private static let summonGestureExclusionAdditionsDefaultsKey = "dottoSummonGestureExclusionAdditions"
    private static let summonGestureExclusionRemovalsDefaultsKey = "dottoSummonGestureExclusionRemovals"
    /// Where earlier builds kept the full exclusion list. Read once to migrate, then deleted.
    private static let legacySummonGestureExcludedApplicationsDefaultsKey = "dottoSummonGestureExcludedApps"

    func startSummonGesture() {
        loadSummonGesturePreferences()
        let summonGestureController = SummonGestureController(
            pointerMovementObserver: pointerMovementObserver,
            ringPanelController: SummonGestureRingPanelController(),
            environment: SummonGestureControllerEnvironment(
                configuration: { [weak self] in self?.summonGestureConfiguration ?? .standard },
                excludedBundleIdentifiers: { [weak self] in self?.summonGestureExcludedBundleIdentifiers ?? [] },
                taskIsInProgress: { [weak self] in self?.taskInProgressBlocksSummoning ?? true },
                commandPanelIsOpen: { [weak self] in self?.commandBarPanelController?.isVisible ?? false },
                taskColor: { [weak self] in
                    (self?.cursorStyleConfiguration ?? .standard).taskAccentColor
                },
                reducesMotion: { [weak self] in self?.summonGestureReducesMotion ?? true },
                onGestureRecognized: { [weak self] topLeftGlobalPoint, displayUnderPointerIsFullScreen, screenIsLockedOrAsleep in
                    self?.showCommandPill(atTopLeftGlobalPoint: topLeftGlobalPoint,
                                          displayUnderPointerIsFullScreen: displayUnderPointerIsFullScreen,
                                          screenIsLockedOrAsleep: screenIsLockedOrAsleep) ?? false
                }))
        self.summonGestureController = summonGestureController
        commandBarPanelController?.onVisibilityChanged = { [weak self] in
            self?.summonGestureController?.refreshObservation()
        }
        summonGestureController.start()
    }

    /// The same states in which the summon shortcut shows the checklist instead of the command bar.
    var taskInProgressBlocksSummoning: Bool {
        sessionState.isBusy || isAwaitingApproval || isDemonstrating
    }

    private var summonGestureReducesMotion: Bool {
        cursorStyleConfiguration.reducesMotion(systemReduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    /// The task targets the app under the pointer; over the desktop or no window, the frontmost app, as with the
    /// shortcut. Nothing opens when that app is excluded, blocked or Dotto itself, or when the display under the
    /// pointer is full screen or the screen is locked (`SummonGestureEligibility.allowsSummoning`). The keyboard goes
    /// back to the app that was in front, whichever app the task is for. Returns whether the pill opened.
    @discardableResult
    func showCommandPill(atTopLeftGlobalPoint topLeftGlobalPoint: CGPoint, displayUnderPointerIsFullScreen: Bool,
                         screenIsLockedOrAsleep: Bool) -> Bool {
        guard !taskInProgressBlocksSummoning else { return false }
        let summonedTargetApplication = PointerTargetApplicationResolver.applicationOwningTopmostWindow(atTopLeftGlobalPoint: topLeftGlobalPoint)
            ?? NSWorkspace.shared.frontmostApplication.map { frontmostApplication in
                TargetApplicationReference(processIdentifier: frontmostApplication.processIdentifier,
                                           applicationName: frontmostApplication.localizedName ?? "the frontmost app",
                                           bundleIdentifier: frontmostApplication.bundleIdentifier)
            }
        guard SummonGestureEligibility.allowsSummoning(
            targetApplication: summonedTargetApplication,
            thisAppProcessIdentifier: ProcessInfo.processInfo.processIdentifier,
            thisAppBundleIdentifier: Bundle.main.bundleIdentifier,
            displayUnderPointerIsFullScreen: displayUnderPointerIsFullScreen,
            screenIsLockedOrAsleep: screenIsLockedOrAsleep,
            excludedBundleIdentifiers: summonGestureExcludedBundleIdentifiers) else { return false }
        targetApplication = summonedTargetApplication
        applicationFrontmostWhenCommandBarWasSummoned = NSWorkspace.shared.frontmostApplication
        summonOriginOfNextCommandInTopLeftGlobalPoints = topLeftGlobalPoint
        commandBarPanelController?.showCommandPill(
            atTopLeftGlobalPoint: topLeftGlobalPoint,
            reducesMotion: summonGestureReducesMotion,
            onDismiss: { [weak self] in self?.previousApplicationTracker.handActivationBackIfThisAppIsActive() })
        return true
    }

    // MARK: - Settings

    func updateSummonGestureConfiguration(_ applyChange: (inout SummonGestureConfiguration) -> Void) {
        var updatedConfiguration = summonGestureConfiguration
        applyChange(&updatedConfiguration)
        updatedConfiguration.loopsNeeded = min(max(updatedConfiguration.loopsNeeded, SummonGestureConfiguration.loopsNeededRange.lowerBound),
                                               SummonGestureConfiguration.loopsNeededRange.upperBound)
        // Only the user's choices survive; everything else is the current defaults.
        updatedConfiguration = SummonGestureUserChoices(configuration: updatedConfiguration).configuration
        guard updatedConfiguration != summonGestureConfiguration else { return }
        summonGestureConfiguration = updatedConfiguration
        saveSummonGestureUserChoices(SummonGestureUserChoices(configuration: updatedConfiguration))
        summonGestureController?.configurationDidChange()
    }

    /// The app the user was in before opening the menu bar panel (the panel doesn't activate Dotto, so that is
    /// normally still the frontmost app).
    var summonGestureExclusionCandidate: NSRunningApplication? {
        let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        if let frontmostApplication = NSWorkspace.shared.frontmostApplication,
           frontmostApplication.processIdentifier != ownProcessIdentifier, frontmostApplication.bundleIdentifier != nil {
            return frontmostApplication
        }
        return previousApplicationTracker.lastFrontmostApplicationOtherThanThisApp
    }

    func addSummonGestureExclusion(bundleIdentifier: String) {
        var updatedAdjustments = summonGestureExclusionAdjustments
        updatedAdjustments.addExclusion(bundleIdentifier: bundleIdentifier)
        setSummonGestureExclusionAdjustments(updatedAdjustments)
    }

    func removeSummonGestureExclusion(bundleIdentifier: String) {
        var updatedAdjustments = summonGestureExclusionAdjustments
        updatedAdjustments.removeExclusion(bundleIdentifier: bundleIdentifier)
        setSummonGestureExclusionAdjustments(updatedAdjustments)
    }

    /// Clears both the additions and the removals.
    func resetSummonGestureExclusionsToDefaults() {
        setSummonGestureExclusionAdjustments(SummonGestureExclusionAdjustments())
    }

    private func setSummonGestureExclusionAdjustments(_ exclusionAdjustments: SummonGestureExclusionAdjustments) {
        guard exclusionAdjustments != summonGestureExclusionAdjustments else { return }
        summonGestureExclusionAdjustments = exclusionAdjustments
        saveSummonGestureExclusionAdjustments(exclusionAdjustments)
        summonGestureController?.refreshObservation()
    }

    // MARK: - Storage

    private func saveSummonGestureUserChoices(_ userChoices: SummonGestureUserChoices) {
        if let encodedUserChoices = try? Self.summonGestureUserChoicesEncoder.encode(userChoices) {
            UserDefaults.standard.set(encodedUserChoices, forKey: Self.summonGestureUserChoicesDefaultsKey)
        }
    }

    /// Nothing is stored while the list matches the defaults.
    private func saveSummonGestureExclusionAdjustments(_ exclusionAdjustments: SummonGestureExclusionAdjustments) {
        let userDefaults = UserDefaults.standard
        if exclusionAdjustments.additions.isEmpty {
            userDefaults.removeObject(forKey: Self.summonGestureExclusionAdditionsDefaultsKey)
        } else {
            userDefaults.set(exclusionAdjustments.additions, forKey: Self.summonGestureExclusionAdditionsDefaultsKey)
        }
        if exclusionAdjustments.removals.isEmpty {
            userDefaults.removeObject(forKey: Self.summonGestureExclusionRemovalsDefaultsKey)
        } else {
            userDefaults.set(exclusionAdjustments.removals, forKey: Self.summonGestureExclusionRemovalsDefaultsKey)
        }
    }

    /// Sorted keys, so re-encoding the same choices gives the same bytes and a stored value can be compared.
    private static var summonGestureUserChoicesEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    /// Earlier builds stored the whole configuration under the same key, tuning values included, and the whole
    /// exclusion list under another. Both are migrated here once: the configuration is rewritten as just the choices,
    /// and the list becomes additions and removals on top of the defaults before its key is deleted.
    private func loadSummonGesturePreferences() {
        let userDefaults = UserDefaults.standard
        if let storedUserChoicesData = userDefaults.data(forKey: Self.summonGestureUserChoicesDefaultsKey) {
            if let storedUserChoices = try? JSONDecoder().decode(SummonGestureUserChoices.self, from: storedUserChoicesData) {
                summonGestureConfiguration = storedUserChoices.configuration
                let reencodedUserChoicesData = try? Self.summonGestureUserChoicesEncoder.encode(storedUserChoices)
                if reencodedUserChoicesData != storedUserChoicesData {
                    saveSummonGestureUserChoices(storedUserChoices)
                }
            } else {
                userDefaults.removeObject(forKey: Self.summonGestureUserChoicesDefaultsKey)
            }
        }

        if let legacyExclusionsData = userDefaults.data(forKey: Self.legacySummonGestureExcludedApplicationsDefaultsKey) {
            if let legacyExcludedBundleIdentifiers = try? JSONDecoder().decode([String].self, from: legacyExclusionsData) {
                let migratedAdjustments = SummonGestureExclusionAdjustments(
                    migratingStoredExcludedBundleIdentifiers: legacyExcludedBundleIdentifiers)
                saveSummonGestureExclusionAdjustments(migratedAdjustments)
            }
            userDefaults.removeObject(forKey: Self.legacySummonGestureExcludedApplicationsDefaultsKey)
        }
        summonGestureExclusionAdjustments = SummonGestureExclusionAdjustments(
            additions: userDefaults.stringArray(forKey: Self.summonGestureExclusionAdditionsDefaultsKey) ?? [],
            removals: userDefaults.stringArray(forKey: Self.summonGestureExclusionRemovalsDefaultsKey) ?? [])
    }
}
