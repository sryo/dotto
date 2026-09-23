import Foundation

private let defaults = ["com.figma.Desktop", "com.adobe.Photoshop", "org.kde.krita"]

let summonGesturePreferenceModelsTestSuite = CoreTestSuite(name: "SummonGesture preferences", testCases: [
    CoreTestCase(name: "only enabled, direction and loops needed are stored") {
        var configuration = SummonGestureConfiguration.standard
        configuration.isEnabled = false
        configuration.direction = .either
        configuration.loopsNeeded = 2
        let encodedData = try JSONEncoder().encode(SummonGestureUserChoices(configuration: configuration))
        let encodedObject = try unwrapOrFail(try JSONSerialization.jsonObject(with: encodedData) as? [String: Any])
        try expectEqual(Set(encodedObject.keys), ["enabled", "direction", "loopsNeeded"])
        try expectEqual(try JSONDecoder().decode(SummonGestureUserChoices.self, from: encodedData).configuration, configuration)
    },
    CoreTestCase(name: "tuning values always come from the defaults, even when an earlier build stored them") {
        let storedFullConfiguration = #"{"enabled":true,"direction":"counterClockwise","loopsNeeded":2.5,"windowSeconds":0.6,"roundnessTolerance":0.7,"maximumReversalFraction":0.4,"minimumRadiusPoints":12}"#
        let choices = try JSONDecoder().decode(SummonGestureUserChoices.self, from: Data(storedFullConfiguration.utf8))
        try expectEqual(choices.direction, .counterClockwise)
        try expectEqual(choices.loopsNeeded, 2.5)
        var expected = SummonGestureConfiguration.standard
        expected.direction = .counterClockwise
        expected.loopsNeeded = 2.5
        try expectEqual(choices.configuration, expected)
        let reencodedObject = try unwrapOrFail(try JSONSerialization.jsonObject(with: try JSONEncoder().encode(choices)) as? [String: Any])
        try expectEqual(reencodedObject.count, 3, "the migrated value drops the tuning keys")
    },
    CoreTestCase(name: "missing choices keep the defaults and loops needed is clamped") {
        try expectEqual(try JSONDecoder().decode(SummonGestureUserChoices.self, from: Data("{}".utf8)).configuration, .standard)
        try expectEqual(try JSONDecoder().decode(SummonGestureUserChoices.self, from: Data(#"{"loopsNeeded":9}"#.utf8)).loopsNeeded, 2.5)
        try expectEqual(try JSONDecoder().decode(SummonGestureUserChoices.self, from: Data(#"{"loopsNeeded":0}"#.utf8)).loopsNeeded, 1.0)
    },
    CoreTestCase(name: "no adjustments means exactly the defaults") {
        let adjustments = SummonGestureExclusionAdjustments()
        try expectTrue(adjustments.isEmpty)
        try expectEqual(adjustments.excludedBundleIdentifiers(defaultExcludedBundleIdentifiers: defaults), defaults)
        try expectEqual(adjustments.excludedBundleIdentifiers(), SummonGestureEligibility.defaultExcludedBundleIdentifiers)
    },
    CoreTestCase(name: "adding and removing record only the difference from the defaults") {
        var adjustments = SummonGestureExclusionAdjustments()
        adjustments.addExclusion(bundleIdentifier: "  com.example.Paint ", defaultExcludedBundleIdentifiers: defaults)
        adjustments.addExclusion(bundleIdentifier: "COM.EXAMPLE.PAINT", defaultExcludedBundleIdentifiers: defaults)
        adjustments.addExclusion(bundleIdentifier: "com.figma.desktop", defaultExcludedBundleIdentifiers: defaults)
        adjustments.addExclusion(bundleIdentifier: "   ", defaultExcludedBundleIdentifiers: defaults)
        try expectEqual(adjustments.additions, ["com.example.Paint"])
        try expectEqual(adjustments.removals, [])
        adjustments.removeExclusion(bundleIdentifier: "com.adobe.Photoshop", defaultExcludedBundleIdentifiers: defaults)
        adjustments.removeExclusion(bundleIdentifier: "com.adobe.photoshop", defaultExcludedBundleIdentifiers: defaults)
        try expectEqual(adjustments.removals, ["com.adobe.Photoshop"])
        try expectEqual(adjustments.excludedBundleIdentifiers(defaultExcludedBundleIdentifiers: defaults),
                        ["com.figma.Desktop", "org.kde.krita", "com.example.Paint"])
        adjustments.addExclusion(bundleIdentifier: "com.adobe.Photoshop", defaultExcludedBundleIdentifiers: defaults)
        try expectEqual(adjustments.removals, [], "re-adding a default undoes its removal")
        adjustments.removeExclusion(bundleIdentifier: "com.example.Paint", defaultExcludedBundleIdentifiers: defaults)
        try expectEqual(adjustments.additions, [])
        try expectTrue(adjustments.isEmpty)
    },
    CoreTestCase(name: "a default added in a later release reaches users who adjusted the list") {
        let adjustments = SummonGestureExclusionAdjustments(additions: ["com.example.Paint"], removals: ["com.adobe.Photoshop"])
        let laterDefaults = defaults + ["com.example.NewDrawingApp"]
        try expectEqual(adjustments.excludedBundleIdentifiers(defaultExcludedBundleIdentifiers: laterDefaults),
                        ["com.figma.Desktop", "org.kde.krita", "com.example.NewDrawingApp", "com.example.Paint"])
        let laterDefaultsAdoptingTheAddition = defaults + ["com.example.paint"]
        try expectEqual(adjustments.excludedBundleIdentifiers(defaultExcludedBundleIdentifiers: laterDefaultsAdoptingTheAddition),
                        ["com.figma.Desktop", "org.kde.krita", "com.example.paint"], "no duplicate once the default covers it")
    },
    CoreTestCase(name: "a full list stored by an earlier build migrates to additions and removals") {
        let storedList = ["com.figma.Desktop", "ORG.KDE.KRITA", "com.example.Paint", "com.example.paint"]
        let migrated = SummonGestureExclusionAdjustments(migratingStoredExcludedBundleIdentifiers: storedList,
                                                         defaultExcludedBundleIdentifiers: defaults)
        try expectEqual(migrated.additions, ["com.example.Paint"])
        try expectEqual(migrated.removals, ["com.adobe.Photoshop"])
        let unchanged = SummonGestureExclusionAdjustments(migratingStoredExcludedBundleIdentifiers: defaults,
                                                          defaultExcludedBundleIdentifiers: defaults)
        try expectTrue(unchanged.isEmpty)
        let emptied = SummonGestureExclusionAdjustments(migratingStoredExcludedBundleIdentifiers: [], defaultExcludedBundleIdentifiers: defaults)
        try expectEqual(emptied.removals, defaults)
        try expectEqual(emptied.excludedBundleIdentifiers(defaultExcludedBundleIdentifiers: defaults), [])
    },
])
