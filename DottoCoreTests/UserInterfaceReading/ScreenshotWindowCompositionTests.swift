import Foundation
import CoreGraphics

private let finderProcessIdentifier: Int32 = 4_242
private let finderListWindow = ScreenshotCandidateWindow(windowIdentifier: 10, ownerProcessIdentifier: finderProcessIdentifier, windowLayer: 0,
                                                         frameInTopLeftGlobalPoints: CGRect(x: 300, y: 80, width: 855, height: 1_074),
                                                         isOnScreen: true)

private func finderWindow(_ windowIdentifier: UInt32, frame: CGRect, layer: Int = 0,
                          ownerProcessIdentifier: Int32 = finderProcessIdentifier) -> ScreenshotCandidateWindow {
    ScreenshotCandidateWindow(windowIdentifier: windowIdentifier, ownerProcessIdentifier: ownerProcessIdentifier, windowLayer: layer,
                              frameInTopLeftGlobalPoints: frame, isOnScreen: true)
}

private func drawnWindowIdentifiers(_ candidateWindows: [ScreenshotCandidateWindow], inFront: Set<UInt32>) -> [UInt32] {
    ScreenshotWindowComposition.windowsToDrawOverTaskWindow(candidateWindows + [finderListWindow], taskWindow: finderListWindow,
                                                            windowIdentifiersInFrontOfTaskWindow: inFront).map(\.windowIdentifier)
}

let screenshotWindowCompositionTestSuite = CoreTestSuite(name: "ScreenshotWindowComposition", testCases: [
    CoreTestCase(name: "a Get Info window behind the list window is not painted over it") {
        let getInfoWindow = finderWindow(20, frame: CGRect(x: 600, y: 500, width: 265, height: 480))
        try expectEqual(drawnWindowIdentifiers([getInfoWindow], inFront: []), [])
        try expectEqual(drawnWindowIdentifiers([getInfoWindow], inFront: [20]), [20])
    },
    CoreTestCase(name: "sheets and menus in front are drawn; other apps' windows and windows elsewhere never are") {
        let renameSheet = finderWindow(30, frame: CGRect(x: 450, y: 110, width: 500, height: 200))
        let openMenu = finderWindow(31, frame: CGRect(x: 700, y: 400, width: 220, height: 300), layer: 101)
        let otherAppWindow = finderWindow(32, frame: CGRect(x: 400, y: 300, width: 600, height: 600), ownerProcessIdentifier: 99)
        let windowOnAnotherDisplay = finderWindow(33, frame: CGRect(x: 3_000, y: 80, width: 800, height: 600))
        try expectEqual(drawnWindowIdentifiers([renameSheet, openMenu, otherAppWindow, windowOnAnotherDisplay], inFront: [30, 31, 32, 33]),
                        [30, 31])
    },
])
