import Foundation

/// Reads prompts and waiting reasons out of a Claude Code session log
/// (`~/.claude/projects/<dir>/<session>.jsonl`). Pure: it is handed bytes from
/// the head or the tail of a file. Unknown or malformed lines are skipped.
///
/// What the log exposes:
/// - User lines (`"type":"user"`) carry what was typed, mixed with tool results,
///   meta lines (`isMeta`), compaction summaries, slash-command scaffolding and,
///   in recent versions, an `origin.kind` that is `"human"` for typed prompts.
/// - `last-prompt` lines carry Claude Code's own one-line copy of the last prompt.
/// - A pending `AskUserQuestion` call carries its questions; `ExitPlanMode` its
///   plan. Permission prompts are not written at all: only the pending tool call
///   they are about is.
public enum ClaudeTranscript {
    /// The first prompt typed in a session, from the head of its log.
    public static func firstPrompt(head: Data) -> String? {
        var found: String?
        TranscriptLines.forward(head) { line in
            found = humanPrompt(line: line)
            return found == nil
        }
        return found
    }

    /// The latest prompt typed in a session, from the tail of its log: the
    /// newest typed prompt or `last-prompt` record.
    public static func latestPrompt(tail: Data) -> String? {
        var found: String?
        TranscriptLines.backward(tail) { line in
            if line.contains("last-prompt"), let dict = TranscriptLines.object(line),
               dict["type"] as? String == "last-prompt", let text = dict["lastPrompt"] as? String {
                found = AgentText.prompt(text)
            } else {
                found = humanPrompt(line: line)
            }
            return found == nil
        }
        return found
    }

    /// A typed prompt's cleaned text; nil for any other line.
    public static func humanPrompt(line: String) -> String? {
        // Cheap checks first: most lines are not user lines, and tool results are
        // user lines that can be very large.
        guard line.contains("\"user\""), !line.contains("tool_use_id"),
              let dict = TranscriptLines.object(line), dict["type"] as? String == "user",
              dict["isMeta"] as? Bool != true, dict["isSidechain"] as? Bool != true,
              dict["isCompactSummary"] as? Bool != true,
              let message = dict["message"] as? [String: Any]
        else { return nil }
        if let origin = dict["origin"] as? [String: Any], let kind = origin["kind"] as? String, kind != "human" {
            return nil
        }
        if dict["promptSource"] as? String == "system" { return nil }
        let text: String
        if let string = message["content"] as? String {
            text = string
        } else if let blocks = message["content"] as? [[String: Any]] {
            if blocks.contains(where: { $0["type"] as? String == "tool_result" }) { return nil }
            text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .joined(separator: "\n")
        } else {
            return nil
        }
        return AgentText.prompt(text)
    }

