import Foundation
import CoreGraphics

let readUserInterfaceBudgetTestSuite = CoreTestSuite(name: "ReadUserInterfaceBudget", testCases: [
    CoreTestCase(name: "Cocoa and web budgets") {
        try expectEqual(ReadUserInterfaceBudget.budget(for: .cocoa),
                        ReadUserInterfaceBudget(maximumNodeCount: 3000, maximumDepth: 40, maximumWalkSeconds: 2.5,
                                                prunesWebContentFarOutsideWindow: false))
        for webKind in [TargetApplicationKind.chromiumBrowser, .electron, .webKitBrowser] {
            try expectEqual(ReadUserInterfaceBudget.budget(for: webKind),
                            ReadUserInterfaceBudget(maximumNodeCount: 2500, maximumDepth: 60, maximumWalkSeconds: 3.0,
                                                    prunesWebContentFarOutsideWindow: true), webKind.rawValue)
        }
    },
    CoreTestCase(name: "exactly one window height away is inside; beyond it is far outside") {
        let windowFrame = CGRect(x: 0, y: 100, width: 800, height: 600)
        try expectTrue(!ReadUserInterfaceBudget.isFrameFarOutsideWindow(CGRect(x: 0, y: 1300, width: 50, height: 20), windowFrame: windowFrame))
        try expectTrue(ReadUserInterfaceBudget.isFrameFarOutsideWindow(CGRect(x: 0, y: 1301, width: 50, height: 20), windowFrame: windowFrame))
        try expectTrue(!ReadUserInterfaceBudget.isFrameFarOutsideWindow(CGRect(x: 0, y: -520, width: 50, height: 20), windowFrame: windowFrame))
        try expectTrue(ReadUserInterfaceBudget.isFrameFarOutsideWindow(CGRect(x: 0, y: -521, width: 50, height: 20), windowFrame: windowFrame))
        try expectTrue(!ReadUserInterfaceBudget.isFrameFarOutsideWindow(CGRect(x: 0, y: 300, width: 50, height: 20), windowFrame: windowFrame))
    },
])
