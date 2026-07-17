import Foundation

/// What an AI coding agent (a Claude Code session) is doing in a worktree,
/// derived from the session logs under `~/.claude/projects`.
public enum AgentActivityState: String, Equatable, Sendable {
    /// A session is mid-turn: the model is thinking or running tools.
    case working
    /// The turn ended (final assistant text) or the session stalled — the agent
    /// is waiting on the user.
    case needsAttention
    /// No session, or the newest one has been silent long enough to ignore.
    case idle
}

/// Time windows for interpreting the last session entry.
public struct AgentStatusThresholds: Equatable, Sendable {
    /// A mid-turn entry older than this with no follow-up means the session
    /// stalled (interrupted, crashed, or waiting on something) — surface it.
    public var stall: TimeInterval
    /// Anything older than this is treated as no agent at all.
    public var idle: TimeInterval

    public init(stall: TimeInterval = 600, idle: TimeInterval = 1_800) {
        self.stall = stall
        self.idle = idle
    }
}

/// One meaningful message entry from a Claude Code session log (`*.jsonl`).
/// Meta lines (mode, snapshots, attachments, summaries…) are not entries.
public struct AgentSessionEntry: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A prompt typed by the human — the model is about to work.
        case humanPrompt
        /// A tool result fed back to the model — mid-turn.
        case toolResult
        /// An assistant message that requests a tool — mid-turn.
        case assistantToolUse
        /// An assistant message with no tool call — the turn's final text.
        case assistantText
    }

    public var kind: Kind
    public var timestamp: Date
    public var isSidechain: Bool

    public init(kind: Kind, timestamp: Date, isSidechain: Bool) {
        self.kind = kind
        self.timestamp = timestamp
        self.isSidechain = isSidechain
    }

    /// Parse one JSONL line; nil for meta lines, malformed JSON, or entries
    /// without a usable timestamp.
    public static func parse(line: String) -> AgentSessionEntry? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any],
              let type = dict["type"] as? String,
              type == "user" || type == "assistant",
              let message = dict["message"] as? [String: Any],
              let timestampString = dict["timestamp"] as? String,
              let timestamp = parseTimestamp(timestampString)
        else { return nil }

        let blocks = (message["content"] as? [[String: Any]]) ?? []
        let blockTypes = Set(blocks.compactMap { $0["type"] as? String })
        let kind: Kind
        if type == "assistant" {
            kind = blockTypes.contains("tool_use") ? .assistantToolUse : .assistantText
        } else {
            kind = blockTypes.contains("tool_result") ? .toolResult : .humanPrompt
        }
        return AgentSessionEntry(
            kind: kind,
            timestamp: timestamp,
            isSidechain: dict["isSidechain"] as? Bool ?? false
        )
    }

    private static func parseTimestamp(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}

/// Maps the last main-chain session entry to an activity state.
public enum AgentStateDeriver {
    public static func derive(
        lastEntry: AgentSessionEntry?,
        now: Date,
        thresholds: AgentStatusThresholds = AgentStatusThresholds()
    ) -> AgentActivityState {
        guard let entry = lastEntry else { return .idle }
        let age = now.timeIntervalSince(entry.timestamp)
        if age >= thresholds.idle { return .idle }
        switch entry.kind {
        case .assistantText:
            return .needsAttention
        case .humanPrompt, .toolResult, .assistantToolUse:
            return age >= thresholds.stall ? .needsAttention : .working
        }
    }
}

/// Reads the newest Claude Code session log for a worktree and derives what the
/// agent there is doing. Pure filesystem reads; no side effects.
public struct AgentSessionScanner: Sendable {
    public var projectsRoot: URL
    public var thresholds: AgentStatusThresholds

    /// How much of the tail of a session file is scanned for the last entry.
    private static let tailBytes = 256 * 1_024

    public init(
        projectsRoot: URL = AgentSessionScanner.defaultProjectsRoot,
        thresholds: AgentStatusThresholds = AgentStatusThresholds()
    ) {
        self.projectsRoot = projectsRoot
        self.thresholds = thresholds
    }

    public static var defaultProjectsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
    }

    /// Claude Code names each project dir by replacing every character of the
    /// cwd that isn't an ASCII letter or digit with "-".
    public static func projectDirName(forWorktreePath path: String) -> String {
        String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    /// The agent state for a worktree, judged from the most recently modified
    /// session file in its project dir.
    public func state(forWorktreePath path: String, now: Date = Date()) -> AgentActivityState {
        let dir = projectsRoot.appendingPathComponent(
            Self.projectDirName(forWorktreePath: path), isDirectory: true)
        guard let newest = newestSessionFile(in: dir) else { return .idle }
        // Fast path: a file untouched for the idle window can't be anything else.
        if now.timeIntervalSince(newest.mtime) >= thresholds.idle { return .idle }
        return AgentStateDeriver.derive(
            lastEntry: lastMainChainEntry(in: newest.url), now: now, thresholds: thresholds)
    }

    private func newestSessionFile(in dir: URL) -> (url: URL, mtime: Date)? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        return entries
            .filter { $0.pathExtension == "jsonl" }
            .compactMap { url -> (URL, Date)? in
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                      let mtime = values.contentModificationDate else { return nil }
                return (url, mtime)
            }
            .max { $0.1 < $1.1 }
            .map { (url: $0.0, mtime: $0.1) }
    }

    /// Scan the tail of the file backwards for the last parseable entry that
    /// belongs to the main conversation (sidechains are subagent chatter).
    private func lastMainChainEntry(in url: URL) -> AgentSessionEntry? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let offset = size > UInt64(Self.tailBytes) ? size - UInt64(Self.tailBytes) : 0
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        for line in text.split(separator: "\n").reversed() {
            if let entry = AgentSessionEntry.parse(line: String(line)), !entry.isSidechain {
                return entry
            }
        }
        return nil
    }
}
