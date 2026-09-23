import AppKit
import ApplicationServices

extension AccessibilityActionBackend {
    func scroll(elementIdentifier: String?, direction: AgentScrollDirection, pages: Int,
                context: ActionRunContext) async throws -> ActionOutcome {
        let scrollTarget: AXUIElement
        let scrollTargetDescription: String
        if let elementIdentifier {
            let (accessibilityElement, node) = try resolveTargetApplicationElement(elementIdentifier, context: context)
            scrollTarget = accessibilityElement
            scrollTargetDescription = describe(node, elementIdentifier: elementIdentifier)
        } else if let taskWindowElement = context.taskWindow?.element {
            scrollTarget = taskWindowElement
            scrollTargetDescription = "the focused window"
        } else {
            throw ActionBackendError.elementNotActionable("\(context.targetApplication.applicationName) has no window to scroll.")
        }
        let deliveryTiers = planTiers(for: .scroll, elementTraits: elementReader.elementInputTraits(of: scrollTarget), context: context)
        guard !deliveryTiers.isEmpty else {
            throw ActionBackendError.inputNotDelivered("scrolling \(scrollTargetDescription) only works with the app in front.",
                                                       foregroundAssistMayHelp: true)
        }
        let scrollFrame = AccessibilityElementReader.frameInTopLeftGlobalPoints(of: scrollTarget)
        try await flyCursor(toCenterOf: scrollFrame, actionKind: .scrolling, context: context)
        let scrollDescription = "scrolled \(direction.rawValue) \(pages) page(s) in \(scrollTargetDescription)"
        for deliveryTier in deliveryTiers {
            try await ensureReadyForInput(context)
            switch deliveryTier {
            case .accessibilityValue:
                if let scrollNote = scrollByScrollBarValue(scrollTarget, direction: direction, pages: pages) {
                    return ActionOutcome(descriptionForModel: scrollDescription + scrollNote, deliveryTier: .accessibilityValue)
                }
            case .processPointerEvents:
                guard let scrollFrame else { continue }
                let changeNote = try await postPointerStepsConfirmingChange(
                    ProcessPointerEventRecipes.scrollSteps(direction: direction, pages: pages,
                                                           targetPointInTopLeftGlobalPoints: ScreenCoordinateConversion.centerOfTopLeftGlobalFrame(scrollFrame)),
                    actionKind: .scroll, targetElement: nil, context: context)
                return ActionOutcome(descriptionForModel: scrollDescription + changeNote, deliveryTier: .processPointerEvents,
                                     noVisibleChangeWasSeen: changeNote == ActionOutcome.noVisibleChangeNote)
            case .accessibilityAction, .processKeyboardEvents, .windowServerKeyboardEvents:
                continue
            }
        }
        throw ActionBackendError.inputNotDelivered("\(scrollTargetDescription) didn't scroll.",
                                                   foregroundAssistMayHelp: !context.targetIsFrontmost)
    }

    /// Moves the scroll bar by the visible fraction per page (0 is the top or left, 1 the bottom or right). Returns a
    /// note for the model, or nil when the scroll bar couldn't be set.
    private func scrollByScrollBarValue(_ scrollTarget: AXUIElement, direction: AgentScrollDirection, pages: Int) -> String? {
        let isVertical = direction == .up || direction == .down
        guard let (scrollBar, scrollArea) = elementReader.settableScrollBar(forScrolling: scrollTarget, isVertical: isVertical),
              let currentValue = AccessibilityElementReader.numberAttribute(kAXValueAttribute, of: scrollBar)?.doubleValue,
              let scrollAreaFrame = AccessibilityElementReader.frameInTopLeftGlobalPoints(of: scrollArea) else { return nil }
        let scrollContent = AccessibilityElementReader.elementArrayAttribute(kAXChildrenAttribute, of: scrollArea)
            .first { AccessibilityElementReader.role(of: $0) != kAXScrollBarRole }
        let contentFrame = scrollContent.flatMap(AccessibilityElementReader.frameInTopLeftGlobalPoints)
        let visibleLength = isVertical ? scrollAreaFrame.height : scrollAreaFrame.width
        let contentLength = contentFrame.map { isVertical ? $0.height : $0.width } ?? visibleLength
        let visibleFraction = contentLength > visibleLength ? visibleLength / contentLength : 1
        let scrollDistance = Double(visibleFraction) * Double(max(1, pages))
        let movesTowardEnd = direction == .down || direction == .right
        let newValue = min(1, max(0, currentValue + (movesTowardEnd ? scrollDistance : -scrollDistance)))
        if newValue == currentValue { return " (it was already at the \(movesTowardEnd ? "end" : "start"))" }
        guard AXUIElementSetAttributeValue(scrollBar, kAXValueAttribute as CFString, NSNumber(value: newValue)) == .success else {
            return nil
        }
        return ""
    }
}
