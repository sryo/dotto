import AppKit
import UserNotifications

/// Optional system notifications for UserAttentionRequest. Action buttons answer in the background (no
/// `.foreground` option), so answering from Notification Center never activates Dotto or any other app.
@MainActor
final class UserAttentionNotificationPoster: NSObject, UNUserNotificationCenterDelegate {
    /// (the chosen option, the attention request it answers)
    var onDecisionOptionChosen: ((UserDecisionOptionIdentifier, String) -> Void)?
    var onNotificationOpened: (() -> Void)?

    nonisolated private static let attentionRequestIdentifierUserInfoKey = "attentionRequestIdentifier"
    private var authorizationWasRequested = false
    private var registeredCategoriesByIdentifier: [String: UNNotificationCategory] = [:]
    private var postedRequestIdentifiers: Set<String> = []

    private var notificationCenter: UNUserNotificationCenter { UNUserNotificationCenter.current() }

    override init() {
        super.init()
        // Set at launch so an action tapped on a notification from an earlier moment still reaches Dotto.
        UNUserNotificationCenter.current().delegate = self
    }

    /// Asked lazily: the first time the user turns notifications on or Dotto first needs to post one.
    func requestAuthorizationIfNeeded() {
        guard !authorizationWasRequested else { return }
        authorizationWasRequested = true
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }
    }

    func post(_ attentionRequest: UserAttentionRequest, targetApplicationName: String) {
        guard !postedRequestIdentifiers.contains(attentionRequest.requestIdentifier) else { return }
        requestAuthorizationIfNeeded()
        postedRequestIdentifiers.insert(attentionRequest.requestIdentifier)

        let notificationContent = UNMutableNotificationContent()
        notificationContent.title = attentionRequest.title
        notificationContent.subtitle = "Dotto · \(targetApplicationName)"
        notificationContent.body = attentionRequest.bodyText
        notificationContent.userInfo = [Self.attentionRequestIdentifierUserInfoKey: attentionRequest.requestIdentifier]
        // Dotto plays its own chime (or stays silent) per the sound preference.
        notificationContent.sound = nil
        if !attentionRequest.decisionOptions.isEmpty {
            notificationContent.categoryIdentifier = registerCategory(for: attentionRequest.decisionOptions)
        }
        let notificationRequest = UNNotificationRequest(identifier: attentionRequest.requestIdentifier,
                                                        content: notificationContent, trigger: nil)
        Task { @MainActor [weak self] in
            // Authorization may still be pending on first use; the system queues or drops the request accordingly.
            try? await self?.notificationCenter.add(notificationRequest)
        }
    }

    /// Removes delivered notifications for requests answered elsewhere, keeping the ones still pending (one per task
    /// at most).
    func withdrawAll(exceptRequestIdentifiers keptRequestIdentifiers: Set<String>) {
        let withdrawnRequestIdentifiers = postedRequestIdentifiers.subtracting(keptRequestIdentifiers)
        guard !withdrawnRequestIdentifiers.isEmpty else { return }
        postedRequestIdentifiers.subtract(withdrawnRequestIdentifiers)
        notificationCenter.removeDeliveredNotifications(withIdentifiers: Array(withdrawnRequestIdentifiers))
        notificationCenter.removePendingNotificationRequests(withIdentifiers: Array(withdrawnRequestIdentifiers))
    }

    /// One category per distinct set of options ("allow-allowRestOfTask-skip-stop"), with one button per option.
    private func registerCategory(for decisionOptions: [UserDecisionOption]) -> String {
        let categoryIdentifier = "dotto." + decisionOptions.map(\.identifier.rawValue).joined(separator: "-")
        guard registeredCategoriesByIdentifier[categoryIdentifier] == nil else { return categoryIdentifier }
        let notificationActions = decisionOptions.map { decisionOption in
            UNNotificationAction(identifier: decisionOption.identifier.rawValue, title: decisionOption.title,
                                 options: decisionOption.identifier == .stop ? [.destructive] : [])
        }
        registeredCategoriesByIdentifier[categoryIdentifier] = UNNotificationCategory(
            identifier: categoryIdentifier, actions: notificationActions, intentIdentifiers: [], options: [])
        notificationCenter.setNotificationCategories(Set(registeredCategoriesByIdentifier.values))
        return categoryIdentifier
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let actionIdentifier = response.actionIdentifier
        let attentionRequestIdentifier = response.notification.request.content.userInfo[Self.attentionRequestIdentifierUserInfoKey] as? String
        await MainActor.run {
            if actionIdentifier == UNNotificationDefaultActionIdentifier {
                self.onNotificationOpened?()
            } else if let decisionOptionIdentifier = UserDecisionOptionIdentifier(rawValue: actionIdentifier),
                      let attentionRequestIdentifier {
                self.onDecisionOptionChosen?(decisionOptionIdentifier, attentionRequestIdentifier)
            }
        }
    }
}
