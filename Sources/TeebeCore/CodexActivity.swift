import Foundation

/// One record of a Codex rollout (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`)
/// that says something about the session's state. Codex 0.155 writes, per line,
/// `{"timestamp", "type", "payload"}`; the kinds used here:
/// - `session_meta` (first line): thread id, cwd, and `source` — `"cli"`,
///   `"exec"`, `{"subagent":{"thread_spawn":{"parent_thread_id":…}}}`, or
///   `{"subagent":{"other":"guardian"}}` (an approval-review thread).
/// - `turn_context`: the turn's cwd, `approval_policy`, `approvals_reviewer`.
/// - `event_msg` `task_started` / `task_complete` / `turn_aborted`: the turn
///   lifecycle. `item_completed` carries finished `CommandExecution` items (with
///   `cwd`) and `FileChange` items (with the changed paths).
/// - `response_item` `function_call` / `custom_tool_call` and their `…_output`,
///   paired by `call_id`: a call without output is still pending.
///
/// Approval requests are not written to the rollout at all, so a pending
/// approval can only be inferred: an escalated call (`require_escalated`) that
/// a human reviews, pending for longer than a quick command takes.
public struct CodexRolloutRecord: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case turnStarted
        case turnCompleted
        case turnAborted
        /// A tool call; `question` for the ask-the-user tools, `escalated` when it
        /// asks to run outside the sandbox (what triggers an approval prompt).
        case toolCall(callID: String, question: Bool, escalated: Bool)
        case toolOutput(callID: String)
        case turnContext(cwd: String?, humanApproves: Bool)
        /// Anything else written during a turn (reasoning, messages, token counts…).
        case activity
    }

    public var kind: Kind
    public var timestamp: Date
    /// Paths the record says the agent works on: command working directories,
    /// edited files. Absolute; relative patch paths are dropped.
    public var targets: [String] = []

    public init(kind: Kind, timestamp: Date, targets: [String] = []) {
        self.kind = kind
        self.timestamp = timestamp
        self.targets = targets
    }

    public static func parse(line: String) -> CodexRolloutRecord? {
        guard let data = line.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = dict["type"] as? String,
              let stamp = dict["timestamp"] as? String,
              let timestamp = AgentSessionEntry.parseTimestamp(stamp),
              let payload = dict["payload"] as? [String: Any]
        else { return nil }
        switch type {
        case "session_meta": return nil
        case "event_msg": return event(payload, at: timestamp)
        case "response_item": return responseItem(payload, at: timestamp)
        case "turn_context":
            let policy = payload["approval_policy"] as? String
            let reviewer = payload["approvals_reviewer"] as? String
            let humanApproves = policy != nil && policy != "never" && reviewer != "auto_review"
            return CodexRolloutRecord(kind: .turnContext(cwd: payload["cwd"] as? String, humanApproves: humanApproves),
                                      timestamp: timestamp)
        default:
            return CodexRolloutRecord(kind: .activity, timestamp: timestamp)
        }
    }

    private static func event(_ payload: [String: Any], at timestamp: Date) -> CodexRolloutRecord {
        switch payload["type"] as? String {
        case "task_started": return CodexRolloutRecord(kind: .turnStarted, timestamp: timestamp)
        case "task_complete": return CodexRolloutRecord(kind: .turnCompleted, timestamp: timestamp)
        case "turn_aborted": return CodexRolloutRecord(kind: .turnAborted, timestamp: timestamp)
        case "item_completed":
            return CodexRolloutRecord(kind: .activity, timestamp: timestamp,
                                      targets: completedItemTargets(payload["item"] as? [String: Any]))
        default: return CodexRolloutRecord(kind: .activity, timestamp: timestamp)
        }
    }

    private static func responseItem(_ payload: [String: Any], at timestamp: Date) -> CodexRolloutRecord {
        let type = payload["type"] as? String
        guard let callID = payload["call_id"] as? String else {
            return CodexRolloutRecord(kind: .activity, timestamp: timestamp)
        }
        switch type {
        case "function_call", "custom_tool_call":
            let name = payload["name"] as? String ?? ""
            let body = (payload["arguments"] as? String) ?? (payload["input"] as? String) ?? ""
            let question = questionTools.contains(name) || body.contains("request_user_input")
            return CodexRolloutRecord(
                kind: .toolCall(callID: callID, question: question, escalated: body.contains("require_escalated")),
                timestamp: timestamp, targets: callTargets(body))
        case "function_call_output", "custom_tool_call_output":
            return CodexRolloutRecord(kind: .toolOutput(callID: callID), timestamp: timestamp)
        default:
            return CodexRolloutRecord(kind: .activity, timestamp: timestamp)
        }
    }

    static let questionTools: Set<String> = ["request_user_input", "request_user_input_async"]

    /// `workdir` of `exec_command` calls (JSON arguments, or the object literals
    /// of a code-mode `exec` script) and the files an `apply_patch` names.
    static func callTargets(_ body: String) -> [String] {
        let range = NSRange(body.startIndex..., in: body)
        var found: [(Int, String)] = []
        for pattern in [workdirPattern, patchPattern] {
            for match in pattern.matches(in: body, range: range) {
                guard let path = Range(match.range(at: 1), in: body) else { continue }
                found.append((match.range.location, String(body[path])))
            }
        }
        // Newest first: a script's later calls are the more recent targets.
        return found.sorted { $0.0 > $1.0 }.map(\.1)
    }

    private static func completedItemTargets(_ item: [String: Any]?) -> [String] {
        guard let item else { return [] }
        switch item["type"] as? String {
        case "CommandExecution":
            return (item["cwd"] as? String).map { [$0] } ?? []
        case "FileChange":
            return ((item["changes"] as? [String: Any])?.keys).map { $0.filter { $0.hasPrefix("/") }.sorted() } ?? []
        default:
            return []
        }
    }

    // swiftlint:disable force_try
    private static let workdirPattern = try! NSRegularExpression(pattern: #""?workdir"?\s*:\s*"(/[^"\\]+)""#)
    private static let patchPattern = try! NSRegularExpression(
        pattern: #"\*\*\* (?:Add|Update|Delete) File: (/[^\n\\"]+)"#)
    // swiftlint:enable force_try
}

/// What a rollout file says about its thread, from its first line and its tail.
struct CodexThreadSummary {
    enum Role: Equatable {
        case user
        case subagent(parentID: String)
        /// An approval-review thread: never the user's work.
        case guardian
    }

    var id: String
    var role: Role
    var cwd: String?
    /// Newest record's time.
    var lastActivity: Date?
    /// The newest lifecycle record in the tail; nil when the tail holds none
    /// (a turn longer than the tail window, or a thread never prompted).
    var lifecycle: CodexRolloutRecord.Kind?
    var hasTurnRecords = false
    /// A pending call of the current turn asks the user a question.
    var pendingQuestion = false
    /// Since when an escalated call a human must approve has been pending.
    var pendingApprovalSince: Date?
    /// Recent targets, newest first (see `WorktreeAttribution`).
    var targets: [String] = []
}

/// Reads Codex rollouts and derives, per thread, working / waiting / idle.
/// Pure filesystem reads.
///
/// Rules (thresholds shared with Claude Code's):
/// - The newest lifecycle record decides: `task_complete` or `turn_aborted`
///   means the turn is over and the user's thread waits for them.
/// - Inside a turn: a pending ask-the-user call, or an escalated call a human
///   reviews pending past `quickTool`, waits on the user; silence past `stall`
///   means it stalled (waiting); otherwise it is working.
/// - Nothing written for `idle`: idle.
/// - A working subagent thread is work for its own worktree and its parent's;
///   a finished or silent subagent adds nothing. Guardian threads are ignored.
/// - Attribution: `WorktreeAttribution` (recent targets, then cwd).
public struct CodexRolloutScanner: AgentActivitySource {
    public var sessionsRoot: URL
    public var thresholds: AgentStatusThresholds
    public var tailBytes: Int
    /// How many date folders back are listed. A resumed thread keeps writing to
    /// the rollout in the folder of the day it started.
    public var lookbackDays: Int
    /// Summaries of files unchanged since the last scan (same size and mtime)
    /// are reused: a busy agent rewrites one or two rollouts a second, not all.
    private let cache = CodexSummaryCache()

    public init(sessionsRoot: URL = CodexRolloutScanner.defaultSessionsRoot,
                thresholds: AgentStatusThresholds = AgentStatusThresholds(),
                tailBytes: Int = 256 * 1_024, lookbackDays: Int = 30) {
        self.sessionsRoot = sessionsRoot
        self.thresholds = thresholds
        self.tailBytes = tailBytes
        self.lookbackDays = lookbackDays
    }

    public static var defaultSessionsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    public func states(forWorktreePaths paths: [String], now: Date) -> [String: AgentActivityState] {
        var result: [String: AgentActivityState] = [:]
        for path in paths { result[path] = .idle }
        let files = rolloutFiles(now: now)
        let fresh = files.values.filter { now.timeIntervalSince($0.mtime) < thresholds.idle }
        var summaries: [String: CodexThreadSummary] = [:]
        for file in fresh { if let thread = cachedSummary(of: file.url, id: file.id) { summaries[file.id] = thread } }
        cache.keep(Set(fresh.map(\.url)))

        // User threads, oldest first so the newest verdict on a worktree wins.
        for file in fresh.sorted(by: { $0.mtime < $1.mtime }) {
            guard let thread = summaries[file.id], thread.role == .user else { continue }
            let state = Self.state(of: thread, now: now, thresholds: thresholds)
            guard state != .idle, let owner = owner(of: thread, among: paths) else { continue }
            result[owner] = state
        }
        // Busy subagents: work where they are, and where their parent is.
        for thread in summaries.values {
            guard case let .subagent(parentID) = thread.role,
                  Self.state(of: thread, now: now, thresholds: thresholds) == .working else { continue }
            if let owner = owner(of: thread, among: paths) { result[owner] = .working }
            let parent = summaries[parentID] ?? files[parentID].flatMap { cachedSummary(of: $0.url, id: parentID) }
            if let parent, let owner = owner(of: parent, among: paths) { result[owner] = .working }
        }
        return result
    }

    static func state(of thread: CodexThreadSummary, now: Date, thresholds: AgentStatusThresholds) -> AgentActivityState {
        guard let last = thread.lastActivity, now.timeIntervalSince(last) < thresholds.idle else { return .idle }
        let waiting: AgentActivityState = thread.role == .user ? .needsAttention : .idle
        switch thread.lifecycle {
        case .turnCompleted?, .turnAborted?: return waiting
        case nil where !thread.hasTurnRecords: return .idle
        default: break
        }
        if thread.pendingQuestion { return waiting }
        if let since = thread.pendingApprovalSince, now.timeIntervalSince(since) >= thresholds.quickTool { return waiting }
        if now.timeIntervalSince(last) >= thresholds.stall { return waiting }
        return .working
    }

    private func owner(of thread: CodexThreadSummary, among paths: [String]) -> String? {
        WorktreeAttribution.owner(targets: thread.targets, cwd: thread.cwd, among: paths)
    }

    // MARK: - Files

    /// Rollouts in the last `lookbackDays` date folders, by thread id.
    private func rolloutFiles(now: Date) -> [String: RolloutFile] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var files: [String: RolloutFile] = [:]
        for back in 0...max(0, lookbackDays) {
            guard let day = calendar.date(byAdding: .day, value: -back, to: now) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            guard let year = parts.year, let month = parts.month, let dayOfMonth = parts.day else { continue }
            let dir = sessionsRoot
                .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", dayOfMonth), isDirectory: true)
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
            ) else { continue }
            for url in entries where url.pathExtension == "jsonl" && url.lastPathComponent.hasPrefix("rollout-") {
                guard let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                else { continue }
                let id = String(url.deletingPathExtension().lastPathComponent.suffix(36))
                files[id] = RolloutFile(id: id, url: url, mtime: mtime)
            }
        }
        return files
    }

    // MARK: - Reading one rollout

    private func cachedSummary(of url: URL, id: String) -> CodexThreadSummary? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let key = CodexSummaryCache.Key(size: values?.fileSize ?? -1, mtime: values?.contentModificationDate ?? .distantPast)
        if let hit = cache.get(url, key) { return hit }
        let thread = summary(of: url, id: id)
        if let thread { cache.set(url, key, thread) }
        return thread
    }

    func summary(of url: URL, id: String) -> CodexThreadSummary? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var thread = CodexThreadSummary(id: id, role: .user)
        // The first line (session_meta, ~20 KB of instructions) says who the thread is.
        if let head = try? handle.read(upToCount: 128 * 1_024),
           let end = head.firstIndex(of: UInt8(ascii: "\n")) ?? (head.isEmpty ? nil : head.endIndex),
           let meta = (try? JSONSerialization.jsonObject(with: head[head.startIndex..<end])) as? [String: Any],
           meta["type"] as? String == "session_meta",
           let payload = meta["payload"] as? [String: Any] {
            thread.cwd = payload["cwd"] as? String
            thread.role = Self.role(of: payload["source"])
        }
        guard thread.role != .guardian,
              let size = try? handle.seekToEnd() else { return thread }
        let offset = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.readToEnd() else { return thread }
        readTail(data, into: &thread)
        return thread
    }

    static func role(of source: Any?) -> CodexThreadSummary.Role {
        guard let subagent = (source as? [String: Any])?["subagent"] else { return .user }
        if let spawn = (subagent as? [String: Any])?["thread_spawn"] as? [String: Any],
           let parent = spawn["parent_thread_id"] as? String {
            return .subagent(parentID: parent)
        }
        return .guardian
    }

    /// Walk the tail newest to oldest: the newest lifecycle record, the turn's
    /// pending calls (calls newer than it without output), the turn's cwd and
    /// the recent targets.
    private func readTail(_ data: Data, into thread: inout CodexThreadSummary) {
        var walk = CodexTailWalk(thread: thread)
        let newline = UInt8(ascii: "\n")
        var end = data.endIndex
        while end > data.startIndex {
            let start = data[data.startIndex..<end].lastIndex(of: newline).map { $0 + 1 } ?? data.startIndex
            if start < end, let line = String(data: data[start..<end], encoding: .utf8),
               let record = CodexRolloutRecord.parse(line: line), !walk.take(record) { break }
            end = start > data.startIndex ? start - 1 : data.startIndex
        }
        thread = walk.finished
    }
}

