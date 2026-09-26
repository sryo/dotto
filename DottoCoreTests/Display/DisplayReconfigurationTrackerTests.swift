import Foundation
import CoreGraphics

private let beginFlag = DisplayReconfigurationTracker.ChangeFlag.beginConfiguration

let displayReconfigurationTrackerTestSuite = CoreTestSuite(name: "DisplayReconfigurationTracker", testCases: [
    CoreTestCase(name: "begin callbacks for every display report one began; finished comes after the last display reports") {
        var tracker = DisplayReconfigurationTracker()
        try expectEqual(tracker.handleCallback(displayIdentifier: 1, flags: beginFlag), .began)
        try expectEqual(tracker.handleCallback(displayIdentifier: 2, flags: beginFlag), nil)
        try expectTrue(tracker.isReconfiguring)
        try expectEqual(tracker.handleCallback(displayIdentifier: 1, flags: DisplayReconfigurationTracker.ChangeFlag.setMode), nil)
        try expectEqual(tracker.handleCallback(displayIdentifier: 2, flags: 0), .finished(changedGeometry: true))
        try expectTrue(!tracker.isReconfiguring)
    },
    CoreTestCase(name: "a display that appears without a begin callback finishes a geometry change on its own") {
        var tracker = DisplayReconfigurationTracker()
        try expectEqual(tracker.handleCallback(displayIdentifier: 7, flags: DisplayReconfigurationTracker.ChangeFlag.added),
                        .finished(changedGeometry: true))
    },
    CoreTestCase(name: "a reconfiguration that changed nothing about geometry still finishes, marked as such") {
        var tracker = DisplayReconfigurationTracker()
        _ = tracker.handleCallback(displayIdentifier: 1, flags: beginFlag)
        try expectEqual(tracker.handleCallback(displayIdentifier: 1, flags: 0), .finished(changedGeometry: false))
        // Stray after-change callbacks with nothing in flight and no geometry flags say nothing.
        try expectEqual(tracker.handleCallback(displayIdentifier: 1, flags: 0), nil)
    },
    CoreTestCase(name: "moving the menu bar to another display, mirroring and the desktop shape all count as geometry") {
        for geometryFlag in [DisplayReconfigurationTracker.ChangeFlag.setMain, DisplayReconfigurationTracker.ChangeFlag.mirrored,
                             DisplayReconfigurationTracker.ChangeFlag.desktopShapeChanged, DisplayReconfigurationTracker.ChangeFlag.removed] {
            var tracker = DisplayReconfigurationTracker()
            _ = tracker.handleCallback(displayIdentifier: 3, flags: beginFlag)
            try expectEqual(tracker.handleCallback(displayIdentifier: 3, flags: geometryFlag), .finished(changedGeometry: true),
                            "flag \(geometryFlag)")
        }
    },
])

let primaryDisplayHeightResolutionTestSuite = CoreTestSuite(name: "PrimaryDisplayHeightResolution", testCases: [
    CoreTestCase(name: "the live Quartz height wins when displays are settled") {
        try expectEqual(PrimaryDisplayHeightResolution.resolve(coreGraphicsMainDisplayHeight: 1117, appKitPrimaryScreenHeight: 982,
                                                               lastKnownHeight: 900, displaysAreReconfiguring: false), 1117)
    },
    CoreTestCase(name: "a height of 0 is never used: AppKit, then the last settled height, then nothing") {
        try expectEqual(PrimaryDisplayHeightResolution.resolve(coreGraphicsMainDisplayHeight: 0, appKitPrimaryScreenHeight: 982,
                                                               lastKnownHeight: 900, displaysAreReconfiguring: false), 982)
        try expectEqual(PrimaryDisplayHeightResolution.resolve(coreGraphicsMainDisplayHeight: 0, appKitPrimaryScreenHeight: nil,
                                                               lastKnownHeight: 900, displaysAreReconfiguring: false), 900)
        try expectEqual(PrimaryDisplayHeightResolution.resolve(coreGraphicsMainDisplayHeight: 0, appKitPrimaryScreenHeight: 0,
                                                               lastKnownHeight: 0, displaysAreReconfiguring: false), nil)
    },
    CoreTestCase(name: "mid-reconfiguration the last settled height beats half-applied live values") {
        try expectEqual(PrimaryDisplayHeightResolution.resolve(coreGraphicsMainDisplayHeight: 1440, appKitPrimaryScreenHeight: 1440,
                                                               lastKnownHeight: 982, displaysAreReconfiguring: true), 982)
        try expectEqual(PrimaryDisplayHeightResolution.resolve(coreGraphicsMainDisplayHeight: 1440, appKitPrimaryScreenHeight: nil,
                                                               lastKnownHeight: nil, displaysAreReconfiguring: true), 1440)
    },
    CoreTestCase(name: "the cache ignores heights of 0 or less") {
        let cache = PrimaryDisplayHeightCache()
        cache.recordSettledHeight(982)
        cache.recordSettledHeight(0)
        cache.recordSettledHeight(-5)
        try expectEqual(cache.lastKnownHeight, 982)
    },
])
