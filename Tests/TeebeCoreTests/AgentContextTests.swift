import Foundation
import Testing
@testable import TeebeCore

// Fixture lines are modelled on Claude Code 2.x session logs and Codex 0.155
// rollouts; their text is made up.

private func stamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

private func json(_ object: Any) -> String {
    // swiftlint:disable:next force_try
    String(bytes: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8) ?? ""
}

private func data(_ lines: [String]) -> Data { Data((lines.joined(separator: "\n") + "\n").utf8) }

private enum Claude {
    static func user(_ content: Any, at date: Date = Date(), origin: String? = "human", extra: [String: Any] = [:]) -> String {
        var line: [String: Any] = ["type": "user", "message": ["role": "user", "content": content],
                                   "timestamp": stamp(date), "cwd": "/repo/wt", "isSidechain": false]
        if let origin { line["origin"] = ["kind": origin] }
        for (key, value) in extra { line[key] = value }
        return json(line)
    }

    static func assistant(_ blocks: [[String: Any]], stop: String?, id: String = "msg_1", at date: Date = Date(),
                          sidechain: Bool = false) -> String {
        json(["type": "assistant", "timestamp": stamp(date), "cwd": "/repo/wt", "isSidechain": sidechain,
              "message": ["id": id, "role": "assistant", "content": blocks, "stop_reason": (stop as Any?) ?? NSNull()]])
    }

    static func text(_ text: String) -> [String: Any] { ["type": "text", "text": text] }
    static func tool(_ name: String, _ input: [String: Any]) -> [String: Any] {
        ["type": "tool_use", "id": "toolu_1", "name": name, "input": input]
    }
    static let toolResult = user([["type": "tool_result", "tool_use_id": "toolu_1", "content": "ok"]], origin: nil)
    static func lastPrompt(_ text: String) -> String {
        json(["type": "last-prompt", "lastPrompt": text, "sessionId": "s1"])
    }
}

private enum Codex {
    static func record(_ type: String, _ payload: [String: Any], at date: Date = Date()) -> String {
        json(["timestamp": stamp(date), "type": type, "payload": payload])
    }
    static func meta(cwd: String, at date: Date = Date()) -> String {
        record("session_meta", ["id": "0199a000-0000-7000-8000-000000000001", "cwd": cwd, "source": "cli"], at: date)
    }
    static func userMessage(_ text: String, at date: Date = Date()) -> String {
        record("response_item", ["type": "message", "role": "user", "content": [["type": "input_text", "text": text]]], at: date)
    }
    static func assistantMessage(_ text: String, at date: Date = Date()) -> String {
        record("response_item", ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": text]]],
               at: date)
    }
    static func event(_ type: String, _ extra: [String: Any] = [:], at date: Date = Date()) -> String {
        record("event_msg", extra.merging(["type": type]) { $1 }, at: date)
    }
    static func call(_ name: String, id: String, arguments: String, custom: Bool = false, at date: Date = Date()) -> String {
        record("response_item", custom ? ["type": "custom_tool_call", "name": name, "call_id": id, "input": arguments]
               : ["type": "function_call", "name": name, "call_id": id, "arguments": arguments], at: date)
    }
    static func output(id: String, at date: Date = Date()) -> String {
        record("response_item", ["type": "function_call_output", "call_id": id, "output": "done"], at: date)
    }
    static let agentsFile = userMessage("# AGENTS.md instructions for /repo\n\n<INSTRUCTIONS>\nBe careful.\n</INSTRUCTIONS>")
    static let environment = userMessage("<environment_context>\n  <cwd>/repo</cwd>\n  <shell>zsh</shell>\n</environment_context>")
}

@Suite("Agent text cleaning")
struct AgentTextTests {
    @Test("system reminders and wrappers are removed; the first line the user wrote remains")
    func stripsWrappers() {
        let raw = "<system-reminder>\nThe user opened cart.ts\n</system-reminder>\n\nAdd guest checkout\nand tests too"
        #expect(AgentText.prompt(raw) == "Add guest checkout")
    }