/// One newest-to-oldest pass over a rollout tail: the newest lifecycle record,
/// the current turn's pending calls (newer than it, without output), the turn's
/// cwd and approval setup, and the recent targets.
private struct CodexTailWalk {
    var thread: CodexThreadSummary
    private var outputs = Set<String>()
    private var inCurrentTurn = true
    private var sawContext = false
    private var humanApproves = false
    private var escalatedSince: Date?

    init(thread: CodexThreadSummary) { self.thread = thread }

    var finished: CodexThreadSummary {
        var done = thread
        done.pendingApprovalSince = humanApproves ? escalatedSince : nil
        return done
    }

    /// Take the next older record; false once nothing more is needed.
    mutating func take(_ record: CodexRolloutRecord) -> Bool {
        let newest = thread.lastActivity ?? record.timestamp
        thread.lastActivity = newest
        let age = newest.timeIntervalSince(record.timestamp)
        if age <= WorktreeAttribution.targetWindow, thread.targets.count < WorktreeAttribution.targetLimit {
            thread.targets += record.targets
        }
        note(record)
        // Past the current turn's start with its context known, only targets are
        // still being gathered; stop once the window or the limit is reached.
        let targetsDone = thread.targets.count >= WorktreeAttribution.targetLimit || age > WorktreeAttribution.targetWindow
        return inCurrentTurn || !sawContext || !targetsDone
    }