    /// What a waiting session waits on, from the tail of its log: a pending
    /// question, a pending plan or tool call, or else the end of its last message.
    /// nil when the newest entry is none of those (an interruption, a stall).
    public static func waitingReason(tail: Data) -> String? {
        var reason: String?
        var messageID: String?
        var texts: [String] = []
        var calls: [[String: Any]] = []
        TranscriptLines.backward(tail) { line in
            guard let dict = TranscriptLines.object(line),
                  let type = dict["type"] as? String, type == "user" || type == "assistant",
                  dict["isSidechain"] as? Bool != true,
                  let message = dict["message"] as? [String: Any] else { return true }
            if let current = messageID {
                // Still inside the newest message: gather its other blocks.
                guard type == "assistant", message["id"] as? String == current else { return false }
            } else {
                guard type == "assistant" else {
                    // Bookkeeping user lines (meta, local commands) don't end the search.
                    return dict["isMeta"] as? Bool == true || isLocalCommand(message)
                }
                messageID = message["id"] as? String ?? ""
            }
            let blocks = (message["content"] as? [[String: Any]]) ?? []
            calls = blocks.filter { $0["type"] as? String == "tool_use" } + calls
            texts = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil } + texts
            return messageID != ""
        }
        if !calls.isEmpty {
            reason = pendingCallReason(calls)
        } else if !texts.isEmpty {
            reason = AgentText.messageEnding(texts.joined(separator: "\n"))
        }
        return reason
    }

    private static func isLocalCommand(_ message: [String: Any]) -> Bool {
        let text = (message["content"] as? String)
            ?? ((message["content"] as? [[String: Any]])?.first { $0["type"] as? String == "text" }?["text"] as? String)
            ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("<command-") || trimmed.hasPrefix("<local-command-")
    }

    /// The reason a pending call gives: a question to answer, a plan to review,
    /// or a tool that waits for permission.
    static func pendingCallReason(_ calls: [[String: Any]]) -> String? {
        for call in calls where call["name"] as? String == "AskUserQuestion" {
            let questions = ((call["input"] as? [String: Any])?["questions"] as? [[String: Any]]) ?? []
            let texts = questions.compactMap { ($0["question"] as? String).flatMap { AgentText.line($0) } }
            guard let first = texts.first else { return nil }
            return texts.count > 1 ? AgentText.line(first + " (+\(texts.count - 1) more)") : first
        }
        for call in calls where call["name"] as? String == "ExitPlanMode" {
            let plan = (call["input"] as? [String: Any])?["plan"] as? String
            let heading = plan.flatMap(AgentText.prompt).map { AgentText.unmarked($0) }
            return AgentText.line("Plan ready for review" + (heading.map { ": " + $0 } ?? ""))
        }
        guard let call = calls.last, let name = call["name"] as? String, !name.isEmpty else { return nil }
        let input = call["input"] as? [String: Any] ?? [:]
        switch name {
        case "Bash":
            let what = (input["description"] as? String) ?? (input["command"] as? String)
            return what.flatMap { AgentText.line("Wants to run: " + $0) } ?? "Wants to run a command"
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            let path = (input["file_path"] as? String) ?? (input["notebook_path"] as? String)
            let file = path.map { URL(fileURLWithPath: $0).lastPathComponent }
            return AgentText.line("Wants to edit" + (file.map { " " + $0 } ?? " a file"))
        default:
            return AgentText.line("Wants to use " + name)
        }
    }
}

/// Reads prompts and waiting reasons out of a Codex rollout
/// (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`). Pure, like `ClaudeTranscript`.
///
/// What the rollout exposes:
/// - User prompts as `response_item` messages with role `user` (mixed with the
///   AGENTS.md and environment context Codex adds), and in some versions as
///   `event_msg` `user_message` records.
/// - `task_complete` records carry the turn's `last_agent_message`.
/// - A pending `request_user_input` call carries its questions. Approval prompts
///   are not written: only the escalated call they are about is, with the
///   `justification` the agent gave.
public enum CodexTranscript {
    public static func firstPrompt(head: Data) -> String? {
        var found: String?
        TranscriptLines.forward(head) { line in
            found = userPrompt(line: line)
            return found == nil
        }
        return found
    }

    public static func latestPrompt(tail: Data) -> String? {
        var found: String?
        TranscriptLines.backward(tail) { line in
            found = userPrompt(line: line)
            return found == nil
        }
        return found
    }

    /// A user prompt's cleaned text; nil for any other record.
    public static func userPrompt(line: String) -> String? {
        guard line.contains("user"), let dict = TranscriptLines.object(line),
              let payload = dict["payload"] as? [String: Any] else { return nil }
        switch (dict["type"] as? String, payload["type"] as? String) {
        case ("response_item", "message"?):
            guard payload["role"] as? String == "user" else { return nil }
            let blocks = (payload["content"] as? [[String: Any]]) ?? []
            let text = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
            return AgentText.prompt(text)
        case ("event_msg", "user_message"?):
            return (payload["message"] as? String).flatMap(AgentText.prompt)
        default:
            return nil
        }
    }

    /// What a waiting thread waits on, from the tail of its rollout: a pending
    /// question, a pending escalated command, or else the end of the turn's last
    /// message. nil after an aborted turn or a stall.
    public static func waitingReason(tail: Data) -> String? {
        var walk = CodexWaitWalk()
        TranscriptLines.backward(tail) { line in
            guard let dict = TranscriptLines.object(line), let payload = dict["payload"] as? [String: Any] else { return true }
            return walk.take(type: dict["type"] as? String, payload: payload)
        }
        return walk.reason
    }

