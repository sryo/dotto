import AppKit

/// Several tasks whose windows are covered each have a live view in the same corner: one is expanded and the others are
/// chips stacked past it (`LiveViewStack`). Toggling a chip expands it and collapses the one that was expanded.
extension TaskSessionController {
    func wireLiveViewStacking(for session: TaskSession) {
        let sessionIdentifier = session.sessionIdentifier
        session.cursorController.onSurfaceChanged = { [weak self] shownSurface in
            guard let self else { return }
            if shownSurface == .liveViewPanel {
                self.liveViewStack.show(sessionIdentifier)
            } else {
                self.liveViewStack.hide(sessionIdentifier)
            }
            self.applyLiveViewStack()
        }
        session.cursorController.onLiveViewCollapseToggleRequested = { [weak self] in
            guard let self else { return }
            self.liveViewStack.toggle(sessionIdentifier)
            self.applyLiveViewStack()
        }
        session.cursorController.onLiveViewSizeChange = { [weak self] in
            self?.applyLiveViewStackOffsets()
        }
    }

    private func applyLiveViewStack() {
        for session in sessions where liveViewStack.shownIdentifiersInOrder.contains(session.sessionIdentifier) {
            session.cursorController.setLiveViewCollapsed(liveViewStack.isCollapsed(session.sessionIdentifier))
        }
        applyLiveViewStackOffsets()
    }

    private func applyLiveViewStackOffsets() {
        var cardHeightsInPoints: [String: CGFloat] = [:]
        for session in sessions {
            cardHeightsInPoints[session.sessionIdentifier] = session.cursorController.liveViewCardHeightIfShown
        }
        let stackOffsets = liveViewStack.stackOffsetsInPoints(heightsInPoints: cardHeightsInPoints)
        for session in sessions {
            session.cursorController.liveViewStackOffsetInPoints = stackOffsets[session.sessionIdentifier] ?? 0
        }
    }
}
