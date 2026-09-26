import Foundation
import CoreGraphics

/// Turns Quartz's per-display reconfiguration callbacks into one "began" and one "finished" per reconfiguration.
/// Quartz calls once per online display with only the begin flag before a change, then once per added, removed and
/// online display without it after the change, when every CoreGraphics value is already up to date.
struct DisplayReconfigurationTracker: Equatable, Sendable {
    /// CGDisplayChangeSummaryFlags bits, as Quartz defines them.
    enum ChangeFlag {
        static let beginConfiguration: UInt32 = 1 << 0
        static let moved: UInt32 = 1 << 1
        static let setMain: UInt32 = 1 << 2
        static let setMode: UInt32 = 1 << 3
        static let added: UInt32 = 1 << 4
        static let removed: UInt32 = 1 << 5
        static let enabled: UInt32 = 1 << 8
        static let disabled: UInt32 = 1 << 9
        static let mirrored: UInt32 = 1 << 10
        static let unmirrored: UInt32 = 1 << 11
        static let desktopShapeChanged: UInt32 = 1 << 12
    }

    enum Update: Equatable, Sendable {
        case began
        /// `changedGeometry` is true when displays moved, appeared, went away, changed mode, main display or
        /// mirroring: anything that moves where windows and panels belong.
        case finished(changedGeometry: Bool)
    }

    private static let geometryChangingFlags = ChangeFlag.moved | ChangeFlag.setMain | ChangeFlag.setMode | ChangeFlag.added
        | ChangeFlag.removed | ChangeFlag.enabled | ChangeFlag.disabled | ChangeFlag.mirrored | ChangeFlag.unmirrored
        | ChangeFlag.desktopShapeChanged

    private(set) var displaysAwaitingTheirChange: Set<UInt32> = []
    private(set) var isReconfiguring = false
    private var accumulatedFlags: UInt32 = 0

    /// Returns an update only when the reconfiguration starts or when its last awaited display has reported.
    mutating func handleCallback(displayIdentifier: UInt32, flags: UInt32) -> Update? {
        if flags & ChangeFlag.beginConfiguration != 0 {
            displaysAwaitingTheirChange.insert(displayIdentifier)
            guard !isReconfiguring else { return nil }
            isReconfiguring = true
            accumulatedFlags = 0
            return .began
        }
        accumulatedFlags |= flags
        displaysAwaitingTheirChange.remove(displayIdentifier)
        // A display that was just added reports without a begin callback; the change is over once nobody is awaited.
        guard displaysAwaitingTheirChange.isEmpty else { return nil }
        let changedGeometry = accumulatedFlags & Self.geometryChangingFlags != 0
        let wasReconfiguring = isReconfiguring
        isReconfiguring = false
        accumulatedFlags = 0
        return wasReconfiguring || changedGeometry ? .finished(changedGeometry: changedGeometry) : nil
    }
}