    /// The first question of a `request_user_input` call's arguments.
    static func questionText(_ body: String) -> String? {
        if let data = body.data(using: .utf8),
           let args = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let questions = args["questions"] as? [[String: Any]] {
            let texts = questions.compactMap { question in
                ["question", "title", "header", "prompt"].lazy.compactMap { question[$0] as? String }.first
            }.compactMap { AgentText.line($0) }
            guard let first = texts.first else { return nil }
            return texts.count > 1 ? AgentText.line(first + " (+\(texts.count - 1) more)") : first
        }
        return stringField(["question", "title"], in: body).flatMap { AgentText.line($0) }
    }

    /// What an escalated command asks approval for, by its justification.
    static func approvalText(_ body: String) -> String {
        guard let why = stringField(["justification"], in: body).flatMap({ AgentText.line($0) }) else {
            return "Asks to run a command outside the sandbox"
        }
        return AgentText.line("Asks for approval: " + why) ?? "Asks to run a command outside the sandbox"
    }

    /// The first string value of `key` in JSON or in a script's object literal.
    private static func stringField(_ keys: [String], in body: String) -> String? {
        for key in keys {
            let pattern = #""?\#(key)"?\s*:\s*"((?:[^"\\]|\\.)*)""#
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
                  let range = Range(match.range(at: 1), in: body) else { continue }
            let literal = "\"" + body[range] + "\""
            if let data = literal.data(using: .utf8),
               let decoded = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String {
                return decoded
            }
        }
        return nil
    }
}

/// One newest-to-oldest pass over a rollout tail for `CodexTranscript.waitingReason`.
private struct CodexWaitWalk {
    private var outputs = Set<String>()
    private var question: String?
    private var approval: String?
    private var finished: String?
    private var lastAssistant: String?
    private var turnEnded = false

    var reason: String? { turnEnded ? finished ?? lastAssistant : question ?? approval }

    /// Take the next older record; false once nothing more is needed.
    mutating func take(type: String?, payload: [String: Any]) -> Bool {
        let kind = payload["type"] as? String
        if type == "event_msg" {
            return event(kind, payload)
        }
        guard type == "response_item" else { return true }
        switch kind {
        case "message"?:
            guard payload["role"] as? String == "assistant" else { return true }
            let text = ((payload["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }
                .joined(separator: "\n")
            lastAssistant = lastAssistant ?? AgentText.messageEnding(text)
            return !turnEnded || lastAssistant == nil
        case "function_call_output"?, "custom_tool_call_output"?:
            if let id = payload["call_id"] as? String { outputs.insert(id) }
        case "function_call"?, "custom_tool_call"?:
            pendingCall(payload)
        default:
            break
        }
        return true
    }

    private mutating func event(_ kind: String?, _ payload: [String: Any]) -> Bool {
        switch kind {
        case "task_complete"?:
            if turnEnded { return false }
            turnEnded = true
            finished = (payload["last_agent_message"] as? String).flatMap(AgentText.messageEnding)
            return finished == nil
        case "turn_aborted"?, "task_started"?:
            return false
        default:
            return true
        }
    }

    /// A call of the current turn with no output yet: a question or an approval.
    private mutating func pendingCall(_ payload: [String: Any]) {
        guard !turnEnded, let id = payload["call_id"] as? String, !outputs.contains(id) else { return }
        let name = payload["name"] as? String ?? ""
        let body = (payload["arguments"] as? String) ?? (payload["input"] as? String) ?? ""
        if CodexRolloutRecord.questionTools.contains(name) || body.contains("request_user_input") {
            question = question ?? CodexTranscript.questionText(body)
        } else if body.contains("require_escalated") {
            approval = approval ?? CodexTranscript.approvalText(body)
        }
    }
}

/// Line iteration over a window of a JSONL file. A window that opens or ends
/// mid-line only loses that partial line: it fails to decode and is skipped.
enum TranscriptLines {
    /// Calls `visit` per line, oldest first, until it returns false.
    static func forward(_ data: Data, _ visit: (String) -> Bool) {
        let newline = UInt8(ascii: "\n")
        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: newline) ?? data.endIndex
            if start < end, let line = String(data: data[start..<end], encoding: .utf8), !visit(line) { return }
            start = end + 1
        }
    }

    /// Calls `visit` per line, newest first, until it returns false.
    static func backward(_ data: Data, _ visit: (String) -> Bool) {
        let newline = UInt8(ascii: "\n")
        var end = data.endIndex
        while end > data.startIndex {
            let start = data[data.startIndex..<end].lastIndex(of: newline).map { $0 + 1 } ?? data.startIndex
            if start < end, let line = String(data: data[start..<end], encoding: .utf8), !visit(line) { return }
            end = start > data.startIndex ? start - 1 : data.startIndex
        }
    }

    static func object(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The first `count` bytes of a file; nil when unreadable or empty.
    static func head(of url: URL, count: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: count), !data.isEmpty else { return nil }
        return data
    }

    /// The last `count` bytes of a file; nil when unreadable or empty.
    static func tail(of url: URL, count: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let offset = size > UInt64(count) ? size - UInt64(count) : 0
        guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.readToEnd(), !data.isEmpty
        else { return nil }
        return data
    }
}

/// One harness's transcript readers, for `AgentContextCache`.
struct TranscriptReader {
    /// How much of the head is searched for the first prompt.
    var headBytes = 512 * 1_024
    var first: (Data) -> String?
    var latest: (Data) -> String?
    var reason: (Data) -> String?

