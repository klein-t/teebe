import Foundation

/// Installs teebe's ping hook into Claude Code's user settings, and names the
/// darwin-notification channel both sides share.
///
/// The hook is push instead of poll: Claude Code runs `notifyutil -p` at the
/// moments teebe cares about, so the app can idle in the background (no FSEvents
/// stream over `~/.claude/projects`, no fast poll) and still badge/notify the
/// instant an agent finishes. `notifyutil` is a stock macOS binary; the ping
/// carries no payload and costs microseconds.
public enum ClaudeHookInstaller {
    /// The darwin-notification channel (`notifyutil -p <channel>`).
    public static let channel = "dev.teebe.agent"
    public static let pingCommand = "notifyutil -p \(channel)"
    /// Hook events that mark the transitions teebe surfaces: the turn ending
    /// (Stop), the agent asking for the user (Notification), and the user
    /// answering (UserPromptSubmit — clears a "needs you" badge promptly).
    public static let events = ["Stop", "Notification", "UserPromptSubmit"]

    public static var defaultSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    public enum InstallError: Error {
        /// The settings file exists but is not valid JSON — refuse to touch it.
        case unreadableSettings
    }

    /// Whether every event already carries the teebe ping.
    public static func isInstalled(in settings: [String: Any]) -> Bool {
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        return events.allSatisfy { event in
            ((hooks[event] as? [[String: Any]]) ?? []).contains(where: groupHasPing)
        }
    }

    /// A copy of `settings` with the ping hook merged into every event that lacks
    /// it, preserving all other keys and existing hooks. nil when fully installed.
    public static func settingsInstallingPing(into settings: [String: Any]) -> [String: Any]? {
        guard !isInstalled(in: settings) else { return nil }
        var result = settings
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            guard !groups.contains(where: groupHasPing) else { continue }
            groups.append(["hooks": [["type": "command", "command": pingCommand]]])
            hooks[event] = groups
        }
        result["hooks"] = hooks
        return result
    }

    public static func isInstalled(at url: URL = defaultSettingsURL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return false }
        return isInstalled(in: json)
    }

    /// Merge the ping hook into the settings file, creating it when absent.
    /// Returns false when it was already fully installed. A file that exists but
    /// can't be parsed as a JSON object throws and is left byte-for-byte intact.
    @discardableResult
    public static func install(at url: URL = defaultSettingsURL) throws -> Bool {
        var settings: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { throw InstallError.unreadableSettings }
            settings = json
        }
        guard let merged = settingsInstallingPing(into: settings) else { return false }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: merged, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        return true
    }

    private static func groupHasPing(_ group: [String: Any]) -> Bool {
        ((group["hooks"] as? [[String: Any]]) ?? [])
            .contains { ($0["command"] as? String)?.contains(channel) == true }
    }
}

// MARK: - Ping listener

/// Listens for the darwin notification the Claude Code hook pings.
public protocol AgentPingListening {
    func start(_ handler: @escaping @Sendable () -> Void)
    func stop()
}

/// Live listener on the darwin notify center — kernel-delivered, no polling, no
/// file descriptors held open. (`notify_register_dispatch` isn't exposed to
/// Swift; the CF darwin center receives the same `notifyutil -p` posts.)
public final class DarwinAgentPingListener: AgentPingListening, @unchecked Sendable {
    private let name: String
    private var handler: (@Sendable () -> Void)?
    private var isObserving = false

    public init(name: String = ClaudeHookInstaller.channel) {
        self.name = name
    }

    deinit { stop() }

    public func start(_ handler: @escaping @Sendable () -> Void) {
        stop()
        self.handler = handler
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        // C callback — no captures allowed; recover self from the observer pointer.
        CFNotificationCenterAddObserver(center, observer, { _, observer, _, _, _ in
            guard let observer else { return }
            let listener = Unmanaged<DarwinAgentPingListener>.fromOpaque(observer).takeUnretainedValue()
            listener.handler?()
        }, name as CFString, nil, .deliverImmediately)
        isObserving = true
    }

    public func stop() {
        guard isObserving else { return }
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterRemoveEveryObserver(center, Unmanaged.passUnretained(self).toOpaque())
        isObserving = false
        handler = nil
    }
}
