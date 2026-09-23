import Foundation

/// The circle summon settings the user actually chose in the menu bar panel, and nothing else. Only these are
/// stored, so every tuning value (window, radii, roundness, reversal limit…) always comes from the current release's
/// defaults and an improved default reaches users who once touched a setting.
struct SummonGestureUserChoices: Codable, Equatable, Sendable {
    var isEnabled: Bool
    var direction: SummonGestureDirection
    var loopsNeeded: Double

    enum CodingKeys: String, CodingKey {
        case isEnabled = "enabled", direction, loopsNeeded
    }

    init(configuration: SummonGestureConfiguration) {
        isEnabled = configuration.isEnabled
        direction = configuration.direction
        loopsNeeded = configuration.loopsNeeded
    }

    /// Missing keys keep the defaults and loops needed is clamped to the settings' range. Any other key is ignored,
    /// so a full configuration stored by an earlier build decodes to just its choices.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SummonGestureConfiguration.standard
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? defaults.isEnabled
        direction = try container.decodeIfPresent(SummonGestureDirection.self, forKey: .direction) ?? defaults.direction
        let decodedLoopsNeeded = try container.decodeIfPresent(Double.self, forKey: .loopsNeeded) ?? defaults.loopsNeeded
        loopsNeeded = decodedLoopsNeeded.isFinite
            ? min(max(decodedLoopsNeeded, SummonGestureConfiguration.loopsNeededRange.lowerBound),
                  SummonGestureConfiguration.loopsNeededRange.upperBound)
            : defaults.loopsNeeded
    }

    /// The defaults with these choices applied.
    var configuration: SummonGestureConfiguration {
        var configuration = SummonGestureConfiguration.standard
        configuration.isEnabled = isEnabled
        configuration.direction = direction
        configuration.loopsNeeded = loopsNeeded
        return configuration
    }
}

/// The user's changes to the default exclusion list, kept as additions and removals rather than a full list, so
/// apps a later release adds to the defaults are excluded for everyone who hasn't removed them. Bundle ids compare
/// case-insensitively and ignoring surrounding whitespace, as in `SummonGestureEligibility`.
struct SummonGestureExclusionAdjustments: Equatable, Sendable {
    var additions: [String] = []
    var removals: [String] = []

    init(additions: [String] = [], removals: [String] = []) {
        self.additions = additions
        self.removals = removals
    }

    /// Derives the adjustments from a full list an earlier build stored.
    init(migratingStoredExcludedBundleIdentifiers storedExcludedBundleIdentifiers: [String],
         defaultExcludedBundleIdentifiers: [String] = SummonGestureEligibility.defaultExcludedBundleIdentifiers) {
        for storedBundleIdentifier in storedExcludedBundleIdentifiers {
            addExclusion(bundleIdentifier: storedBundleIdentifier, defaultExcludedBundleIdentifiers: defaultExcludedBundleIdentifiers)
        }
        for defaultBundleIdentifier in defaultExcludedBundleIdentifiers
        where !SummonGestureEligibility.isExcluded(bundleIdentifier: defaultBundleIdentifier,
                                                   excludedBundleIdentifiers: storedExcludedBundleIdentifiers) {
            removals.append(defaultBundleIdentifier)
        }
    }

    var isEmpty: Bool { additions.isEmpty && removals.isEmpty }

    /// The defaults in their order, minus the removals, then the additions in the order they were added.
    func excludedBundleIdentifiers(
        defaultExcludedBundleIdentifiers: [String] = SummonGestureEligibility.defaultExcludedBundleIdentifiers
    ) -> [String] {
        let keptDefaults = defaultExcludedBundleIdentifiers.filter { defaultBundleIdentifier in
            !SummonGestureEligibility.isExcluded(bundleIdentifier: defaultBundleIdentifier, excludedBundleIdentifiers: removals)
        }
        let newAdditions = additions.filter { addedBundleIdentifier in
            !SummonGestureEligibility.isExcluded(bundleIdentifier: addedBundleIdentifier,
                                                 excludedBundleIdentifiers: defaultExcludedBundleIdentifiers)
        }
        return keptDefaults + newAdditions
    }

    /// Re-adding a removed default undoes the removal; anything else not already listed becomes an addition.
    mutating func addExclusion(bundleIdentifier: String,
                               defaultExcludedBundleIdentifiers: [String] = SummonGestureEligibility.defaultExcludedBundleIdentifiers) {
        let trimmedBundleIdentifier = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBundleIdentifier.isEmpty else { return }
        if SummonGestureEligibility.isExcluded(bundleIdentifier: trimmedBundleIdentifier, excludedBundleIdentifiers: removals) {
            removals.removeAll { removedBundleIdentifier in
                SummonGestureEligibility.isExcluded(bundleIdentifier: removedBundleIdentifier,
                                                    excludedBundleIdentifiers: [trimmedBundleIdentifier])
            }
            return
        }
        let alreadyExcluded = SummonGestureEligibility.isExcluded(
            bundleIdentifier: trimmedBundleIdentifier,
            excludedBundleIdentifiers: excludedBundleIdentifiers(defaultExcludedBundleIdentifiers: defaultExcludedBundleIdentifiers))
        guard !alreadyExcluded else { return }
        additions.append(trimmedBundleIdentifier)
    }

    /// Removing an addition forgets it; removing a default records the removal.
    mutating func removeExclusion(bundleIdentifier: String,
                                  defaultExcludedBundleIdentifiers: [String] = SummonGestureEligibility.defaultExcludedBundleIdentifiers) {
        additions.removeAll { addedBundleIdentifier in
            SummonGestureEligibility.isExcluded(bundleIdentifier: addedBundleIdentifier, excludedBundleIdentifiers: [bundleIdentifier])
        }
        let isDefault = SummonGestureEligibility.isExcluded(bundleIdentifier: bundleIdentifier,
                                                            excludedBundleIdentifiers: defaultExcludedBundleIdentifiers)
        let isAlreadyRemoved = SummonGestureEligibility.isExcluded(bundleIdentifier: bundleIdentifier, excludedBundleIdentifiers: removals)
        if isDefault && !isAlreadyRemoved {
            removals.append(bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
