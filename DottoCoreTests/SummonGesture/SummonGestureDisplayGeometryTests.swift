import CoreGraphics
import Foundation

private let primaryDisplay = CGRect(x: 0, y: 0, width: 1440, height: 900)
private let displayToTheRight = CGRect(x: 1440, y: 0, width: 1920, height: 1080)

let summonGestureDisplayGeometryTestSuite = CoreTestSuite(name: "SummonGestureDisplayGeometry", testCases: [
    CoreTestCase(name: "the pointer's display counts its right and bottom edges") {
        let displays = [primaryDisplay, displayToTheRight]
        try expectEqual(SummonGestureDisplayGeometry.indexOfDisplay(containing: CGPoint(x: 700, y: 400), displayFrames: displays), 0)
        try expectEqual(SummonGestureDisplayGeometry.indexOfDisplay(containing: CGPoint(x: 700, y: 900), displayFrames: displays), 0,
                        "the bottom row")
        try expectEqual(SummonGestureDisplayGeometry.indexOfDisplay(containing: CGPoint(x: 3360, y: 1080), displayFrames: displays), 1,
                        "the far corner")
        try expectEqual(SummonGestureDisplayGeometry.indexOfDisplay(containing: CGPoint(x: 1440, y: 100), displayFrames: displays), 1,
                        "a shared edge goes to the display the point is inside")
        try expectEqual(SummonGestureDisplayGeometry.indexOfDisplay(containing: CGPoint(x: 700, y: 901), displayFrames: displays), nil)
    },
    CoreTestCase(name: "a window covering the whole display is full screen; a maximized one below the menu bar isn't") {
        try expectTrue(SummonGestureDisplayGeometry.largestWindowCoversDisplay(displayFrame: primaryDisplay,
                                                                               applicationWindowFrames: [primaryDisplay]))
        try expectEqual(SummonGestureDisplayGeometry.largestWindowCoversDisplay(
            displayFrame: primaryDisplay, applicationWindowFrames: [CGRect(x: 0, y: 25, width: 1440, height: 875)]), false)
        try expectEqual(SummonGestureDisplayGeometry.largestWindowCoversDisplay(displayFrame: primaryDisplay, applicationWindowFrames: []),
                        false)
    },
    CoreTestCase(name: "a small palette in front doesn't decide it: the largest window on the display does") {
        let palette = CGRect(x: 100, y: 100, width: 240, height: 300)
        try expectTrue(SummonGestureDisplayGeometry.largestWindowCoversDisplay(displayFrame: primaryDisplay,
                                                                               applicationWindowFrames: [palette, primaryDisplay]))
        try expectEqual(SummonGestureDisplayGeometry.largestWindowCoversDisplay(
            displayFrame: primaryDisplay, applicationWindowFrames: [palette, CGRect(x: 50, y: 60, width: 900, height: 700)]), false)
    },
    CoreTestCase(name: "a full-screen video on another display doesn't make this display full screen") {
        let windowedDocumentHere = CGRect(x: 200, y: 100, width: 800, height: 600)
        try expectEqual(SummonGestureDisplayGeometry.largestWindowCoversDisplay(
            displayFrame: primaryDisplay, applicationWindowFrames: [displayToTheRight, windowedDocumentHere]), false)
        try expectTrue(SummonGestureDisplayGeometry.largestWindowCoversDisplay(
            displayFrame: displayToTheRight, applicationWindowFrames: [displayToTheRight, windowedDocumentHere]))
    },
])