    static let claude = TranscriptReader(first: ClaudeTranscript.firstPrompt(head:),
                                         latest: ClaudeTranscript.latestPrompt(tail:),
                                         reason: ClaudeTranscript.waitingReason(tail:))
    static let codex = TranscriptReader(first: CodexTranscript.firstPrompt(head:),
                                        latest: CodexTranscript.latestPrompt(tail:),
                                        reason: CodexTranscript.waitingReason(tail:))
}

/// Context read from session files, by file. The first prompt is in the head of
/// an append-only log, so once found it is kept for as long as the file is in
/// use; what the tail says is kept while the file keeps its size and mtime. Reads
/// happen only for sessions that are working or waiting.
final class AgentContextCache: @unchecked Sendable {
    struct Key: Equatable { var size: Int; var mtime: Date }
    private struct TailEntry { var key: Key; var latest: String?; var reason: String? }
    private let lock = NSLock()
    private var firstPrompts: [URL: String] = [:]
    /// Files whose head held no prompt yet, at that size: read again once it grows.
    private var headMisses: [URL: Int] = [:]
    private var tails: [URL: TailEntry] = [:]
    /// Beyond this many files, everything is dropped and read again on demand.
    private let capacity = 256

    /// The waiting reason is only kept on the context while `state` is waiting.
    func context(of url: URL, state: AgentActivityState, lastActivity: Date?, tailBytes: Int,
                 reader: TranscriptReader) -> AgentContext {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let key = Key(size: values?.fileSize ?? -1, mtime: values?.contentModificationDate ?? .distantPast)
        let waiting = state == .needsAttention
        var context = AgentContext(state: state, lastActivity: lastActivity)
        context.firstPrompt = firstPrompt(of: url, size: key.size, headBytes: reader.headBytes, read: reader.first)

        let entry: TailEntry
        if let cached = lock.withLock({ tails[url] }), cached.key == key {
            entry = cached
        } else {
            let data = TranscriptLines.tail(of: url, count: tailBytes)
            entry = TailEntry(key: key, latest: data.flatMap(reader.latest), reason: data.flatMap(reader.reason))
            lock.withLock {
                if tails.count >= capacity { tails.removeAll() }
                tails[url] = entry
            }
        }
        context.latestPrompt = entry.latest
        context.waitingReason = waiting ? entry.reason : nil
        return context
    }

    private func firstPrompt(of url: URL, size: Int, headBytes: Int, read: (Data) -> String?) -> String? {
        let known: (String?, Int?) = lock.withLock { (firstPrompts[url], headMisses[url]) }
        if let prompt = known.0 { return prompt }
        if let missedAt = known.1, missedAt == size { return nil }
        let prompt = TranscriptLines.head(of: url, count: headBytes).flatMap(read)
        lock.withLock {
            if firstPrompts.count + headMisses.count >= capacity {
                firstPrompts.removeAll()
                headMisses.removeAll()
            }
            if let prompt { firstPrompts[url] = prompt; headMisses[url] = nil } else { headMisses[url] = size }
        }
        return prompt
    }
}