    @Test("a slash command reads as its name and arguments; one without arguments is no prompt")
    func slashCommands() {
        let review = "<command-message>review</command-message>\n<command-name>/review</command-name>\n<command-args>the auth module</command-args>"
        #expect(AgentText.prompt(review) == "/review the auth module")
        #expect(AgentText.prompt("<command-name>/clear</command-name>\n<command-args></command-args>") == nil)
        #expect(AgentText.prompt("<local-command-stdout>Set model to opus</local-command-stdout>") == nil)
    }

    @Test("pasted blobs and attachment placeholders are skipped")
    func pastedBlobs() {
        #expect(AgentText.prompt("[Image #1]\nWhy does this render twice?") == "Why does this render twice?")
        #expect(AgentText.prompt("<pasted_content id=\"b05e\">\nlots\nof log\n</pasted_content>\nSummarize this log")
                == "Summarize this log")
        #expect(AgentText.prompt("<task>\nRename the store\n</task>") == "Rename the store")
    }

    @Test("harness bookkeeping is never a prompt")
    func bookkeeping() {
        #expect(AgentText.prompt("[Request interrupted by user]") == nil)
        #expect(AgentText.prompt("This session is being continued from a previous conversation that ran out") == nil)
        #expect(AgentText.prompt("# AGENTS.md instructions for /repo\n\n<INSTRUCTIONS>x</INSTRUCTIONS>") == nil)
        #expect(AgentText.prompt("<environment_context><cwd>/x</cwd></environment_context>") == nil)
        #expect(AgentText.prompt("   \n\t") == nil)
    }

    @Test("control and format characters become spaces, and lines are capped")
    func sanitizes() {
        #expect(AgentText.line("a\tb\u{0007}c\u{202E}d\r\ne") == "a b c d e")
        let long = String(repeating: "word ", count: 100)
        let capped = AgentText.line(long, limit: 40)
        #expect(capped?.count ?? 0 <= 40)
        #expect(capped?.hasSuffix("…") == true)
        #expect(AgentText.prompt(long)?.count ?? 0 <= AgentText.maximumLength)
    }

    @Test("a message ending keeps its last prose lines, without code or markdown")
    func messageEnding() {
        let message = "## Done\n\n- Fixed the timer\n\n```ts\nclearTimeout(t)\n```\n\nThe tests pass.\nShould I also raise the **idle** limit?"
        #expect(AgentText.messageEnding(message) == "The tests pass. Should I also raise the idle limit?")
        #expect(AgentText.messageEnding("```json\n{\"a\":1}\n```") == nil)
        #expect(AgentText.messageEnding("{\"verdict\":\"ok\",\"items\":[]}") == nil)
    }
}

@Suite("Claude Code transcripts")
struct ClaudeTranscriptTests {
    @Test("the first prompt skips meta lines, tool results, local commands and other senders")
    func firstPrompt() {
        let head = data([
            json(["type": "permission-mode", "permissionMode": "default"]),
            Claude.user("<command-name>/model</command-name>\n<command-args></command-args>"),
            Claude.user("Skill instructions follow", extra: ["isMeta": true]),
            Claude.user("<task-notification>agent done</task-notification>", origin: "task-notification"),
            Claude.toolResult,
            Claude.user([Claude.text("<system-reminder>ctx</system-reminder>"), Claude.text("Fix the flaky login test")]),
            Claude.user("Then update the docs")
        ])
        #expect(ClaudeTranscript.firstPrompt(head: head) == "Fix the flaky login test")
    }

