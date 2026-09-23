import AppKit
import ApplicationServices

/// Walks the planned tiers for each action: an AX error moves to the next tier; an event that may have landed is
/// confirmed through the change fingerprint, and is never silently retried, because a retry could toggle something
/// twice.
extension AccessibilityActionBackend {
    func clickElement(_ elementIdentifier: String, clickType: AgentClickType, context: ActionRunContext) async throws -> ActionOutcome {
        let (accessibilityElement, node) = try resolveTargetApplicationElement(elementIdentifier, context: context)
        let elementDescription = describe(node, elementIdentifier: elementIdentifier)
        let elementFrame = AccessibilityElementReader.frameInTopLeftGlobalPoints(of: accessibilityElement) ?? node?.frameInTopLeftGlobalPoints
        var elementTraits = elementReader.elementInputTraits(of: accessibilityElement)
        let elementRole = node?.role ?? AccessibilityElementReader.role(of: accessibilityElement) ?? ""
        // InputTierPlanner already keeps menu-opening presses for the assist; this re-check on the live role also
        // covers traits that were read before the element changed.
        if !context.targetIsFrontmost && (clickType == .right || AccessibilityElementReader.menuOpeningRoles.contains(elementRole)) {
            elementTraits.supportsPressAction = false
            elementTraits.supportsShowMenuAction = false
        }
        // A single click on a text input only puts the caret in it. In the background that is done by focusing it
        // through Accessibility, and type_text then replaces or appends its text, so no app has to come forward.
        if !context.targetIsFrontmost, clickType == .single, Self.textInputRoles.contains(elementRole),
           node?.isSecureTextField != true, !elementReader.isSecureTextField(accessibilityElement) {
            try await flyCursor(toCenterOf: elementFrame, actionKind: Self.cursorActionKind(for: clickType), context: context)
            try await ensureReadyForInput(context)
            if (try? inputSynthesizer.focusAccessibilityElement(accessibilityElement, abortSignal: context.abortSignal)) != nil {
                return ActionOutcome(
                    descriptionForModel: "focused \(elementDescription). A background click can't place the caret at a point: "
                        + "use type_text on this element to replace its whole text (replace_existing_text true) or to add at the end",
                    deliveryTier: .accessibilityAction)
            }
        }
        let deliveryTiers = planTiers(for: .click(clickType), elementTraits: elementTraits, context: context)
        guard !deliveryTiers.isEmpty else {
            throw ActionBackendError.inputNotDelivered(
                "\(elementDescription) needs a real \(clickType.rawValue) click, which only works with the app in front.",
                foregroundAssistMayHelp: true)
        }
        try await flyCursor(toCenterOf: elementFrame, actionKind: Self.cursorActionKind(for: clickType), context: context)
        for deliveryTier in deliveryTiers {
            switch deliveryTier {
            case .accessibilityAction:
                let accessibilityActionName = clickType == .right ? kAXShowMenuAction : kAXPressAction
                try await ensureReadyForInput(context)
                let actionDescription = clickType == .right ? "opened the context menu of" : "pressed"
                switch try inputSynthesizer.attemptAccessibilityAction(accessibilityActionName, on: accessibilityElement,
                                                                       abortSignal: context.abortSignal) {
                case .performed:
                    return ActionOutcome(descriptionForModel: "\(actionDescription) \(elementDescription)", deliveryTier: .accessibilityAction)
                case .mayHaveActed:
                    // No other tier is tried: if the press did act (often by opening a dialog), a second one would act twice.
                    return ActionOutcome(descriptionForModel: "\(actionDescription) \(elementDescription)"
                                            + Self.mayHaveActedNoteForModel(applicationName: context.targetApplication.applicationName),
                                         deliveryTier: .accessibilityAction)
                case .refused:
                    continue
                }
            case .processPointerEvents:
                guard let elementFrame else { continue }
                let pointerSteps = ProcessPointerEventRecipes.clickSteps(
                    clickType: clickType, targetPointInTopLeftGlobalPoints: ScreenCoordinateConversion.centerOfTopLeftGlobalFrame(elementFrame))
                let changeNote = try await postPointerStepsConfirmingChange(pointerSteps, actionKind: .click(clickType),
                                                                            targetElement: accessibilityElement, context: context)
                return ActionOutcome(descriptionForModel: "\(clickType.rawValue)-clicked \(elementDescription)\(changeNote)",
                                     deliveryTier: .processPointerEvents,
                                     noVisibleChangeWasSeen: changeNote == ActionOutcome.noVisibleChangeNote)
            case .accessibilityValue, .processKeyboardEvents, .windowServerKeyboardEvents:
                continue
            }
        }
        throw ActionBackendError.inputNotDelivered("\(elementDescription) didn't respond to Dotto's \(clickType.rawValue) click.",
                                                   foregroundAssistMayHelp: !context.targetIsFrontmost)
    }

