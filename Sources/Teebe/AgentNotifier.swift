import AppKit
@preconcurrency import UserNotifications

/// Posts "an agent needs you" notifications. Notification Center requires a real
/// app bundle — an unbundled `swift run` binary would crash inside
/// `UNUserNotificationCenter.current()`, so that path falls back to a beep.
enum AgentNotifier {
    @MainActor static func post(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else {
            NSSound.beep()
            return
        }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            center.add(UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
