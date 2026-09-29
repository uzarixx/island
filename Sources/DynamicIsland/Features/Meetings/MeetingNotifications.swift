import AppKit
import UserNotifications

/// Meeting reminders as macOS notifications: shows them even though the app counts as "in the
/// foreground", and opens the meeting link from the notification or its "Подключиться" button.
final class MeetingNotifications: NSObject, UNUserNotificationCenterDelegate {
    func register() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let join = UNNotificationAction(identifier: MeetingStore.joinAction, title: L("Подключиться", "Join"), options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: MeetingStore.notificationCategory, actions: [join], intentIdentifiers: []),
        ])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let isJoin = response.actionIdentifier == UNNotificationDefaultActionIdentifier
            || response.actionIdentifier == MeetingStore.joinAction
        if isJoin,
           let link = response.notification.request.content.userInfo["link"] as? String,
           let url = URL(string: link), !link.isEmpty {
            NSWorkspace.shared.open(url)
        }
        completionHandler()
    }
}
