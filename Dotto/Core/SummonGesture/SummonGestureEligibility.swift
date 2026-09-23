import Foundation

/// When pointer moves may be fed to the circle recognizer at all, and whether a recognized circle may open the pill.
/// Outside these conditions Dotto observes nothing.
enum SummonGestureEligibility {
    /// Apps where circling the pointer is ordinary work (drawing, design, 3D, game engines) or where games run.
    /// Games launched through Steam have their own bundle ids and can't be listed; most run full screen, which is
    /// excluded anyway. The user edits this list in the menu bar panel.
    static let defaultExcludedBundleIdentifiers: [String] = [
        "com.figma.Desktop",
        "com.bohemiancoding.sketch3",
        "com.adobe.Photoshop",
        "com.adobe.illustrator",
        "com.adobe.InDesign",
        "com.seriflabs.affinitydesigner",
        "com.seriflabs.affinityphoto",
        "com.seriflabs.affinitydesigner2",
        "com.seriflabs.affinityphoto2",
        "com.pixelmatorteam.pixelmator.x",
        "org.kde.krita",
        "org.blenderfoundation.blender",
        "com.unity3d.UnityEditor5.x",
        "com.valvesoftware.steam",
    ]

    /// `screenIsLockedOrAsleep` covers the lock screen, the screen saver, sleeping displays and a session switched
    /// out by fast user switching: the user isn't at this desktop, so nothing is observed.
    static func allowsObservation(gestureEnabled: Bool,
                                  taskIsRunning: Bool,
                                  commandPillIsOpen: Bool,
                                  frontmostApplicationBundleIdentifier: String?,
                                  frontmostApplicationIsFullScreen: Bool,
                                  screenIsLockedOrAsleep: Bool,
                                  excludedBundleIdentifiers: [String]) -> Bool {
        guard gestureEnabled, !taskIsRunning, !commandPillIsOpen, !frontmostApplicationIsFullScreen, !screenIsLockedOrAsleep else {
            return false
        }
        guard let frontmostApplicationBundleIdentifier else { return true }
        return !isExcluded(bundleIdentifier: frontmostApplicationBundleIdentifier, excludedBundleIdentifiers: excludedBundleIdentifiers)
    }

    /// The last check when a circle is recognized. Observation follows the frontmost app, but the pill is for the app
    /// under the pointer, which may be excluded, blocked (`TargetApplicationPolicy`) or Dotto itself. The screen may
    /// also have locked or gone full screen since eligibility was last read. A nil target (nothing under the pointer
    /// and no frontmost app) has nothing to summon for.
    static func allowsSummoning(targetApplication: TargetApplicationReference?,
                                thisAppProcessIdentifier: Int32,
                                thisAppBundleIdentifier: String?,
                                displayUnderPointerIsFullScreen: Bool,
                                screenIsLockedOrAsleep: Bool,
                                excludedBundleIdentifiers: [String]) -> Bool {
        guard let targetApplication, !displayUnderPointerIsFullScreen, !screenIsLockedOrAsleep else { return false }
        guard targetApplication.processIdentifier != thisAppProcessIdentifier else { return false }
        if let thisAppBundleIdentifier, let targetBundleIdentifier = targetApplication.bundleIdentifier,
           normalizedBundleIdentifier(targetBundleIdentifier) == normalizedBundleIdentifier(thisAppBundleIdentifier) {
            return false
        }
        guard !TargetApplicationPolicy.isBlockedTargetApplication(targetApplication) else { return false }
        guard let targetBundleIdentifier = targetApplication.bundleIdentifier else { return true }
        return !isExcluded(bundleIdentifier: targetBundleIdentifier, excludedBundleIdentifiers: excludedBundleIdentifiers)
    }

    /// Bundle ids compare case-insensitively and ignore surrounding whitespace, since the user types the list.
    static func isExcluded(bundleIdentifier: String, excludedBundleIdentifiers: [String]) -> Bool {
        let normalizedCandidateBundleIdentifier = normalizedBundleIdentifier(bundleIdentifier)
        return excludedBundleIdentifiers.contains { excludedBundleIdentifier in
            normalizedBundleIdentifier(excludedBundleIdentifier) == normalizedCandidateBundleIdentifier
        }
    }

    static func normalizedBundleIdentifier(_ bundleIdentifier: String) -> String {
        bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
