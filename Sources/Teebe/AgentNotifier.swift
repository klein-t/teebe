import AppKit
@preconcurrency import UserNotifications

/// Notification Center needs a real bundle. Tests inject a notification sink;
/// the Settings test checks the OS permission and reports delivery errors.
enum AgentNotifier {
    @MainActor static var soundEnabled = true

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
                    completion(error == nil ? "Sent to Notification Center. Focus may silence the banner." : "macOS couldn’t deliver the notification.")
                }
            }
        }
    }
}
