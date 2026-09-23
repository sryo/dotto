import Foundation
import CoreGraphics

private func isClose(_ firstValue: Double, _ secondValue: Double, tolerance: Double = 0.0001) -> Bool { abs(firstValue - secondValue) <= tolerance }

let cursorFlightPathTestSuite = CoreTestSuite(name: "CursorFlightPath", testCases: [
    CoreTestCase(name: "the flight starts and ends exactly on its end points") {
        let flightPath = CursorFlightPath(startPoint: CGPoint(x: 10, y: 20), endPoint: CGPoint(x: 700, y: 400))
        try expectEqual(flightPath.point(atLinearProgress: 0), CGPoint(x: 10, y: 20))
        try expectEqual(flightPath.point(atLinearProgress: 1), CGPoint(x: 700, y: 400))
        try expectEqual(flightPath.point(atLinearProgress: 1.5), CGPoint(x: 700, y: 400))
    },
    CoreTestCase(name: "the duration is clamped to 0.3…0.8 s, scaled by speed, and 0 for no distance") {
        try expectTrue(isClose(CursorFlightPath(startPoint: .zero, endPoint: CGPoint(x: 100, y: 0)).durationSeconds, 0.3))
        try expectTrue(isClose(CursorFlightPath(startPoint: .zero, endPoint: CGPoint(x: 700, y: 0)).durationSeconds, 0.5))
        try expectTrue(isClose(CursorFlightPath(startPoint: .zero, endPoint: CGPoint(x: 5000, y: 0)).durationSeconds, 0.8))
        try expectTrue(isClose(CursorFlightPath(startPoint: .zero, endPoint: CGPoint(x: 700, y: 0), motionSpeed: 2).durationSeconds, 0.25))
        try expectEqual(CursorFlightPath(startPoint: CGPoint(x: 3, y: 3), endPoint: CGPoint(x: 3.5, y: 3)).durationSeconds, 0)
    },
    CoreTestCase(name: "the arc lifts toward the top of the screen, whichever way the flight goes") {
        let rightwardFlight = CursorFlightPath(startPoint: .zero, endPoint: CGPoint(x: 400, y: 0))
        try expectTrue(rightwardFlight.point(atLinearProgress: 0.5).y < 0, "\(rightwardFlight.point(atLinearProgress: 0.5))")
        let leftwardFlight = CursorFlightPath(startPoint: CGPoint(x: 400, y: 0), endPoint: .zero)
        try expectTrue(leftwardFlight.point(atLinearProgress: 0.5).y < 0, "\(leftwardFlight.point(atLinearProgress: 0.5))")
        // The arc height is capped at 70 points; the midpoint of the eased curve sits halfway to the control point.
        let longFlight = CursorFlightPath(startPoint: .zero, endPoint: CGPoint(x: 2000, y: 0))
        try expectTrue(isClose(Double(longFlight.point(atLinearProgress: 0.5).y), -35))
    },
])
