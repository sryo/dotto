import AppKit
import ApplicationServices

extension AccessibilityActionBackend {
    private static let changePollIntervalNanoseconds: UInt64 = 100_000_000
    private static let changePollCount = 8

    func postPointerStepsConfirmingChange(_ pointerSteps: [ProcessPointerEventStep], actionKind: InputActionKind,
                                          targetElement: AXUIElement?, context: ActionRunContext) async throws -> String {
        // Pointer events are only ever posted with the target in front, whatever the planner says.
        guard context.targetIsFrontmost, context.taskWindow != nil,
              let pointerTargetPoint = pointerSteps.first?.locationInTopLeftGlobalPoints else {
            throw ActionBackendError.inputNotDelivered("a pointer event only works with the app in front.", foregroundAssistMayHelp: true)
        }
        try await ensureReadyForInput(context)
        // Sheets, popovers, menus and web pop-ups (a <select> list) are windows of their own. A per-process event has
        // no hit test, so it must name the window that is really under the point and use that window's origin.
        guard let pointerTargetWindow = WindowListEntryClassification.frontmostWindow(
                ownedBy: context.targetApplication.processIdentifier, containingTopLeftGlobalPoint: pointerTargetPoint),
              let targetProcessPin = TargetProcessPin(processIdentifier: context.targetApplication.processIdentifier,
                                                      windowIdentifier: pointerTargetWindow.windowIdentifier) else {
            throw ActionBackendError.elementNotActionable(
                "no window of \(context.targetApplication.applicationName) is under that point. Read the UI or take a new screenshot first.")
        }
        let pointerConfirmation = InputTierPlanner.deliveryConfirmation(
            for: .processPointerEvents, actionKind: actionKind, targetIsFrontmost: context.targetIsFrontmost)
        return try await performConfirmingChange(targetElement: targetElement, confirmation: pointerConfirmation, context: context) {
            try await self.inputSynthesizer.postPointerEvents(
                pointerSteps, to: targetProcessPin, windowFrameInTopLeftGlobalPoints: pointerTargetWindow.frameInTopLeftGlobalPoints,
                abortSignal: context.abortSignal,
                verifyBeforeEachPressOrMove: { try await self.ensureReadyForInput(context) })
        }
    }

    /// Fingerprints before and after, polling up to 800 ms. The window thumbnail is only compared when every AX
    /// signal is unchanged. What a missing change means comes from `InputTierPlanner.deliveryConfirmation`.
    func performConfirmingChange(targetElement: AXUIElement?, confirmation: DeliveryConfirmation,
                                 context: ActionRunContext,
                                 postInput: () async throws -> Void) async throws -> String {
        if confirmation == .tierConfirmsItself {
            try await postInput()
            return ""
        }
        let fingerprintBefore = await changeFingerprintIncludingWindowImage(targetElement: targetElement, context: context)
        try await postInput()
        for _ in 0..<Self.changePollCount {
            try await Task.sleep(nanoseconds: Self.changePollIntervalNanoseconds)
            try throwIfRunEnded(context)
            let fingerprintAfter = elementReader.changeFingerprint(of: context.targetApplication, targetElement: targetElement)
            if UserInterfaceChangeFingerprint.showsObservableChange(from: fingerprintBefore, to: fingerprintAfter) { return "" }
        }
        let fingerprintAfter = await changeFingerprintIncludingWindowImage(targetElement: targetElement, context: context)
        if UserInterfaceChangeFingerprint.showsObservableChange(from: fingerprintBefore, to: fingerprintAfter) { return "" }
        guard confirmation == .visibleChangeNoted else {
            throw ActionBackendError.inputNotDelivered("nothing visibly changed in \(context.targetApplication.applicationName).",
                                                       foregroundAssistMayHelp: true)
        }
        return ActionOutcome.noVisibleChangeNote
    }

    private func changeFingerprintIncludingWindowImage(targetElement: AXUIElement?,
                                                       context: ActionRunContext) async -> UserInterfaceChangeFingerprint {
        var changeFingerprint = elementReader.changeFingerprint(of: context.targetApplication, targetElement: targetElement)
        if let taskWindowReference = context.taskWindow?.reference {
            changeFingerprint.windowImageThumbnail = await windowCapturer.captureThumbnail(of: taskWindowReference)
        }
        return changeFingerprint
    }
}
