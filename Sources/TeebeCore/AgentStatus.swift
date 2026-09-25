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
    /// How long a near-instant built-in tool (Read, Edit, Grep…) may stay
    /// pending before the silence means a permission prompt; also the grace
    /// added to a call's own timeout.
    public var quickTool: TimeInterval

    public init(stall: TimeInterval = 600, idle: TimeInterval = 1_800, quickTool: TimeInterval = 60) {
        self.stall = stall
        self.idle = idle
        self.quickTool = quickTool
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
        /// A block of an assistant message that does not end the turn: its
        /// message goes on to call a tool (a later line), or it is still
        /// streaming (`stop_reason` null — subagent logs write blocks as they
        /// stream). Mid-turn.
        case assistantPartial
        /// A block of the turn's final assistant message (`end_turn`, or the
        /// `stop_sequence` of a synthetic API-error message) — the turn ended.
        case assistantText
        /// The user interrupted the turn (Esc) — the agent is back to waiting.
        case interrupted
    }

    /// One tool call requested by an assistant message.
    public struct ToolCall: Equatable, Sendable {
        public var name: String
        /// The call's own timeout (Bash `input.timeout`), when it set one.
        public var timeout: TimeInterval?
        /// The absolute path the call works on, when it names one: a file it
        /// reads or edits (`file_path`, `notebook_path`), a search root (`path`),
        /// or the directory a Bash command `cd`s into.
        public var target: String?

        public init(name: String, timeout: TimeInterval? = nil, target: String? = nil) {
            self.name = name
            self.timeout = timeout
            self.target = target
        }
    }

    public var kind: Kind
    public var timestamp: Date
    public var isSidechain: Bool
    /// The API message this line is a block of (assistant lines only). Parallel
    /// tool calls are separate lines sharing it.
    public var messageID: String?
    /// The tool calls of an `.assistantToolUse` entry — after a tail scan, every
    /// call of its message, not only the last line's.
    public var toolCalls: [ToolCall] = []
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
            // Each content block is its own line; only the stop reason says
            // whether this message ended the turn. Main-chain lines carry the
            // message's final reason, subagent lines are null until the last.
            if blockTypes.contains("tool_use") {
                kind = .assistantToolUse
            } else if endsTurn(stopReason: message["stop_reason"] as? String) {
                kind = .assistantText
            } else {
                kind = .assistantPartial
            }
        } else if blockTypes.contains("tool_result") {
            kind = .toolResult
        } else {
            // A compaction summary neither starts nor ends a turn.
            if dict["isCompactSummary"] as? Bool == true { return nil }
            let text = leadingText(of: message["content"])
            if text.hasPrefix("[Request interrupted by user") {
                kind = .interrupted
            } else if localCommandPrefixes.contains(where: text.hasPrefix) {
                // Local slash commands (`/model`, `/effort`, `/compact`…) are
                // logged as user lines, but the model never answers them.
                return nil
            } else {
                kind = .humanPrompt
            }
        }
        var entry = AgentSessionEntry(
            kind: kind,
            timestamp: timestamp,
            isSidechain: dict["isSidechain"] as? Bool ?? false,
            cwd: dict["cwd"] as? String
        )
        if type == "assistant" {
            entry.messageID = message["id"] as? String
            entry.toolCalls = blocks.filter { $0["type"] as? String == "tool_use" }.map { block in
                let input = block["input"] as? [String: Any]
                let millis = (input?["timeout"] as? NSNumber)?.doubleValue
                return ToolCall(name: block["name"] as? String ?? "", timeout: millis.map { $0 / 1_000 },
                                target: input.flatMap(target(ofToolInput:)))
            }
        }
        return entry
    }

    /// The absolute path a tool call works on (see `ToolCall.target`).
    static func target(ofToolInput input: [String: Any]) -> String? {
        for key in ["file_path", "notebook_path", "path"] {
            if let path = input[key] as? String, path.hasPrefix("/") { return path }
        }
        guard let command = input["command"] as? String else { return nil }
        let range = NSRange(command.startIndex..., in: command)
        guard let match = cdPattern.matches(in: command, range: range).last else { return nil }
        for group in 1...3 {
            if let groupRange = Range(match.range(at: group), in: command) { return String(command[groupRange]) }
        }
        return nil
    }

    /// `cd /abs/dir` at the start of a command or after `&&`, `;`, `||` or a newline.
    private static let cdPattern: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"(?:^|&&|;|\|\||\n)\s*cd\s+(?:"(/[^"]+)"|'(/[^']+)'|(/[^\s;&|]+))"#)
    }()

    /// Whether an assistant message's stop reason ends the turn: `end_turn`,
    /// the `stop_sequence` of synthetic API-error messages, `max_tokens`…
    /// Null (still streaming), `tool_use` and `pause_turn` keep it going.
    private static func endsTurn(stopReason: String?) -> Bool {
        guard let stopReason else { return false }
        return stopReason != "tool_use" && stopReason != "pause_turn"
    }

    private static let localCommandPrefixes = [
        "<command-name>", "<command-message>", "<command-args>",
        "<local-command-stdout>", "<local-command-stderr>", "<local-command-caveat>"
    ]

    /// A user message's text: the string content, or its first text block.
    private static func leadingText(of content: Any?) -> String {
        if let string = content as? String { return String(string.drop(while: \.isWhitespace)) }
        let blocks = (content as? [[String: Any]]) ?? []
        let text = blocks.first { $0["type"] as? String == "text" }?["text"] as? String ?? ""
        return String(text.drop(while: \.isWhitespace))
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

    static func parseTimestamp(_ string: String) -> Date? {
        fractionalFormatter.date(from: string) ?? plainFormatter.date(from: string)
    }
}

