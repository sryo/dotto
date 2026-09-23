import Foundation
import CoreGraphics

let cursorFixtureTargetWindow = TargetWindowReference(processIdentifier: 500, windowIdentifier: 31,
                                                      frameInTopLeftGlobalPoints: CGRect(x: 0, y: 0, width: 800, height: 600))

/// The cursor state after the mapper has seen these events in order.
func cursorState(after events: [CursorActivityEvent], from initialState: CursorPresentationState = .hidden) -> CursorPresentationState {
    events.reduce(initialState) { CursorPresentationStateMapper.nextState(from: $0, on: $1) }
}
