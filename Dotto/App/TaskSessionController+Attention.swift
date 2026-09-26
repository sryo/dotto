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

    /// Each task's cursor carries its own questions; what the user answers there goes back to that task.
    func wireAttentionDelivery(for session: TaskSession) {
        session.cursorController.liveViewCorner = liveViewCorner
        session.cursorController.styleConfiguration = styleConfiguration(for: session)
        // Resume, Pause, Stop and Cancel carry no request; the pill they were clicked on says whose they are.
        session.cursorController.onDecisionOptionChosen = { [weak self, weak session] userDecisionAnswer in
            guard let self, let session else { return }
            self.withSession(session) { self.answerUserDecisionInCurrentSession(userDecisionAnswer) }
        }
        session.cursorController.onAttentionRequestChanged = { [weak self, weak session] attentionRequest in
            guard let self, let session else { return }
            self.withSession(session) { self.deliverAttention(for: attentionRequest) }
        }
        session.cursorController.onAttentionNudge = { [weak self, weak session] unansweredAttentionRequest in
            guard let self, let session,
                  self.withSession(session, { self.attentionDeliveryChannels(for: unansweredAttentionRequest).playsSound }) else { return }
            AttentionChime.play(for: unansweredAttentionRequest.kind)
        }
    }

    // MARK: - Answers

    /// Answers from notification actions: the request they name says which task they belong to. An answer whose
    /// request no session holds any more is dropped.
    func answerUserDecision(_ userDecisionAnswer: UserDecisionAnswer) {
        guard let answeringSession = session(owningAttentionRequestIdentifier: userDecisionAnswer.attentionRequestIdentifier) else { return }
        withSession(answeringSession) { answerUserDecisionInCurrentSession(userDecisionAnswer) }
    }

    /// The one path for every answer, from the cursor pill, the live view or a notification. Every answer carries
    /// the request it was given for and is dropped once that request is no longer the pending one (answered
    /// elsewhere, or the run moved on or stopped); see UserDecisionAnswerPolicy.
    private func answerUserDecisionInCurrentSession(_ userDecisionAnswer: UserDecisionAnswer) {
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
        for session in sessions { session.cursorController.liveViewCorner = newLiveViewCorner }
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
        if let ownerCursorStyleJSON = UserDefaults.standard.string(forKey: Self.cursorStyleJSONDefaultsKey),
           let ownerCursorStyle = try? CursorStyleConfiguration.decodingOwnerJSON(Data(ownerCursorStyleJSON.utf8)) {
            cursorStyleConfiguration = ownerCursorStyle
        }
    }
}
