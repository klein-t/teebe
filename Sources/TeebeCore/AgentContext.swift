import Foundation

/// What an agent's own records say about its session in one worktree, besides
/// its state: the prompts it was given and, while it waits, what it waits on.
/// Read from local logs and shown locally only.
public struct AgentContext: Equatable, Sendable {
    /// The state of the session this context was read from.
    public var state: AgentActivityState
    /// When the session last wrote anything; decides between two sessions.
    public var lastActivity: Date?
    /// The first prompt the user typed in the session, cleaned to one line.
    public var firstPrompt: String?
    /// The most recent prompt the user typed in the session, cleaned to one line.
    public var latestPrompt: String?
    /// What the agent waits on: its pending question or request, otherwise the
    /// end of its last message. Only set while the session waits for the user.
    public var waitingReason: String?
    /// The exact session whose log supplied these lines. Not saved in app state.
    public var terminalSession: AgentTerminalSession?

    public init(state: AgentActivityState, lastActivity: Date? = nil, firstPrompt: String? = nil,
                latestPrompt: String? = nil, waitingReason: String? = nil, terminalSession: AgentTerminalSession? = nil) {
        self.state = state
        self.lastActivity = lastActivity
        self.firstPrompt = firstPrompt
        self.latestPrompt = latestPrompt
        self.waitingReason = waitingReason
        self.terminalSession = terminalSession
    }
}

/// A repo's agent states and, for worktrees with a session, its context.
public struct AgentSnapshot: Equatable, Sendable {
    public var states: [String: AgentActivityState]
    public var contexts: [String: AgentContext]

    public init(states: [String: AgentActivityState], contexts: [String: AgentContext] = [:]) {
        self.states = states
        self.contexts = contexts
    }
}

/// Turns raw prompt and message text from agent logs into one short, safe line.
/// Anything it cannot clean into plain text comes back nil: never garbage.
public enum AgentText {
    /// The longest line kept for a prompt or a reason.
    public static let maximumLength = 240

    /// Blocks an agent harness wraps around or adds to what the user typed;
    /// removed with their content.
    static let noiseTags = [
        "system-reminder", "environment_context", "user_instructions", "INSTRUCTIONS",
        "local-command-stdout", "local-command-stderr", "local-command-caveat",
        "command-message", "structured_output_contract", "send_user_message_question_reply",
        "user_shell_command", "turn_aborted", "task-notification", "pasted_content"
    ]

    /// A user's prompt as one line: wrappers removed, the first line of what the
    /// user wrote. A slash command reads as `/name args`, and one without
    /// arguments (`/clear`, `/model`) is not a prompt. nil when nothing is left.
    public static func prompt(_ raw: String) -> String? {
        var text = raw
        if let command = tagContent("command-name", in: text) {
            let args = tagContent("command-args", in: text)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !args.isEmpty else { return nil }
            let name = command.trimmingCharacters(in: .whitespacesAndNewlines)
            return line(clean(name.hasPrefix("/") ? name : "/" + name) + " " + clean(args))
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if skippedPrefixes.contains(where: trimmed.hasPrefix) { return nil }
        for tag in noiseTags { text = removingBlocks(tag, from: text) }
        for candidate in text.components(separatedBy: .newlines) {
            let stripped = candidate.trimmingCharacters(in: .whitespaces)
            if stripped.isEmpty || isTagOnly(stripped) || isPlaceholder(stripped) { continue }
            return line(stripped)
        }
        return nil
    }

    /// The end of an agent's message: its last one or two lines of prose, as one
    /// line. Code fences and markdown markers are dropped.
    public static func messageEnding(_ raw: String) -> String? {
        // A structured answer (a JSON object or array) is data, not prose to show.
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("["), let data = trimmed.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil { return nil }
        var lines: [String] = []
        var inFence = false
        for candidate in raw.components(separatedBy: .newlines) {
            let stripped = candidate.trimmingCharacters(in: .whitespaces)
            if stripped.hasPrefix("```") { inFence.toggle(); continue }
            if inFence || stripped.isEmpty || isTagOnly(stripped) { continue }
            if stripped.allSatisfy({ "-*_=|".contains($0) || $0 == " " }) { continue }
            lines.append(unmarked(stripped))
        }
        let ending = lines.suffix(2).filter { !$0.isEmpty }
        guard !ending.isEmpty else { return nil }
        return line(ending.joined(separator: " "))
    }

    /// One display line: control and format characters (newlines, tabs, bidi
    /// overrides) become spaces, runs of spaces collapse, and the result is
    /// capped at `limit` characters with an ellipsis. nil when empty.
    public static func line(_ raw: String, limit: Int = maximumLength) -> String? {
        var scalars = String.UnicodeScalarView()
        var lastWasSpace = true
        for scalar in raw.unicodeScalars {
            let isSpace = scalar.properties.generalCategory == .control
                || scalar.properties.generalCategory == .format
                || scalar.properties.generalCategory == .lineSeparator
                || scalar.properties.generalCategory == .paragraphSeparator
                || scalar.properties.isWhitespace
            if isSpace {
                if !lastWasSpace { scalars.append(" ") }
                lastWasSpace = true
            } else {
                scalars.append(scalar)
                lastWasSpace = false
            }
        }
        let collapsed = String(scalars).trimmingCharacters(in: .whitespaces)
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(max(1, limit - 1))).trimmingCharacters(in: .whitespaces) + "…"
    }

