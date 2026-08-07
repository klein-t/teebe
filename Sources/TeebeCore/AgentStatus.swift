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
    /// The directory the session was operating in when this entry was logged.
    /// This is the ground truth for *which worktree* the agent is in: a session
    /// launched in the primary checkout that moves into a linked worktree keeps
    /// logging under the launch dir's project folder, but its entries' `cwd`
    /// follows the agent.
    public var cwd: String?

    public init(kind: Kind, timestamp: Date, isSidechain: Bool, cwd: String? = nil) {
        self.kind = kind
        self.timestamp = timestamp
        self.isSidechain = isSidechain
        self.cwd = cwd
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
            isSidechain: dict["isSidechain"] as? Bool ?? false,
            cwd: dict["cwd"] as? String
        )
    }

    // Built once — ISO8601DateFormatter is expensive to construct and thread-safe,
    // and this parser runs for every scanned session-log line.
    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func parseTimestamp(_ string: String) -> Date? {
        fractionalFormatter.date(from: string) ?? plainFormatter.date(from: string)
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
    /// Injectable so tests can exercise the window boundary with small files.
    public var tailBytes: Int

    public init(
        projectsRoot: URL = AgentSessionScanner.defaultProjectsRoot,
        thresholds: AgentStatusThresholds = AgentStatusThresholds(),
        tailBytes: Int = 256 * 1_024
    ) {
        self.projectsRoot = projectsRoot
        self.thresholds = thresholds
        self.tailBytes = tailBytes
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

    /// The agent state for a single worktree, judged only from sessions logged
    /// under its own project dir.
    public func state(forWorktreePath path: String, now: Date = Date()) -> AgentActivityState {
        states(forWorktreePaths: [path], now: now)[path] ?? .idle
    }

    /// States for a repo's worktrees, attributing each session to the worktree
    /// its entries actually ran in (the entry `cwd`), not the directory it was
    /// launched from. A session started in the primary checkout that then works
    /// inside a linked worktree logs under the primary's project dir — a purely
    /// per-dir lookup would pin its "working" badge on the primary.
    public func states(forWorktreePaths paths: [String], now: Date = Date()) -> [String: AgentActivityState] {
        var result: [String: AgentActivityState] = [:]
        for path in paths { result[path] = .idle }
        // Every fresh session file across every project dir (files idle-old by
        // mtime can only be idle — skip without reading them).
        var files: [(launchPath: String, url: URL, mtime: Date)] = []
        var seen = Set<URL>()
        for path in paths {
            let dir = projectsRoot.appendingPathComponent(
                Self.projectDirName(forWorktreePath: path), isDirectory: true)
            for file in sessionFiles(in: dir) where now.timeIntervalSince(file.mtime) < thresholds.idle {
                guard seen.insert(file.url.standardizedFileURL).inserted else { continue }
                files.append((path, file.url, file.mtime))
            }
        }
        // Oldest first, so when two sessions land on the same worktree the newer
        // session's verdict wins (the per-dir "newest file wins" rule, kept).
        for file in files.sorted(by: { $0.mtime < $1.mtime }) {
            guard let entry = lastMainChainEntry(in: file.url) else { continue }
            let state = AgentStateDeriver.derive(lastEntry: entry, now: now, thresholds: thresholds)
            guard state != .idle else { continue }
            let owner = owningPath(forCwd: entry.cwd, among: paths) ?? file.launchPath
            result[owner] = state
        }
        return result
    }

    /// The deepest known worktree containing `cwd` — sessions record the exact
    /// directory they run in, which is often a subdirectory of the worktree.
    /// nil when `cwd` is missing or outside every known worktree.
    private func owningPath(forCwd cwd: String?, among paths: [String]) -> String? {
        guard let cwd else { return nil }
        return paths
            .filter { cwd == $0 || cwd.hasPrefix($0 + "/") }
            .max { $0.count < $1.count }
    }

    private func sessionFiles(in dir: URL) -> [(url: URL, mtime: Date)] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries
            .filter { $0.pathExtension == "jsonl" }
            .compactMap { url -> (url: URL, mtime: Date)? in
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                      let mtime = values.contentModificationDate else { return nil }
                return (url: url, mtime: mtime)
            }
    }

    /// Scan the tail of the file backwards for the last parseable entry that
    /// belongs to the main conversation (sidechains are subagent chatter).
    ///
    /// Lines are located and decoded individually, from the end: a tail window
    /// that opens mid-multibyte-character (or mid-line) only invalidates that
    /// first truncated line instead of poisoning a whole-buffer decode, and the
    /// scan stops at the first hit instead of materializing every line of the
    /// window when only the last one or two matter.
    private func lastMainChainEntry(in url: URL) -> AgentSessionEntry? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let offset = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty
        else { return nil }
        let newline = UInt8(ascii: "\n")
        var end = data.endIndex
        while end > data.startIndex {
            let start = data[data.startIndex..<end].lastIndex(of: newline).map { $0 + 1 }
                ?? data.startIndex
            if start < end,
               let line = String(data: data[start..<end], encoding: .utf8),
               let entry = AgentSessionEntry.parse(line: line),
               !entry.isSidechain {
                return entry
            }
            end = start > data.startIndex ? start - 1 : data.startIndex
        }
        return nil
    }
}
