import Foundation

/// A recorded turn ending, independent of whether its working badge was observed.
public struct AgentTurnEnd: Equatable, Sendable {
    public var id: String
    public var worktreePath: String
    public var endedAt: Date
    public var completed: Bool

    public init(id: String, worktreePath: String, endedAt: Date, completed: Bool = true) {
        self.id = id
        self.worktreePath = worktreePath
        self.endedAt = endedAt
        self.completed = completed
    }
}

/// Consumes events even when notifications are off. New projects and app launches
/// start a fresh observation boundary, so browsing old work never replays alerts.
public struct AgentTurnDelivery: Sendable {
    private var watchingSince: [String: Date] = [:]
    private var seen: [String: Date] = [:]

    public init() {}

    public mutating func watch(_ paths: [String], now: Date = Date()) {
        let paths = Set(paths)
        watchingSince = watchingSince.filter { paths.contains($0.key) }
        let boundary = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 * 1_000) / 1_000)
        for path in paths where watchingSince[path] == nil { watchingSince[path] = boundary }
    }

    /// Reenabling notifications discards unscanned endings from the muted
    /// interval. Keep seen identities so already delivered turns stay deduplicated.
    public mutating func resumeObservation(now: Date = Date()) {
        for path in watchingSince.keys { watchingSince[path] = now }
    }

    public mutating func consume(_ events: [AgentTurnEnd], now: Date) -> [AgentTurnEnd] {
        seen = seen.filter { now.timeIntervalSince($0.value) < 86_400 }
        var fresh: [AgentTurnEnd] = []
        for event in events.sorted(by: { $0.endedAt < $1.endedAt }) {
            guard let since = watchingSince[event.worktreePath], event.endedAt >= since,
                  event.endedAt <= now.addingTimeInterval(0.001), now.timeIntervalSince(event.endedAt) < 86_400,
                  seen[event.id] == nil else { continue }
            seen[event.id] = event.endedAt
            fresh.append(event)
        }
        return fresh
    }
}