/// A session Claude Code itself reports in its live registry
/// (`~/.claude/sessions/<pid>.json`, rewritten on every status change). It is
/// exact where the log can only guess: a permission prompt, a question or a
/// dialog is `waiting`; a turn in flight — or background agents it delegated —
/// is `busy`.
public struct LiveAgentSession: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case busy, waiting, idle
    }

    public var sessionID: String
    public var cwd: String?
    public var status: Status
    public var statusChangedAt: Date?

    public init(sessionID: String, cwd: String?, status: Status, statusChangedAt: Date?) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.status = status
        self.statusChangedAt = statusChangedAt
    }

    /// Parse one registry file; nil when it isn't a session with a known status.
    public static func parse(_ data: Data) -> (pid: Int32, session: LiveAgentSession)? {
        guard let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let pid = (dict["pid"] as? NSNumber)?.int32Value,
              let sessionID = dict["sessionId"] as? String
        else { return nil }
        let status: Status
        switch dict["status"] as? String {
        case "busy": status = .busy
        case "waiting": status = .waiting
        case "idle", "shell": status = .idle
        default: return nil
        }
        let changedAt = (dict["statusUpdatedAt"] as? NSNumber).map {
            Date(timeIntervalSince1970: $0.doubleValue / 1_000)
        }
        return (pid, LiveAgentSession(sessionID: sessionID, cwd: dict["cwd"] as? String,
                                      status: status, statusChangedAt: changedAt))
    }
}

/// Maps the last main-chain session entry to an activity state.
public enum AgentStateDeriver {
    /// With a `live` registry status the session's own report wins: busy is
    /// working, waiting needs the user, idle means the turn is over — unless the
    /// log has moved on since (a prompt landed before the registry caught up).
    public static func derive(
        lastEntry: AgentSessionEntry?,
        live: LiveAgentSession?,
        now: Date,
        thresholds: AgentStatusThresholds = AgentStatusThresholds()
    ) -> AgentActivityState {
        let logState = derive(lastEntry: lastEntry, now: now, thresholds: thresholds)
        guard let live else { return logState }
        switch live.status {
        case .busy: return .working
        case .waiting: return .needsAttention
        case .idle:
            if let entry = lastEntry, let changedAt = live.statusChangedAt, entry.timestamp > changedAt {
                return logState
            }
            return logState == .working ? .needsAttention : logState
        }
    }

