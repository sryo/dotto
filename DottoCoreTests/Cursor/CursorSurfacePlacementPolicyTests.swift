import Foundation
import CoreGraphics

private func visibility(onScreen: Bool = true, fraction: Double, pointUnoccluded: Bool? = nil, at uptimeSeconds: TimeInterval) -> TargetWindowVisibility {
    TargetWindowVisibility(isOnScreen: onScreen, visibleFraction: fraction, targetPointIsUnoccluded: pointUnoccluded,
                           observedAtUptimeSeconds: uptimeSeconds)
}

let cursorSurfacePlacementPolicyTestSuite = CoreTestSuite(name: "CursorSurfacePlacementPolicy", testCases: [
    CoreTestCase(name: "the first decision applies at once: overlay when visible, panel when covered, occluded or minimized") {
        var visiblePolicy = CursorSurfacePlacementPolicy()
        try expectEqual(visiblePolicy.surface(for: visibility(fraction: 0.9, at: 0), cursorIsActive: true), .overlayOnTargetWindow)
        var coveredPolicy = CursorSurfacePlacementPolicy()
        try expectEqual(coveredPolicy.surface(for: visibility(fraction: 0.4, at: 0), cursorIsActive: true), .liveViewPanel)
        var occludedPointPolicy = CursorSurfacePlacementPolicy()
        try expectEqual(occludedPointPolicy.surface(for: visibility(fraction: 0.9, pointUnoccluded: false, at: 0), cursorIsActive: true),
                        .liveViewPanel)
        var minimizedPolicy = CursorSurfacePlacementPolicy()
        try expectEqual(minimizedPolicy.surface(for: visibility(onScreen: false, fraction: 1, at: 0), cursorIsActive: true), .liveViewPanel)
    },
    CoreTestCase(name: "an inactive cursor is hidden at once") {
        var policy = CursorSurfacePlacementPolicy()
        _ = policy.surface(for: visibility(fraction: 0.9, at: 0), cursorIsActive: true)
        try expectEqual(policy.surface(for: visibility(fraction: 0.9, at: 0.1), cursorIsActive: false), .hidden)
    },
    CoreTestCase(name: "a switch between surfaces applies only after 0.4 s of agreement") {
        var policy = CursorSurfacePlacementPolicy()
        policy.minimumDwellSeconds = 0
        _ = policy.surface(for: visibility(fraction: 0.9, at: 10), cursorIsActive: true)
        try expectEqual(policy.surface(for: visibility(fraction: 0.2, at: 10.1), cursorIsActive: true), .overlayOnTargetWindow)
        // A flip back within the window cancels the pending switch.
        try expectEqual(policy.surface(for: visibility(fraction: 0.9, at: 10.3), cursorIsActive: true), .overlayOnTargetWindow)
        try expectEqual(policy.surface(for: visibility(fraction: 0.2, at: 10.4), cursorIsActive: true), .overlayOnTargetWindow)
        try expectEqual(policy.surface(for: visibility(fraction: 0.2, at: 10.7), cursorIsActive: true), .overlayOnTargetWindow)
        try expectEqual(policy.surface(for: visibility(fraction: 0.2, at: 10.8), cursorIsActive: true), .liveViewPanel)
        try expectEqual(policy.currentSurface, .liveViewPanel)
    },
    CoreTestCase(name: "hysteresis: the overlay stays down to 0.45 visible, the live view stays up to 0.65") {
        var policy = CursorSurfacePlacementPolicy()
        policy.minimumDwellSeconds = 0
        policy.stabilitySeconds = 0
        try expectEqual(policy.surface(for: visibility(fraction: 0.9, at: 0), cursorIsActive: true), .overlayOnTargetWindow)
        for (index, fraction) in [0.6, 0.5, 0.46, 0.55].enumerated() {
            let uptime = Double(index + 1)
            _ = policy.surface(for: visibility(fraction: fraction, at: uptime), cursorIsActive: true)
            try expectEqual(policy.surface(for: visibility(fraction: fraction, at: uptime + 0.1), cursorIsActive: true),
                            .overlayOnTargetWindow, "fraction \(fraction)")
        }
        _ = policy.surface(for: visibility(fraction: 0.4, at: 10), cursorIsActive: true)
        try expectEqual(policy.surface(for: visibility(fraction: 0.4, at: 10.1), cursorIsActive: true), .liveViewPanel)
        for (index, fraction) in [0.5, 0.6, 0.65].enumerated() {
            let uptime = 20 + Double(index)
            _ = policy.surface(for: visibility(fraction: fraction, at: uptime), cursorIsActive: true)
            try expectEqual(policy.surface(for: visibility(fraction: fraction, at: uptime + 0.1), cursorIsActive: true),
                            .liveViewPanel, "fraction \(fraction)")
        }
        _ = policy.surface(for: visibility(fraction: 0.7, at: 30), cursorIsActive: true)
        try expectEqual(policy.surface(for: visibility(fraction: 0.7, at: 30.1), cursorIsActive: true), .overlayOnTargetWindow)
    },
    CoreTestCase(name: "a surface dwells 1.5 s before switching again, unless the window left the screen") {
        var policy = CursorSurfacePlacementPolicy()
        try expectEqual(policy.surface(for: visibility(fraction: 0.9, at: 100), cursorIsActive: true), .overlayOnTargetWindow)
        _ = policy.surface(for: visibility(fraction: 0.2, at: 100.2), cursorIsActive: true)
        // Stable for 0.4 s, but the overlay has only been up 0.8 s.
        try expectEqual(policy.surface(for: visibility(fraction: 0.2, at: 100.8), cursorIsActive: true), .overlayOnTargetWindow)
        try expectEqual(policy.surface(for: visibility(fraction: 0.2, at: 101.5), cursorIsActive: true), .liveViewPanel)
        // Uncovered again right away: the live view dwells too.
        _ = policy.surface(for: visibility(fraction: 0.9, at: 101.6), cursorIsActive: true)
        try expectEqual(policy.surface(for: visibility(fraction: 0.9, at: 102.2), cursorIsActive: true), .liveViewPanel)
        try expectEqual(policy.surface(for: visibility(fraction: 0.9, at: 103.0), cursorIsActive: true), .overlayOnTargetWindow)
        // Minimized right after: no dwell, only the stability wait.
        _ = policy.surface(for: visibility(onScreen: false, fraction: 1, at: 103.1), cursorIsActive: true)
        try expectEqual(policy.surface(for: visibility(onScreen: false, fraction: 1, at: 103.5), cursorIsActive: true), .liveViewPanel)
    },
    CoreTestCase(name: "visibleFraction for no, half and full occlusion") {
        let windowFrame = CGRect(x: 100, y: 100, width: 400, height: 300)
        try expectEqual(CursorSurfacePlacementPolicy.visibleFraction(of: windowFrame, occludingFrames: []), 1)
        try expectEqual(CursorSurfacePlacementPolicy.visibleFraction(of: windowFrame, occludingFrames: [CGRect(x: 0, y: 0, width: 300, height: 1000)]), 0.5)
        try expectEqual(CursorSurfacePlacementPolicy.visibleFraction(of: windowFrame, occludingFrames: [CGRect(x: 0, y: 0, width: 300, height: 1000),
                                                                                                         CGRect(x: 300, y: 0, width: 500, height: 1000)]), 0)
        try expectEqual(CursorSurfacePlacementPolicy.visibleFraction(of: .zero, occludingFrames: []), 0)
    },
])