    @Test("older logs without an origin still count typed prompts")
    func noOrigin() {
        #expect(ClaudeTranscript.firstPrompt(head: data([Claude.user("Port the CLI to Swift", origin: nil)]))
                == "Port the CLI to Swift")
    }

    @Test("a truncated or garbled line is skipped, never shown")
    func malformed() {
        let head = data(["{\"type\":\"user\",\"message\":{\"content\":\"cut off", "not json at all", Claude.user("Real prompt")])
        #expect(ClaudeTranscript.firstPrompt(head: head) == "Real prompt")
        #expect(ClaudeTranscript.firstPrompt(head: Data([0xFF, 0xFE, 0x0A])) == nil)
        #expect(ClaudeTranscript.waitingReason(tail: Data("garbage\n".utf8)) == nil)
    }

    @Test("the latest prompt is the newest typed prompt or last-prompt record")
    func latestPrompt() {
        let tail = data([Claude.user("First ask"), Claude.assistant([Claude.text("ok")], stop: "end_turn"),
                         Claude.user("Now add tests"), Claude.toolResult,
                         Claude.assistant([Claude.text("Added.")], stop: "end_turn")])
        #expect(ClaudeTranscript.latestPrompt(tail: tail) == "Now add tests")
        #expect(ClaudeTranscript.latestPrompt(tail: data([Claude.lastPrompt("Ship it"), Claude.toolResult])) == "Ship it")
    }

    @Test("a pending AskUserQuestion is the reason")
    func question() {
        let ask = Claude.tool("AskUserQuestion", ["questions": [
            ["question": "Email receipts or on screen only?", "header": "Receipts", "options": [["label": "Email"]]],
            ["question": "Keep guest carts?", "header": "Carts", "options": [["label": "Yes"]]]
        ]])
        let tail = data([Claude.user("Add guest checkout"), Claude.assistant([Claude.text("Two questions.")], stop: "tool_use"),
                         Claude.assistant([ask], stop: "tool_use")])
        #expect(ClaudeTranscript.waitingReason(tail: tail) == "Email receipts or on screen only? (+1 more)")
    }

    @Test("a pending plan and a pending tool call say what they wait on")
    func pendingCalls() {
        let plan = Claude.assistant([Claude.tool("ExitPlanMode", ["plan": "# Add refunds\n\n1. Model\n2. API"])], stop: "tool_use")
        #expect(ClaudeTranscript.waitingReason(tail: data([plan])) == "Plan ready for review: Add refunds")
        let bash = Claude.assistant([Claude.tool("Bash", ["command": "rm -rf build", "description": "Clean the build folder"])],
                                    stop: "tool_use")
        #expect(ClaudeTranscript.waitingReason(tail: data([bash])) == "Wants to run: Clean the build folder")
        let edit = Claude.assistant([Claude.tool("Edit", ["file_path": "/repo/wt/Sources/App.swift"])], stop: "tool_use")
        #expect(ClaudeTranscript.waitingReason(tail: data([edit])) == "Wants to edit App.swift")
    }

    @Test("a finished turn gives the end of the last message, across its blocks")
    func finishedTurn() {
        let tail = data([
            Claude.user("Fix the timeout"),
            Claude.assistant([["type": "thinking", "thinking": "..."]], stop: "end_turn", id: "msg_9"),
            Claude.assistant([Claude.text("Fixed the refresh timer.\nShould I raise the limit to 30 minutes?")],
                             stop: "end_turn", id: "msg_9"),
            json(["type": "system", "subtype": "turn_duration", "durationMs": 1000]),
            Claude.user("<local-command-stdout>ok</local-command-stdout>")
        ])
        #expect(ClaudeTranscript.waitingReason(tail: tail) == "Fixed the refresh timer. Should I raise the limit to 30 minutes?")
    }

    @Test("an interruption, a tool result or a sidechain line gives no reason")
    func noReason() {
        #expect(ClaudeTranscript.waitingReason(tail: data([Claude.user("[Request interrupted by user]")])) == nil)
        let ran = data([Claude.assistant([Claude.tool("Bash", ["command": "make"])], stop: "tool_use"), Claude.toolResult])
        #expect(ClaudeTranscript.waitingReason(tail: ran) == nil)
        let side = data([Claude.assistant([Claude.text("subagent says hi")], stop: "end_turn", sidechain: true)])
        #expect(ClaudeTranscript.waitingReason(tail: side) == nil)
    }
}

