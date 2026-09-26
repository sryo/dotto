import Foundation
import CoreGraphics

/// Counts, per app process, how many tasks' backends hold its Accessibility modes on. The modes go on with the first
/// hold and come off only with the last release, so one task ending never switches off the modes another task (or a
/// stopped task still unwinding in the same app) relies on.
struct AccessibilityModeHolds: Equatable, Sendable {
    private(set) var holdCountByProcessIdentifier: [Int32: Int] = [:]

    /// Returns true for the first hold on this process: the caller switches its modes on.
    mutating func hold(processIdentifier: Int32) -> Bool {
        let previousHoldCount = holdCountByProcessIdentifier[processIdentifier, default: 0]
        holdCountByProcessIdentifier[processIdentifier] = previousHoldCount + 1
        return previousHoldCount == 0
    }

    /// Returns true when this was the last hold: the caller puts the process's prior values back. A release without a
    /// hold changes nothing and returns false.
    mutating func release(processIdentifier: Int32) -> Bool {
        guard let holdCount = holdCountByProcessIdentifier[processIdentifier] else { return false }
        if holdCount <= 1 {
            holdCountByProcessIdentifier[processIdentifier] = nil
            return true
        }
        holdCountByProcessIdentifier[processIdentifier] = holdCount - 1
        return false
    }

    func isHeld(processIdentifier: Int32) -> Bool {
        holdCountByProcessIdentifier[processIdentifier] != nil
    }

    mutating func releaseAll() {
        holdCountByProcessIdentifier = [:]
    }
}
