import Foundation

/// Shared macOS signal transport. Any agent integration can publish this signal;
/// the bundled settings installer below currently targets Claude Code.
///
/// The hook is push instead of poll: Claude Code runs `notifyutil -p` at the
/// moments teebe cares about, so the app can idle in the background (no FSEvents
/// stream over `~/.claude/projects`, no fast poll) and still badge/notify the
/// instant an agent finishes. `notifyutil` is a stock macOS binary; the ping
/// carries no payload and costs microseconds.
public enum AgentSignal {
    public static let channel = "dev.teebe.agent"
    public static let command = "/usr/bin/notifyutil -p \(channel)"
}

public enum ClaudeHookInstaller {
    /// The darwin-notification channel (`notifyutil -p <channel>`).
    public static let channel = AgentSignal.channel
    public static let pingCommand = AgentSignal.command
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
        /// Existing hook configuration cannot be merged without losing data.
        case invalidHooks
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

    /// Global Claude hook disabling is separate from whether our commands exist.
    public static func hooksDisabled(at url: URL = defaultSettingsURL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return false }
        return json["disableAllHooks"] as? Bool == true
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
        try validateHooks(in: settings)
        guard let merged = settingsInstallingPing(into: settings) else { return false }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: merged, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        return true
    }

    /// Refuse unexpected shapes instead of replacing an existing configuration
    /// with empty defaults. Unknown events and keys are preserved verbatim.
    private static func validateHooks(in settings: [String: Any]) throws {
        guard let rawHooks = settings["hooks"] else { return }
        guard let hooks = rawHooks as? [String: Any] else { throw InstallError.invalidHooks }
        for event in events {
            guard let rawGroups = hooks[event] else { continue }
            guard let groups = rawGroups as? [[String: Any]] else { throw InstallError.invalidHooks }
            for group in groups {
                if let rawCommands = group["hooks"], rawCommands as? [[String: Any]] == nil {
                    throw InstallError.invalidHooks
                }
            }
        }
    }

    private static func groupHasPing(_ group: [String: Any]) -> Bool {
        let matcher = group["matcher"] as? String ?? ""
        guard matcher.isEmpty || matcher == "*" else { return false }
        return ((group["hooks"] as? [[String: Any]]) ?? []).contains { hook in
            guard hook["type"] as? String == "command", let command = hook["command"] as? String else { return false }
            let normalized = command.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return normalized == pingCommand || normalized == "notifyutil -p \(channel)"
        }
    }
}

// MARK: - Ping listener

/// Listens for the shared Darwin notification published by an agent integration.
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

    public init(name: String = AgentSignal.channel) {
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