    private mutating func note(_ record: CodexRolloutRecord) {
        switch record.kind {
        case .turnStarted, .turnCompleted, .turnAborted:
            if thread.lifecycle == nil { thread.lifecycle = record.kind }
            inCurrentTurn = false
        case let .turnContext(cwd, approves):
            if !sawContext {
                if let cwd { thread.cwd = cwd }
                humanApproves = approves
            }
            sawContext = true
        case let .toolOutput(callID):
            thread.hasTurnRecords = true
            outputs.insert(callID)
        case let .toolCall(callID, question, escalated):
            thread.hasTurnRecords = true
            guard inCurrentTurn, !outputs.contains(callID) else { return }
            thread.pendingQuestion = thread.pendingQuestion || question
            if escalated { escalatedSince = record.timestamp }
        case .activity:
            thread.hasTurnRecords = true
        }
    }
}

private struct RolloutFile {
    var id: String
    var url: URL
    var mtime: Date
}

/// Rollout summaries by file, valid while the file keeps its size and mtime.
private final class CodexSummaryCache: @unchecked Sendable {
    struct Key: Equatable { var size: Int; var mtime: Date }
    private let lock = NSLock()
    private var entries: [URL: (key: Key, summary: CodexThreadSummary)] = [:]

    func get(_ url: URL, _ key: Key) -> CodexThreadSummary? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[url], entry.key == key else { return nil }
        return entry.summary
    }

    func set(_ url: URL, _ key: Key, _ summary: CodexThreadSummary) {
        lock.lock(); entries[url] = (key, summary); lock.unlock()
    }

    /// Forget files that are no longer fresh.
    func keep(_ urls: Set<URL>) {
        lock.lock(); entries = entries.filter { urls.contains($0.key) }; lock.unlock()
    }
}