    public static func derive(
        lastEntry: AgentSessionEntry?,
        now: Date,
        thresholds: AgentStatusThresholds = AgentStatusThresholds()
    ) -> AgentActivityState {
        guard let entry = lastEntry else { return .idle }
        let age = now.timeIntervalSince(entry.timestamp)
        if age >= thresholds.idle { return .idle }
        switch entry.kind {
        case .assistantText, .interrupted:
            return .needsAttention
        case .assistantToolUse:
            if entry.toolCalls.contains(where: { questionTools.contains($0.name) }) { return .needsAttention }
            return age >= pendingLimit(entry.toolCalls, thresholds: thresholds) ? .needsAttention : .working
        case .humanPrompt, .toolResult, .assistantPartial:
            return age >= thresholds.stall ? .needsAttention : .working
        }
    }

    /// Tools whose call *is* a question to the user (a choice, a plan to approve).
    static let questionTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]
    /// Built-in tools that finish in well under a second once allowed to run.
    static let quickTools: Set<String> = [
        "Read", "Write", "Edit", "MultiEdit", "NotebookEdit", "Glob", "Grep", "TodoWrite"
    ]

    /// How long pending tool calls may stay silent before that silence means
    /// the agent is waiting on the user. The log can't tell a permission prompt
    /// from a call that is still running, so the limit follows what the calls
    /// can legitimately take: near-instant built-ins get a short window; any
    /// other call (a build, a subagent, an MCP request) the general stall, or
    /// its own timeout when longer — a running command never reads as waiting.
    private static func pendingLimit(_ calls: [AgentSessionEntry.ToolCall],
                                     thresholds: AgentStatusThresholds) -> TimeInterval {
        if !calls.isEmpty, calls.allSatisfy({ quickTools.contains($0.name) }) { return thresholds.quickTool }
        let longestTimeout = calls.compactMap(\.timeout).max() ?? 0
        return max(thresholds.stall, longestTimeout + thresholds.quickTool)
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

    /// Claude Code's live session registry (`~/.claude/sessions`).
    public var sessionsRoot: URL
    /// Whether a pid is still running — registry files can outlive a crash.
    public var isProcessAlive: @Sendable (Int32) -> Bool

    public init(
        projectsRoot: URL = AgentSessionScanner.defaultProjectsRoot,
        thresholds: AgentStatusThresholds = AgentStatusThresholds(),
        tailBytes: Int = 256 * 1_024,
        sessionsRoot: URL? = nil,
        isProcessAlive: @escaping @Sendable (Int32) -> Bool = AgentSessionScanner.processIsAlive
    ) {
        self.projectsRoot = projectsRoot
        self.thresholds = thresholds
        self.tailBytes = tailBytes
        self.sessionsRoot = sessionsRoot ?? projectsRoot.deletingLastPathComponent()
            .appendingPathComponent("sessions", isDirectory: true)
        self.isProcessAlive = isProcessAlive
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

    /// Whether a batch of watched file events can change what
    /// `states(forWorktreePaths:)` reports for `worktreePaths`. The scan only
    /// reads those paths' project dirs, so writes by sessions of other projects
    /// under `projectsRoot` cannot; anything outside the root (the live
    /// registry, other harnesses' folders) and an empty batch always count.
    public static func eventsMatter(_ eventPaths: [String], projectsRoot: String, worktreePaths: [String]) -> Bool {
        guard !eventPaths.isEmpty else { return true }
        let root = WorktreeAttribution.normalized(projectsRoot) + "/"
        let ownDirs = Set(worktreePaths.map(projectDirName(forWorktreePath:)))
        return eventPaths.contains { raw in
            let path = WorktreeAttribution.normalized(raw)
            guard path.hasPrefix(root), let dir = path.dropFirst(root.count).split(separator: "/").first
            else { return true }
            return ownDirs.contains(String(dir))
        }
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
        let live = liveSessions()
        // Every fresh session file across every project dir (files idle-old by
        // mtime can only be idle — skip without reading them — unless the
        // session is live: a parent waiting on a long background agent logs
        // nothing).
        var files: [(launchPath: String, url: URL, mtime: Date)] = []
        var seen = Set<URL>()
        for path in paths {
            let dir = projectsRoot.appendingPathComponent(
                Self.projectDirName(forWorktreePath: path), isDirectory: true)
            for file in sessionFiles(in: dir)
            where now.timeIntervalSince(file.mtime) < thresholds.idle || live[Self.sessionID(of: file.url)] != nil {
                guard seen.insert(file.url.standardizedFileURL).inserted else { continue }
                files.append((path, file.url, file.mtime))
            }
        }
        // Oldest first, so when two sessions land on the same worktree the newer
        // session's verdict wins (the per-dir "newest file wins" rule, kept).
        for file in files.sorted(by: { $0.mtime < $1.mtime }) {
            let entry = lastEntry(in: file.url, includingSidechains: false)
            let session = live[Self.sessionID(of: file.url)]
            let state = AgentStateDeriver.derive(lastEntry: entry, live: session, now: now, thresholds: thresholds)
            guard state != .idle else { continue }
            let owner = WorktreeAttribution.owner(
                targets: recentTargets(in: file.url, includingSidechains: false),
                cwd: entry?.cwd ?? session?.cwd, among: paths) ?? file.launchPath
            result[owner] = state
        }
        markBusySubagents(in: &result, paths: paths, live: live, now: now)
        return result
    }

    public static func processIsAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private static func sessionID(of logURL: URL) -> String {
        logURL.deletingPathExtension().lastPathComponent
    }

    /// Registry entries whose process is still running, by session id.
    private func liveSessions() -> [String: LiveAgentSession] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: sessionsRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [:] }
        var sessions: [String: LiveAgentSession] = [:]
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let entry = LiveAgentSession.parse(data),
                  isProcessAlive(entry.pid) else { continue }
            sessions[entry.session.sessionID] = entry.session
        }
        return sessions
    }

    /// Subagents log to `<project>/<sessionId>/subagents/agent-*.jsonl`, not to
    /// the parent's file. A busy one means work is happening both in the
    /// worktree it runs in and in its parent's — a parent that launched a
    /// background subagent and ended its own turn is still busy.
    private func markBusySubagents(in result: inout [String: AgentActivityState], paths: [String],
                                   live: [String: LiveAgentSession], now: Date) {
        var seen = Set<URL>()
        for path in paths {
            let dir = projectsRoot.appendingPathComponent(
                Self.projectDirName(forWorktreePath: path), isDirectory: true)
            guard seen.insert(dir.standardizedFileURL).inserted else { continue }
            for sessionDir in subdirectories(of: dir) {
                // A live parent that isn't busy has no agent running under it.
                if let parent = live[sessionDir.lastPathComponent], parent.status != .busy { continue }
                let subagents = sessionDir.appendingPathComponent("subagents", isDirectory: true)
                let busy = sessionFiles(in: subagents)
                    .filter { now.timeIntervalSince($0.mtime) < thresholds.stall }
                    .compactMap { file in lastEntry(in: file.url, includingSidechains: true).map { (file.url, $0) } }
                    .filter { AgentStateDeriver.derive(lastEntry: $0.1, now: now, thresholds: thresholds) == .working }
                guard !busy.isEmpty else { continue }
                for (url, entry) in busy {
                    let targets = recentTargets(in: url, includingSidechains: true)
                    result[WorktreeAttribution.owner(targets: targets, cwd: entry.cwd, among: paths) ?? path] = .working
                }
                let parent = dir.appendingPathComponent(sessionDir.lastPathComponent + ".jsonl")
                let parentCwd = lastEntry(in: parent, includingSidechains: false)?.cwd
                let parentTargets = recentTargets(in: parent, includingSidechains: false)
                result[WorktreeAttribution.owner(targets: parentTargets, cwd: parentCwd, among: paths) ?? path] = .working
            }
        }
    }

    private func subdirectories(of dir: URL) -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
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

    /// Scan the tail of the file backwards for the last parseable entry. In a
    /// session file only the main conversation counts (sidechains are subagent
    /// chatter); a subagent's own file is all sidechain.
    ///
    /// Lines are located and decoded individually, from the end: a tail window
    /// that opens mid-multibyte-character (or mid-line) only invalidates that
    /// first truncated line instead of poisoning a whole-buffer decode, and the
    /// scan stops at the first hit instead of materializing every line of the
    /// window when only the last one or two matter.
    private func lastEntry(in url: URL, includingSidechains: Bool) -> AgentSessionEntry? {
        guard let data = tail(of: url) else { return nil }
        let newline = UInt8(ascii: "\n")
        var end = data.endIndex
        while end > data.startIndex {
            let start = data[data.startIndex..<end].lastIndex(of: newline).map { $0 + 1 }
                ?? data.startIndex
            if start < end,
               let line = String(data: data[start..<end], encoding: .utf8),
               let entry = AgentSessionEntry.parse(line: line),
               includingSidechains || !entry.isSidechain {
                guard entry.kind == .assistantToolUse, let id = entry.messageID else { return entry }
                // Parallel calls are separate lines: gather the whole message's
                // calls, so a quick call last doesn't hide a slow sibling.
                var merged = entry
                merged.toolCalls = siblingToolCalls(of: id, in: data[data.startIndex..<start]) + entry.toolCalls
                return merged
            }
            end = start > data.startIndex ? start - 1 : data.startIndex
        }
        return nil
    }

    /// The last `tailBytes` of a file; nil when unreadable or empty.
    private func tail(of url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let offset = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty
        else { return nil }
        return data
    }

    /// The paths the session's recent tool calls worked on, newest first: calls
    /// within `WorktreeAttribution.targetWindow` of its newest entry, at most
    /// `targetLimit` of them. Only read for sessions that are not idle.
    private func recentTargets(in url: URL, includingSidechains: Bool) -> [String] {
        guard let data = tail(of: url) else { return [] }
        var targets: [String] = []
        var newest: Date?
        let newline = UInt8(ascii: "\n")
        var end = data.endIndex
        while end > data.startIndex, targets.count < WorktreeAttribution.targetLimit {
            let start = data[data.startIndex..<end].lastIndex(of: newline).map { $0 + 1 } ?? data.startIndex
            if start < end,
               let line = String(data: data[start..<end], encoding: .utf8),
               let entry = AgentSessionEntry.parse(line: line),
               includingSidechains || !entry.isSidechain {
                if let newest, newest.timeIntervalSince(entry.timestamp) > WorktreeAttribution.targetWindow { break }
                newest = newest ?? entry.timestamp
                targets += entry.toolCalls.reversed().compactMap(\.target)
            }
            end = start > data.startIndex ? start - 1 : data.startIndex
        }
        return targets
    }

    /// Tool calls on the lines just before `data`'s end that belong to message
    /// `id` (its blocks are contiguous; the first foreign entry ends the run).
    private func siblingToolCalls(of id: String, in data: Data) -> [AgentSessionEntry.ToolCall] {
        var calls: [AgentSessionEntry.ToolCall] = []
        let newline = UInt8(ascii: "\n")
        var end = data.endIndex > data.startIndex ? data.endIndex - 1 : data.startIndex
        while end > data.startIndex {
            let start = data[data.startIndex..<end].lastIndex(of: newline).map { $0 + 1 } ?? data.startIndex
            if start < end,
               let line = String(data: data[start..<end], encoding: .utf8),
               let entry = AgentSessionEntry.parse(line: line) {
                guard entry.messageID == id else { break }
                calls = entry.toolCalls + calls
            }
            end = start > data.startIndex ? start - 1 : data.startIndex
        }
        return calls
    }
}
