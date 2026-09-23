import Foundation
import CoreGraphics

/// Web apps expose huge trees, so their walks get their own limits and skip content far outside the window.
struct ReadUserInterfaceBudget: Equatable, Sendable {
    var maximumNodeCount: Int
    var maximumDepth: Int
    var maximumWalkSeconds: TimeInterval
    var prunesWebContentFarOutsideWindow: Bool

    static func budget(for applicationKind: TargetApplicationKind) -> ReadUserInterfaceBudget {
        switch applicationKind {
        case .cocoa:
            return ReadUserInterfaceBudget(maximumNodeCount: 3000, maximumDepth: 40, maximumWalkSeconds: 2.5,
                                           prunesWebContentFarOutsideWindow: false)
        case .chromiumBrowser, .electron, .webKitBrowser:
            return ReadUserInterfaceBudget(maximumNodeCount: 2500, maximumDepth: 60, maximumWalkSeconds: 3.0,
                                           prunesWebContentFarOutsideWindow: true)
        }
    }

    /// A web node whose frame lies more than one window height above or below the window is not descended into.
    static func isFrameFarOutsideWindow(_ elementFrame: CGRect, windowFrame: CGRect) -> Bool {
        elementFrame.maxY < windowFrame.minY - windowFrame.height || elementFrame.minY > windowFrame.maxY + windowFrame.height
    }
}