@Suite("Codex transcripts")
struct CodexTranscriptTests {
    @Test("the first prompt skips AGENTS.md and the environment context")
    func firstPrompt() {
        let head = data([Codex.meta(cwd: "/repo"), Codex.agentsFile, Codex.environment, Codex.event("task_started"),
                         Codex.userMessage("Support partial refunds"), Codex.userMessage("And log them")])
        #expect(CodexTranscript.firstPrompt(head: head) == "Support partial refunds")
        #expect(CodexTranscript.latestPrompt(tail: head) == "And log them")
    }

    @Test("older rollouts' user_message events are prompts too")
    func userMessageEvent() {
        #expect(CodexTranscript.firstPrompt(head: data([Codex.event("user_message", ["message": "Bump deps"])])) == "Bump deps")
    }

    @Test("a completed turn gives the end of its last agent message")
    func completed() {
        let tail = data([Codex.userMessage("Refunds"), Codex.event("task_started"),
                         Codex.assistantMessage("Working on it"),
                         Codex.event("task_complete", ["last_agent_message": "Refunds work.\nReject or cap refunds above the total?"])])
        #expect(CodexTranscript.waitingReason(tail: tail) == "Refunds work. Reject or cap refunds above the total?")
        // Without last_agent_message, the turn's last assistant message.
        let older = data([Codex.event("task_started"), Codex.assistantMessage("All green. Merge it?"),
                          Codex.event("task_complete")])
        #expect(CodexTranscript.waitingReason(tail: older) == "All green. Merge it?")
    }

    @Test("a pending request_user_input call is the reason; an answered one is not")
    func question() {
        let args = json(["questions": [["title": "Which branch should I target?", "options": ["dev", "main"]]]])
        let pending = data([Codex.event("task_started"), Codex.call("request_user_input_async", id: "c1", arguments: args)])
        #expect(CodexTranscript.waitingReason(tail: pending) == "Which branch should I target?")
        let answered = data([Codex.event("task_started"), Codex.call("request_user_input_async", id: "c1", arguments: args),
                             Codex.output(id: "c1")])
        #expect(CodexTranscript.waitingReason(tail: answered) == nil)
    }

    @Test("a pending escalated command gives its justification")
    func escalated() {
        let script = #"await tools.exec_command({cmd: "git push", sandbox_permissions: "require_escalated", justification: "Push the release branch \"v2\""})"#
        let tail = data([Codex.event("task_started"), Codex.call("exec", id: "c2", arguments: script, custom: true)])
        #expect(CodexTranscript.waitingReason(tail: tail) == "Asks for approval: Push the release branch \"v2\"")
        let bare = data([Codex.event("task_started"),
                         Codex.call("exec_command", id: "c3", arguments: json(["cmd": "ls", "sandbox_permissions": "require_escalated"]))])
        #expect(CodexTranscript.waitingReason(tail: bare) == "Asks to run a command outside the sandbox")
    }

    @Test("an aborted turn or an unknown format gives no reason")
    func noReason() {
        #expect(CodexTranscript.waitingReason(tail: data([Codex.event("task_started"), Codex.event("turn_aborted")])) == nil)
        #expect(CodexTranscript.waitingReason(tail: data([json(["kind": "future", "body": ["x": 1]])])) == nil)
        #expect(CodexTranscript.firstPrompt(head: data(["{\"type\":\"response_item\",\"payload\":"])) == nil)
    }
}

@Suite("Agent context in scanner snapshots")
struct AgentSnapshotTests {
    let worktree = "/Users/dev/acme-feature"

