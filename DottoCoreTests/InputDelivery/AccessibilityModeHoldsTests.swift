import Foundation
import CoreGraphics

let accessibilityModeHoldsTestSuite = CoreTestSuite(name: "AccessibilityModeHolds", testCases: [
    CoreTestCase(name: "modes go on with the first hold and come off only with the last release") {
        var holds = AccessibilityModeHolds()
        try expectTrue(holds.hold(processIdentifier: 42), "first hold switches the modes on")
        try expectTrue(!holds.hold(processIdentifier: 42), "a second hold on the same app doesn't set them again")
        try expectTrue(!holds.release(processIdentifier: 42), "one holder left")
        try expectTrue(holds.isHeld(processIdentifier: 42))
        try expectTrue(holds.release(processIdentifier: 42), "the last release puts the prior values back")
        try expectTrue(!holds.isHeld(processIdentifier: 42))
    },
    CoreTestCase(name: "apps are counted separately, and a release without a hold does nothing") {
        var holds = AccessibilityModeHolds()
        _ = holds.hold(processIdentifier: 1)
        try expectTrue(holds.hold(processIdentifier: 2))
        try expectTrue(holds.release(processIdentifier: 2))
        try expectTrue(holds.isHeld(processIdentifier: 1), "releasing one app never touches another")
        try expectTrue(!holds.release(processIdentifier: 3))
        holds.releaseAll()
        try expectEqual(holds.holdCountByProcessIdentifier, [:])
    },
])

let inputObservationLeasesTestSuite = CoreTestSuite(name: "InputObservationLeases", testCases: [
    CoreTestCase(name: "the tap stays on while any task holds a lease") {
        var leases = InputObservationLeases()
        try expectEqual(leases.requirement, .none)
        leases.take(holderIdentifier: "run-a", includingPointerMoves: false)
        leases.take(holderIdentifier: "run-b", includingPointerMoves: false)
        leases.end(holderIdentifier: "run-a")
        try expectEqual(leases.requirement, .clicksScrollsAndKeys, "task b still needs takeover detection")
        leases.end(holderIdentifier: "run-b")
        try expectEqual(leases.requirement, .none)
    },
    CoreTestCase(name: "pointer moves are observed only while a demonstration holds a lease") {
        var leases = InputObservationLeases()
        leases.take(holderIdentifier: "run-a", includingPointerMoves: false)
        leases.take(holderIdentifier: "demonstration-b", includingPointerMoves: true)
        try expectEqual(leases.requirement, .includingPointerMoves)
        leases.end(holderIdentifier: "demonstration-b")
        try expectEqual(leases.requirement, .clicksScrollsAndKeys)
        leases.take(holderIdentifier: "run-a", includingPointerMoves: true)
        try expectEqual(leases.requirement, .includingPointerMoves, "taking a lease again replaces it")
        leases.endAll()
        try expectEqual(leases.requirement, .none)
    },
])
