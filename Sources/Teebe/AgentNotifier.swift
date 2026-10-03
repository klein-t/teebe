import AppKit
@preconcurrency import UserNotifications

/// Notification Center needs a real bundle. Tests inject a notification sink;
/// the Settings test checks the OS permission and reports delivery errors.
enum AgentNotifier {
    @MainActor static var soundEnabled = true
    /// macOS hides a notification when its app is frontmost unless the app says
    /// otherwise; agent notices matter just as much while Teebe is in front.
    static let foregroundPresentation: UNNotificationPresentationOptions = [.banner, .sound, .list]
    /// Notification Center keeps only a weak reference to its delegate.
    private static let presenter = ForegroundPresenter()

    /// Call before launch finishes, so a notification arriving at launch is covered.
    @MainActor static func showWhileFrontmost() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().delegate = presenter
    }

    @MainActor static func post(title: String, body: String) {
        post(title: title, body: body, completion: { _ in })
    }

    @MainActor static func post(title: String, body: String, completion: @escaping @MainActor (String) -> Void) {
        guard Bundle.main.bundleIdentifier != nil else {
            completion("Notifications need the packaged app.")
            return
        }
        let sound = soundEnabled
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else {
                Task { @MainActor in completion("Notifications are off in macOS. Open Notification Settings to allow them.") }
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = sound ? .default : nil
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { error in
                Task { @MainActor in
                    completion(error == nil ? "Sent. A banner should appear now; if not, check Teebe in Notification Settings." : "macOS couldn’t deliver the notification.")
                }
            }
        }
    }
}

private final class ForegroundPresenter: NSObject, UNUserNotificationCenterDelegate, Sendable {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(AgentNotifier.foregroundPresentation)
    }
}