    // MARK: - Helpers

    /// Messages that are harness bookkeeping as a whole, not something typed.
    private static let skippedPrefixes = [
        "[Request interrupted by user", "Caveat: The messages below", "# AGENTS.md instructions",
        "<local-command-", "<task-notification>", "This session is being continued from a previous conversation"
    ]

    private static func clean(_ text: String) -> String { line(text) ?? "" }

    /// The text inside the first `<tag>…</tag>`.
    static func tagContent(_ tag: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(tag)>"),
              let close = text.range(of: "</\(tag)>", range: open.upperBound..<text.endIndex) else { return nil }
        return String(text[open.upperBound..<close.lowerBound])
    }

    /// Removes every `<tag …>…</tag>` block; an unclosed one runs to the end.
    static func removingBlocks(_ tag: String, from text: String) -> String {
        var result = text
        while let open = result.range(of: "<\(tag)") {
            let after = result[open.upperBound...]
            // Only a real tag opening: `<tag>` or `<tag attr…>`.
            guard let next = after.first, next == ">" || next == " " else {
                // Look past this occurrence by splitting there.
                let head = String(result[..<open.upperBound])
                return head + removingBlocks(tag, from: String(after))
            }
            if let close = result.range(of: "</\(tag)>", range: open.upperBound..<result.endIndex) {
                result.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                result.removeSubrange(open.lowerBound..<result.endIndex)
            }
        }
        return result
    }

    /// A line that is only an opening or closing tag, like `<task>` or `</task>`.
    private static func isTagOnly(_ line: String) -> Bool {
        line.range(of: #"^</?[A-Za-z][A-Za-z0-9_\-]*(\s[^<>]*)?/?>$"#, options: .regularExpression) != nil
    }

    /// Placeholders a harness writes for attachments: `[Image #1]`, `[Pasted text #2 +40 lines]`.
    private static func isPlaceholder(_ line: String) -> Bool {
        line.range(of: #"^(\[(Image|Pasted text|Pasted image)[^\]]*\]\s*)+$"#, options: .regularExpression) != nil
    }

    /// A markdown line without its list, heading or quote marker and emphasis.
    static func unmarked(_ line: String) -> String {
        var text = line
        if let marker = text.range(of: #"^(#{1,6}\s+|[-*+]\s+|>\s*|\d+[.)]\s+)"#, options: .regularExpression) {
            text.removeSubrange(marker)
        }
        for token in ["**", "__", "`"] { text = text.replacingOccurrences(of: token, with: "") }
        return text.trimmingCharacters(in: .whitespaces)
    }
}

extension [String: AgentContext] {
    /// Contexts as the final states say: a worktree a busy subagent turned
    /// working is no longer waiting, so its reason is dropped.
    func reconciled(with states: [String: AgentActivityState]) -> Self {
        var result: Self = [:]
        for (path, context) in self {
            guard let state = states[path], state != .idle else { continue }
            var updated = context
            updated.state = state
            if state != .needsAttention { updated.waitingReason = nil }
            result[path] = updated
        }
        return result
    }
}

/// The session file whose state a worktree shows, kept during a scan so its
/// context can be read afterwards.
struct SessionWinner {
    var url: URL
    var state: AgentActivityState
    var lastActivity: Date
}