    static let textInputRoles: Set<String> = [kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String]

    func clickScreenshotPoint(_ screenshotPixelPoint: CGPoint, clickType: AgentClickType, context: ActionRunContext) async throws -> ActionOutcome {
        guard let latestScreenshot else { throw ActionBackendError.noScreenshotForPixelCoordinates }
        guard ScreenCoordinateConversion.isScreenshotPixelInsideImage(screenshotPixelPoint, in: latestScreenshot) else {
            throw ActionBackendError.elementNotActionable(
                "(\(Int(screenshotPixelPoint.x)), \(Int(screenshotPixelPoint.y))) is outside the \(latestScreenshot.pixelWidth)x\(latestScreenshot.pixelHeight) screenshot.")
        }
        // The pixel is relative to the captured window; the click uses that window's frame as it is now.
        guard let taskWindow = context.taskWindow,
              taskWindow.reference.windowIdentifier == latestScreenshot.capturedWindow.windowIdentifier else {
            throw ActionBackendError.elementNotActionable("the window changed since the last screenshot. Take a new screenshot first.")
        }
        // A resized window reflows its content, so the pixel no longer shows what the model saw there.
        let capturedWindowSize = latestScreenshot.capturedWindow.frameInTopLeftGlobalPoints.size
        let currentWindowSize = taskWindow.reference.frameInTopLeftGlobalPoints.size
        guard abs(capturedWindowSize.width - currentWindowSize.width) < 1, abs(capturedWindowSize.height - currentWindowSize.height) < 1 else {
            throw ActionBackendError.elementNotActionable(
                "the window was resized since the last screenshot, so that pixel may show something else now. Take a new screenshot first.")
        }
        let windowRelativePoint = ScreenCoordinateConversion.windowRelativePoint(fromScreenshotPixel: screenshotPixelPoint, in: latestScreenshot)
        let topLeftGlobalPoint = ScreenCoordinateConversion.topLeftGlobalPoint(
            fromWindowRelativePoint: windowRelativePoint, windowFrameInTopLeftGlobalPoints: taskWindow.reference.frameInTopLeftGlobalPoints)
        guard taskWindow.reference.frameInTopLeftGlobalPoints.contains(topLeftGlobalPoint) else {
            throw ActionBackendError.elementNotActionable("that point is outside \(context.targetApplication.applicationName)'s window.")
        }
        let pointDescription = "screenshot pixel (\(Int(screenshotPixelPoint.x)), \(Int(screenshotPixelPoint.y)))"
            + (elementDescription(atTopLeftGlobalPoint: topLeftGlobalPoint, context: context).map { " on \($0)" } ?? "")
        guard planTiers(for: .clickScreenshotPoint, elementTraits: nil, context: context).contains(.processPointerEvents) else {
            throw ActionBackendError.inputNotDelivered("a click at \(pointDescription) only works with the app in front.",
                                                       foregroundAssistMayHelp: true)
        }
        try await flyCursor(toTopLeftGlobalPoint: topLeftGlobalPoint, actionKind: clickType == .double ? .doubleClick : .click,
                            context: context)
        let changeNote = try await postPointerStepsConfirmingChange(
            ProcessPointerEventRecipes.clickSteps(clickType: clickType, targetPointInTopLeftGlobalPoints: topLeftGlobalPoint),
            actionKind: .clickScreenshotPoint, targetElement: nil, context: context)
        return ActionOutcome(descriptionForModel: "\(clickType.rawValue)-clicked \(pointDescription)\(changeNote)",
                             deliveryTier: .processPointerEvents, noVisibleChangeWasSeen: changeNote == ActionOutcome.noVisibleChangeNote)
    }

    private static func cursorActionKind(for clickType: AgentClickType) -> CursorActionKind {
        switch clickType {
        case .single: .click
        case .double: .doubleClick
        case .right: .rightClick
        }
    }

    /// Only describes what is under the point for the model; the target app's hit test is not a refusal.
    private func elementDescription(atTopLeftGlobalPoint topLeftGlobalPoint: CGPoint, context: ActionRunContext) -> String? {
        let applicationElement = AccessibilityElementReader.makeApplicationElement(for: context.targetApplication.processIdentifier)
        guard let elementAtPoint = AccessibilityElementReader.element(atTopLeftGlobalPoint: topLeftGlobalPoint, in: applicationElement),
              let elementRole = AccessibilityElementReader.role(of: elementAtPoint) else { return nil }
        let elementName = [kAXTitleAttribute, kAXDescriptionAttribute]
            .compactMap { AccessibilityElementReader.stringAttribute($0, of: elementAtPoint) }.first
        return Self.roleNameLabel(role: elementRole, subrole: AccessibilityElementReader.stringAttribute(kAXSubroleAttribute, of: elementAtPoint),
                                  displayedName: elementName)
    }
}