    func tempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("teebe-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("Claude Code: a waiting session's context carries its prompts and question")
    func claudeSnapshot() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent(AgentSessionScanner.projectDirName(forWorktreePath: worktree))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let now = Date()
        let ask = Claude.tool("AskUserQuestion", ["questions": [["question": "Keep the old API?"]]])
        try data([Claude.user("Replace the payments client", at: now - 60),
                  Claude.assistant([ask], stop: "tool_use", at: now - 5)])
            .write(to: dir.appendingPathComponent("11111111-2222-3333-4444-555555555555.jsonl"))
        let scanner = AgentSessionScanner(projectsRoot: root, sessionsRoot: root.appendingPathComponent("sessions"))
        let snapshot = scanner.snapshot(forWorktreePaths: [worktree], now: now)
        #expect(snapshot.states[worktree] == .needsAttention)
        #expect(snapshot.contexts[worktree] == AgentContext(state: .needsAttention, lastActivity: snapshot.contexts[worktree]?.lastActivity,
                                                            firstPrompt: "Replace the payments client",
                                                            latestPrompt: "Replace the payments client",
                                                            waitingReason: "Keep the old API?"))
        // `states` alone reads no context and reports the same state.
        #expect(scanner.states(forWorktreePaths: [worktree], now: now) == snapshot.states)
    }

    @Test("Codex: a working thread has its task but no reason")
    func codexSnapshot() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let parts = Calendar(identifier: .gregorian).dateComponents(in: .current, from: now)
        let folder = root.appendingPathComponent(String(format: "%04d/%02d/%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data([Codex.meta(cwd: worktree, at: now - 100), Codex.agentsFile,
                  Codex.event("task_started", at: now - 90), Codex.userMessage("Retry failed webhooks", at: now - 90),
                  Codex.record("response_item", ["type": "reasoning", "summary": []], at: now - 2)])
            .write(to: folder.appendingPathComponent("rollout-2026-11-19T10-00-00-0199a000-0000-7000-8000-000000000001.jsonl"))
        let snapshot = CodexRolloutScanner(sessionsRoot: root).snapshot(forWorktreePaths: [worktree], now: now)
        #expect(snapshot.states[worktree] == .working)
        #expect(snapshot.contexts[worktree]?.firstPrompt == "Retry failed webhooks")
        #expect(snapshot.contexts[worktree]?.waitingReason == nil)
    }

    @Test("combined: the waiting session's context wins over the working one's")
    func combined() {
        struct Scripted: AgentActivitySource {
            let snapshot: AgentSnapshot
            func states(forWorktreePaths paths: [String], now: Date) -> [String: AgentActivityState] { snapshot.states }
            func snapshot(forWorktreePaths paths: [String], now: Date) -> AgentSnapshot { snapshot }
        }
        let working = AgentContext(state: .working, lastActivity: Date(timeIntervalSince1970: 200), firstPrompt: "Codex task")
        let waiting = AgentContext(state: .needsAttention, lastActivity: Date(timeIntervalSince1970: 100),
                                   firstPrompt: "Claude task", waitingReason: "Proceed?")
        let combined = CombinedAgentActivity([
            Scripted(snapshot: AgentSnapshot(states: [worktree: .working], contexts: [worktree: working])),
            Scripted(snapshot: AgentSnapshot(states: [worktree: .needsAttention], contexts: [worktree: waiting]))
        ])
        let snapshot = combined.snapshot(forWorktreePaths: [worktree], now: Date())
        #expect(snapshot.states[worktree] == .needsAttention)
        #expect(snapshot.contexts[worktree] == waiting)
    }

    @Test("a worktree a busy subagent turned working keeps its task but drops its reason")
    func reconciled() {
        let contexts = ["/a": AgentContext(state: .needsAttention, firstPrompt: "Task", waitingReason: "Why?"),
                        "/b": AgentContext(state: .working, firstPrompt: "Gone")]
        let result = contexts.reconciled(with: ["/a": .working, "/b": .idle])
        #expect(result["/a"] == AgentContext(state: .working, firstPrompt: "Task"))
        #expect(result["/b"] == nil)
    }
}
