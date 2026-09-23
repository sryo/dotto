import AppKit

/// Calling the user over without taking focus: the cursor pill or the live view's docked pill carry the question,
/// and a sound, the menu bar icon and (optionally) a system notification point the user to it. Every answer,
/// wherever it was clicked, goes through the same path as the checklist card. Also the persisted cursor and
/// attention preferences.
extension TaskSessionController {
    private static let attentionPreferencesDefaultsKey = "dottoAttentionPreferences"
    private static let liveViewCornerDefaultsKey = "dottoLiveViewCorner"
    /// The owner's "Copy settings for the Swift port" JSON from the cursor lab, pasted with
    /// `defaults write com.sryo.dotto dottoCursorStyleJSON '<json>'`.
    private static let cursorStyleJSONDefaultsKey = "dottoCursorStyleJSON"

    func startAttentionDelivery() {
        loadAttentionAndCursorPreferences()
        cursorController.onDecisionOptionChosen = { [weak self] userDecisionAnswer in
            self?.answerUserDecision(userDecisionAnswer)
        }
        cursorController.onAttentionRequestChanged = { [weak self] attentionRequest in
            self?.deliverAttention(for: attentionRequest)
        }
        cursorController.onAttentionNudge = { [weak self] unansweredAttentionRequest in
            guard let self, self.attentionDeliveryChannels(for: unansweredAttentionRequest).playsSound else { return }
            AttentionChime.play(for: unansweredAttentionRequest.kind)
        }
        attentionNotificationPoster.onDecisionOptionChosen = { [weak self] decisionOptionIdentifier, attentionRequestIdentifier in
            self?.answerUserDecision(UserDecisionAnswer(optionIdentifier: decisionOptionIdentifier,
                                                        attentionRequestIdentifier: attentionRequestIdentifier))
        }
        attentionNotificationPoster.onNotificationOpened = { [weak self] in
            // Opening Dotto's notification activates Dotto; show the panel and hand activation straight back to the
            // app the user was in (a bare deactivate lets macOS pick one, possibly the target).
            self?.checklistPanelController?.showChecklistPanel(makeKey: false)
            self?.previousApplicationTracker.handActivationBackOnceThisAppIsActive()
        }
    }

    // MARK: - Answers

    /// The one entry point for answers from the cursor pill, the live view and notification actions. Every answer
    /// carries the request it was given for and is dropped once that request is no longer the pending one
    /// (answered elsewhere, or the run moved on or stopped); see UserDecisionAnswerPolicy.
    func answerUserDecision(_ userDecisionAnswer: UserDecisionAnswer) {
        let pendingAttentionRequestIdentifier = cursorController.viewModel.presentationState.attentionRequest?.requestIdentifier
        guard UserDecisionAnswerPolicy.accepts(userDecisionAnswer, pendingAttentionRequestIdentifier: pendingAttentionRequestIdentifier) else {
            return
        }
        let decisionOptionIdentifier = userDecisionAnswer.optionIdentifier
        if decisionOptionIdentifier == .cancel {
            cancelForegroundAssistCountdown()
            return
        }
        switch sessionState {
        case .awaitingSafetyConfirmation:
            guard let safetyConfirmationAnswer = SafetyConfirmationAnswer(decisionOptionIdentifier: decisionOptionIdentifier) else { return }
            answerPendingSafetyConfirmation(safetyConfirmationAnswer)
        case .awaitingItemFailureDecision:
            guard let itemFailureDecision = ChecklistItemFailureDecision(decisionOptionIdentifier: decisionOptionIdentifier) else { return }
            answerPendingItemFailureDecision(itemFailureDecision)
        case .paused:
            if decisionOptionIdentifier == .resume { resumeTask() }
            if decisionOptionIdentifier == .stop { stopTask() }
        case .executing:
            if decisionOptionIdentifier == .pause { pauseTask() }
            if decisionOptionIdentifier == .stop { stopTask() }
        case .planning:
            if decisionOptionIdentifier == .stop { stopTask() }
        default:
            break
        }
    }

    // MARK: - Delivery

    private func deliverAttention(for attentionRequest: UserAttentionRequest?) {
        attentionNotificationPoster.withdrawAll(exceptRequestIdentifier: attentionRequest?.requestIdentifier)
        guard let attentionRequest else {
            isMenuBarIconPulsing = false
            return
        }
        let deliveryChannels = attentionDeliveryChannels(for: attentionRequest)
        isMenuBarIconPulsing = deliveryChannels.pulsesMenuBarIcon && attentionRequest.kind != .finished
        if deliveryChannels.playsSound {
            AttentionChime.play(for: attentionRequest.kind)
        }
        if deliveryChannels.postsNotification {
            attentionNotificationPoster.post(attentionRequest,
                                             targetApplicationName: targetApplication?.applicationName ?? "the app")
        }
    }

    private func attentionDeliveryChannels(for attentionRequest: UserAttentionRequest) -> AttentionDeliveryChannels {
        let frontmostProcessIdentifier = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let targetOrThisAppIsFrontmost = frontmostProcessIdentifier == ProcessInfo.processInfo.processIdentifier
            || (frontmostProcessIdentifier != nil && frontmostProcessIdentifier == targetApplication?.processIdentifier)
        return attentionPreferences.deliveryChannels(for: attentionRequest, targetOrThisAppIsFrontmost: targetOrThisAppIsFrontmost)
    }

    // MARK: - Preferences

    func updateAttentionPreferences(_ updatePreferences: (inout AttentionPreferences) -> Void) {
        updatePreferences(&attentionPreferences)
        if let encodedPreferences = try? JSONEncoder().encode(attentionPreferences) {
            UserDefaults.standard.set(encodedPreferences, forKey: Self.attentionPreferencesDefaultsKey)
        }
        if !attentionPreferences.menuBarPulseEnabled { isMenuBarIconPulsing = false }
        if attentionPreferences.notificationsEnabled { attentionNotificationPoster.requestAuthorizationIfNeeded() }
    }

    func updateLiveViewCorner(_ newLiveViewCorner: ScreenCorner) {
        liveViewCorner = newLiveViewCorner
        cursorController.liveViewCorner = newLiveViewCorner
        UserDefaults.standard.set(newLiveViewCorner.rawValue, forKey: Self.liveViewCornerDefaultsKey)
    }

    private func loadAttentionAndCursorPreferences() {
        if let storedPreferencesData = UserDefaults.standard.data(forKey: Self.attentionPreferencesDefaultsKey),
           let storedPreferences = try? JSONDecoder().decode(AttentionPreferences.self, from: storedPreferencesData) {
            attentionPreferences = storedPreferences
        }
        if let storedCornerName = UserDefaults.standard.string(forKey: Self.liveViewCornerDefaultsKey),
           let storedCorner = ScreenCorner(rawValue: storedCornerName) {
            liveViewCorner = storedCorner
        }
        cursorController.liveViewCorner = liveViewCorner
        if let ownerCursorStyleJSON = UserDefaults.standard.string(forKey: Self.cursorStyleJSONDefaultsKey),
           let ownerCursorStyle = try? CursorStyleConfiguration.decodingOwnerJSON(Data(ownerCursorStyleJSON.utf8)) {
            cursorStyleConfiguration = ownerCursorStyle
        }
        cursorController.styleConfiguration = cursorStyleConfiguration
    }
}
