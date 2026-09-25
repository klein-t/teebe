import Foundation
import Testing
@testable import TeebeCore

// MARK: - Fixture builders (mirror the real ~/.claude/projects/*.jsonl shapes)

private func iso(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

private func humanPromptLine(at date: Date, sidechain: Bool = false, cwd: String = "/Users/k/Documents/CODE/teebe") -> String {
    """
    {"parentUuid":null,"isSidechain":\(sidechain),"type":"user",\
    "message":{"role":"user","content":"hey can u check the product"},\
    "uuid":"u1","timestamp":"\(iso(date))","origin":{"kind":"human"},"promptSource":"typed",\
    "cwd":"\(cwd)","sessionId":"s1","gitBranch":"dev"}
    """
}

private func toolResultLine(at date: Date, sidechain: Bool = false, cwd: String = "/Users/k/Documents/CODE/teebe") -> String {
    """
    {"parentUuid":"a1","isSidechain":\(sidechain),"type":"user",\
    "message":{"role":"user","content":[{"tool_use_id":"toolu_1","type":"tool_result","content":"ok"}]},\
    "uuid":"u2","timestamp":"\(iso(date))","cwd":"\(cwd)","sessionId":"s1"}
    """
}

private func assistantToolUseLine(at date: Date, sidechain: Bool = false, cwd: String = "/Users/k/Documents/CODE/teebe") -> String {
    """
    {"parentUuid":"u1","isSidechain":\(sidechain),"type":"assistant",\
    "message":{"role":"assistant","content":[{"type":"text","text":"Looking."},\
    {"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls"}}],"stop_reason":"tool_use"},\
    "uuid":"a1","timestamp":"\(iso(date))","cwd":"\(cwd)","sessionId":"s1"}
    """
}

private func assistantTextLine(at date: Date, sidechain: Bool = false, cwd: String = "/Users/k/Documents/CODE/teebe") -> String {
    """
    {"parentUuid":"u2","isSidechain":\(sidechain),"type":"assistant",\
    "message":{"role":"assistant","content":[{"type":"text","text":"Done — here is the answer."}],"stop_reason":"end_turn"},\
    "uuid":"a2","timestamp":"\(iso(date))","cwd":"\(cwd)","sessionId":"s1"}
    """
}

/// One content block of an assistant message. Claude Code writes every block of
/// a message as its own line sharing `message.id`; main-chain lines carry the
/// message's final `stop_reason`, subagent lines are written while the message
/// still streams (`stop_reason` null) until the final one.
private func assistantBlockLine(
    _ block: String, stop: String?, at date: Date, sidechain: Bool = false,
    cwd: String = "/Users/k/Documents/CODE/teebe"
) -> String {
    let content = block == "thinking"
        ? #"{"type":"thinking","thinking":"Let me check.","signature":"sig"}"#
        : #"{"type":"text","text":"Checking the tests first."}"#
    let stopJSON = stop.map { "\"\($0)\"" } ?? "null"
    return """
    {"parentUuid":"u1","isSidechain":\(sidechain),"type":"assistant",\
    "message":{"model":"claude-sonnet","id":"msg_1","type":"message","role":"assistant",\
    "content":[\(content)],"stop_reason":\(stopJSON),"stop_sequence":null},\
    "uuid":"a3","timestamp":"\(iso(date))","cwd":"\(cwd)","sessionId":"s1"}
    """
}

/// One tool_use block line; parallel calls of one message share `messageID`.
private func toolCallLine(
    _ name: String, input: String = "{}", messageID: String = "msg_2", at date: Date, sidechain: Bool = false
) -> String {
    """
    {"parentUuid":"u1","isSidechain":\(sidechain),"type":"assistant",\
    "message":{"model":"claude-sonnet","id":"\(messageID)","type":"message","role":"assistant",\
    "content":[{"type":"tool_use","id":"toolu_\(name)","name":"\(name)","input":\(input)}],\
    "stop_reason":"tool_use","stop_sequence":null},\
    "uuid":"a5","timestamp":"\(iso(date))","cwd":"/Users/k/Documents/CODE/teebe","sessionId":"s1"}
    """
}

/// The synthetic message Claude Code logs when a request fails (API error,
/// usage limit, not logged in): the turn is over.
private func apiErrorLine(at date: Date) -> String {
    """
    {"parentUuid":"u1","isSidechain":false,"type":"assistant",\
    "message":{"model":"<synthetic>","role":"assistant","stop_reason":"stop_sequence","type":"message",\
    "content":[{"type":"text","text":"API Error: 500 Internal server error"}]},\
    "isApiErrorMessage":true,"uuid":"a4","timestamp":"\(iso(date))","cwd":"/Users/k/Documents/CODE/teebe","sessionId":"s1"}
    """
}

/// What Claude Code logs when the user presses Esc mid-turn.
private func interruptLine(_ text: String = "[Request interrupted by user]", at date: Date) -> String {
    """
    {"parentUuid":"a1","isSidechain":false,"type":"user",\
    "message":{"role":"user","content":[{"type":"text","text":"\(text)"}]},\
    "uuid":"u5","timestamp":"\(iso(date))","cwd":"/Users/k/Documents/CODE/teebe","sessionId":"s1"}
    """
}

/// A slash command run locally (`/model`, `/cost`…): logged as user lines, but
/// the model never answers them.
private func localCommandLines(at date: Date) -> [String] {
    let tail = #""uuid":"u6","timestamp":"\#(iso(date))","cwd":"/Users/k/Documents/CODE/teebe","sessionId":"s1"}"#
    return [
        #"{"parentUuid":"a2","isSidechain":false,"type":"user","message":{"role":"user","content":"<local-command-caveat>Caveat: The messages below were generated by the user while running local commands. DO NOT respond to these messages or otherwise consider them in your response unless the user explicitly asks you to.</local-command-caveat>"},"isMeta":true,"#
            + tail,
        #"{"parentUuid":"u6","isSidechain":false,"type":"user","message":{"role":"user","content":"<command-name>/model</command-name>\n            <command-message>model</command-message>\n            <command-args></command-args>"},"#
            + tail,
        #"{"parentUuid":"u6","isSidechain":false,"type":"user","message":{"role":"user","content":"<local-command-stdout>Set model to Sonnet</local-command-stdout>"},"#
            + tail
    ]
}

private let metaLines = [
    #"{"type":"last-prompt","leafUuid":"x","sessionId":"s1"}"#,
    #"{"type":"mode","mode":"normal","sessionId":"s1"}"#,
    #"{"type":"permission-mode","permissionMode":"auto","sessionId":"s1"}"#,
    #"{"type":"file-history-snapshot","messageId":"m1","snapshot":{},"isSnapshotUpdate":false}"#,
    #"{"parentUuid":null,"isSidechain":false,"attachment":{"type":"hook_success"},"type":"attachment","uuid":"at1","timestamp":"2026-07-17T10:12:43.312Z"}"#,
    #"{"type":"summary","summary":"Earlier context","leafUuid":"x"}"#
]

// MARK: - Project dir encoding

@Suite("ClaudeProjects path encoding")
struct ClaudeProjectsPathTests {
    @Test("plain repo path encodes slashes to dashes")
    func plainPath() {
        #expect(AgentSessionScanner.projectDirName(forWorktreePath: "/Users/k/Documents/CODE/teebe")
            == "-Users-k-Documents-CODE-teebe")
    }

    @Test("dots and other non-alphanumerics also become dashes")
    func dottedPath() {
        #expect(AgentSessionScanner.projectDirName(forWorktreePath: "/Users/k/katast/.claude/worktrees/dev")
            == "-Users-k-katast--claude-worktrees-dev")
        #expect(AgentSessionScanner.projectDirName(forWorktreePath: "/Users/k/my_repo v2")
            == "-Users-k-my-repo-v2")
    }
}

// MARK: - Entry parsing

@Suite("AgentSessionEntry parsing")
struct AgentSessionEntryTests {
    let date = Date(timeIntervalSince1970: 1_784_000_000)

    @Test("human prompt (string content) parses as humanPrompt")
    func humanPrompt() throws {
        let entry = try #require(AgentSessionEntry.parse(line: humanPromptLine(at: date)))
        #expect(entry.kind == .humanPrompt)
        #expect(abs(entry.timestamp.timeIntervalSince(date)) < 1)
        #expect(entry.isSidechain == false)
    }

    @Test("user entry carrying a tool_result parses as toolResult")
    func toolResult() throws {
        let entry = try #require(AgentSessionEntry.parse(line: toolResultLine(at: date)))
        #expect(entry.kind == .toolResult)
    }

    @Test("assistant message with a tool_use block parses as assistantToolUse")
    func assistantToolUse() throws {
        let entry = try #require(AgentSessionEntry.parse(line: assistantToolUseLine(at: date)))
        #expect(entry.kind == .assistantToolUse)
    }

    @Test("assistant message with only text parses as assistantText")
    func assistantText() throws {
        let entry = try #require(AgentSessionEntry.parse(line: assistantTextLine(at: date)))
        #expect(entry.kind == .assistantText)
    }

    @Test("a text or thinking block of a message that goes on to call a tool is mid-turn", arguments: [
        "text", "thinking"
    ])
    func blockBeforeToolUse(block: String) throws {
        let entry = try #require(AgentSessionEntry.parse(line: assistantBlockLine(block, stop: "tool_use", at: date)))
        #expect(entry.kind == .assistantPartial)
    }

    @Test("a block written while its message still streams (null stop_reason) is mid-turn")
    func streamingBlock() throws {
        let entry = try #require(AgentSessionEntry.parse(
            line: assistantBlockLine("text", stop: nil, at: date, sidechain: true)))
        #expect(entry.kind == .assistantPartial)
    }

    @Test("a block of the turn's final message ends the turn", arguments: ["text", "thinking"])
    func finalMessageBlock(block: String) throws {
        let entry = try #require(AgentSessionEntry.parse(line: assistantBlockLine(block, stop: "end_turn", at: date)))
        #expect(entry.kind == .assistantText)
    }

    @Test("a synthetic API-error message ends the turn")
    func apiError() throws {
        let entry = try #require(AgentSessionEntry.parse(line: apiErrorLine(at: date)))
        #expect(entry.kind == .assistantText)
    }

    @Test("an interrupt marker parses as interrupted", arguments: [
        "[Request interrupted by user]", "[Request interrupted by user for tool use]"
    ])
    func interrupt(text: String) throws {
        let entry = try #require(AgentSessionEntry.parse(line: interruptLine(text, at: date)))
        #expect(entry.kind == .interrupted)
    }

    @Test("local slash-command lines are not entries — the model never answers them")
    func localCommandsAreNil() {
        for line in localCommandLines(at: date) {
            #expect(AgentSessionEntry.parse(line: line) == nil, "should ignore: \(line.prefix(90))")
        }
    }

    @Test("the summary a compaction writes is not a prompt — it neither starts nor ends a turn")
    func compactSummaryIsNil() {
        let line = """
        {"parentUuid":"c1","isSidechain":false,"type":"user","message":{"role":"user",\
        "content":"This session is being continued from a previous conversation that ran out of context."},\
        "isVisibleInTranscriptOnly":true,"isCompactSummary":true,"uuid":"u7",\
        "timestamp":"\(iso(date))","cwd":"/Users/k/Documents/CODE/teebe","sessionId":"s1"}
        """
        #expect(AgentSessionEntry.parse(line: line) == nil)
    }

    @Test("a tool_use line carries its message id and each call's name and timeout")
    func toolCalls() throws {
        let line = toolCallLine("Bash", input: #"{"command":"swift build","timeout":480000}"#, messageID: "msg_9", at: date)
        let entry = try #require(AgentSessionEntry.parse(line: line))
        #expect(entry.messageID == "msg_9")
        #expect(entry.toolCalls == [AgentSessionEntry.ToolCall(name: "Bash", timeout: 480)])
    }

    @Test("meta / non-message lines parse to nil")
    func metaLinesAreNil() {
        for line in metaLines {
            #expect(AgentSessionEntry.parse(line: line) == nil, "should ignore: \(line.prefix(40))")
        }
        #expect(AgentSessionEntry.parse(line: "not json at all") == nil)
        #expect(AgentSessionEntry.parse(line: "") == nil)
    }

    @Test("missing timestamp parses to nil")
    func missingTimestamp() {
        let line = #"{"type":"user","message":{"role":"user","content":"hi"},"uuid":"u9"}"#
        #expect(AgentSessionEntry.parse(line: line) == nil)
    }

    @Test("sidechain flag is carried through")
    func sidechainFlag() throws {
        let entry = try #require(AgentSessionEntry.parse(line: assistantTextLine(at: date, sidechain: true)))
        #expect(entry.isSidechain == true)
    }

    @Test("cwd is carried through; missing cwd parses to nil")
    func cwdCarried() throws {
        let entry = try #require(AgentSessionEntry.parse(
            line: assistantToolUseLine(at: date, cwd: "/repo/.claude/worktrees/audit/web")))
        #expect(entry.cwd == "/repo/.claude/worktrees/audit/web")
        let noCwd = #"{"type":"user","message":{"role":"user","content":"hi"},"uuid":"u9","timestamp":"2026-07-17T10:12:43.312Z"}"#
        #expect(AgentSessionEntry.parse(line: noCwd)?.cwd == nil)
    }
}

// MARK: - State derivation

@Suite("AgentStateDeriver")
struct AgentStateDeriverTests {
    let now = Date(timeIntervalSince1970: 1_784_000_000)
    let thresholds = AgentStatusThresholds(stall: 600, idle: 1_800)

    func entry(_ kind: AgentSessionEntry.Kind, age: TimeInterval) -> AgentSessionEntry {
        AgentSessionEntry(kind: kind, timestamp: now.addingTimeInterval(-age), isSidechain: false)
    }

    @Test("no entry means idle")
    func noEntry() {
        #expect(AgentStateDeriver.derive(lastEntry: nil, now: now, thresholds: thresholds) == .idle)
    }

    @Test("fresh assistant final text means the turn ended — needs attention")
    func turnEnded() {
        #expect(AgentStateDeriver.derive(lastEntry: entry(.assistantText, age: 5), now: now, thresholds: thresholds)
            == .needsAttention)
    }

    @Test("fresh mid-turn entries mean working", arguments: [
        AgentSessionEntry.Kind.humanPrompt, .toolResult, .assistantToolUse
    ])
    func working(kind: AgentSessionEntry.Kind) {
        #expect(AgentStateDeriver.derive(lastEntry: entry(kind, age: 30), now: now, thresholds: thresholds)
            == .working)
    }

    @Test("a mid-message block means working")
    func partialIsWorking() {
        #expect(AgentStateDeriver.derive(lastEntry: entry(.assistantPartial, age: 5), now: now, thresholds: thresholds)
            == .working)
    }

    @Test("an interrupted turn waits on the user")
    func interruptedNeedsAttention() {
        #expect(AgentStateDeriver.derive(lastEntry: entry(.interrupted, age: 5), now: now, thresholds: thresholds)
            == .needsAttention)
    }

    @Test("a mid-turn entry past the stall threshold needs attention")
    func stalled() {
        #expect(AgentStateDeriver.derive(lastEntry: entry(.assistantToolUse, age: 700), now: now, thresholds: thresholds)
            == .needsAttention)
    }

    func pending(_ calls: [(String, TimeInterval?)], age: TimeInterval) -> AgentActivityState {
        var pending = entry(.assistantToolUse, age: age)
        pending.toolCalls = calls.map { AgentSessionEntry.ToolCall(name: $0.0, timeout: $0.1) }
        return AgentStateDeriver.derive(lastEntry: pending, now: now, thresholds: thresholds)
    }

    @Test("a pending question to the user waits on the user at once", arguments: ["AskUserQuestion", "ExitPlanMode"])
    func questionTool(name: String) {
        #expect(pending([(name, nil)], age: 2) == .needsAttention)
    }

    @Test("a near-instant tool still pending past the quick window is a permission prompt")
    func quickToolPending() {
        #expect(pending([("Edit", nil)], age: 30) == .working)
        #expect(pending([("Edit", nil)], age: 90) == .needsAttention)
    }

    @Test("a quick tool pending beside a slow sibling follows the slow one")
    func mixedParallelCalls() {
        #expect(pending([("Bash", nil), ("Read", nil)], age: 90) == .working)
    }

    @Test("a long tool call keeps working until the general stall")
    func longToolWorks() {
        #expect(pending([("Bash", nil)], age: 500) == .working)
        #expect(pending([("mcp__server__audit", nil)], age: 500) == .working)
        #expect(pending([("mcp__server__audit", nil)], age: 700) == .needsAttention)
    }

    @Test("a command with a longer timeout than the stall keeps working until that timeout")
    func explicitTimeout() {
        #expect(pending([("Bash", 900)], age: 700) == .working)
        #expect(pending([("Bash", 900)], age: 1_000) == .needsAttention)
    }

    @Test("anything past the idle threshold is idle", arguments: [
        AgentSessionEntry.Kind.humanPrompt, .toolResult, .assistantToolUse, .assistantText
    ])
    func pastIdle(kind: AgentSessionEntry.Kind) {
        #expect(AgentStateDeriver.derive(lastEntry: entry(kind, age: 1_801), now: now, thresholds: thresholds)
            == .idle)
    }
}

// MARK: - Scanner (filesystem integration)

@Suite("AgentSessionScanner")
struct AgentSessionScannerTests {
    let now = Date(timeIntervalSince1970: 1_784_000_000)
    let worktreePath = "/Users/k/Documents/CODE/teebe"

    /// A throwaway projects root with a project dir for `worktreePath`.
    struct Fixture {
        var scanner: AgentSessionScanner
        var root: URL
        var dir: URL
    }

    func makeFixture(tailBytes: Int = 256 * 1_024) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("teebe-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let projectDir = root.appendingPathComponent(
            AgentSessionScanner.projectDirName(forWorktreePath: worktreePath), isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let scanner = AgentSessionScanner(
            projectsRoot: root, thresholds: AgentStatusThresholds(stall: 600, idle: 1_800),
            tailBytes: tailBytes)
        return Fixture(scanner: scanner, root: root, dir: projectDir)
    }

    func write(_ lines: [String], to url: URL, mtime: Date? = nil) throws {
        try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
        if let mtime {
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        }
    }

    @Test("no project dir for the worktree means idle")
    func noProjectDir() throws {
        let fx = try makeFixture()
        #expect(fx.scanner.state(forWorktreePath: "/nowhere/else", now: now) == .idle)
        try? FileManager.default.removeItem(at: fx.root)
    }

    @Test("session ending in a tool_use is working")
    func workingSession() throws {
        let fx = try makeFixture()
        try write(
            [humanPromptLine(at: now.addingTimeInterval(-60)), assistantToolUseLine(at: now.addingTimeInterval(-5))],
            to: fx.dir.appendingPathComponent("s1.jsonl"))
        #expect(fx.scanner.state(forWorktreePath: worktreePath, now: now) == .working)
        try? FileManager.default.removeItem(at: fx.root)
    }

    @Test("session ending in final assistant text needs attention")
    func finishedSession() throws {
        let fx = try makeFixture()
        try write(
            [humanPromptLine(at: now.addingTimeInterval(-120)), assistantTextLine(at: now.addingTimeInterval(-10))],
            to: fx.dir.appendingPathComponent("s1.jsonl"))
        #expect(fx.scanner.state(forWorktreePath: worktreePath, now: now) == .needsAttention)
        try? FileManager.default.removeItem(at: fx.root)
    }

    @Test("trailing sidechain entries are skipped — main chain decides")
    func sidechainSkipped() throws {
        let fx = try makeFixture()
        try write(
            [
                assistantToolUseLine(at: now.addingTimeInterval(-30)),
                assistantTextLine(at: now.addingTimeInterval(-4), sidechain: true)
            ],
            to: fx.dir.appendingPathComponent("s1.jsonl"))
        #expect(fx.scanner.state(forWorktreePath: worktreePath, now: now) == .working)
        try? FileManager.default.removeItem(at: fx.root)
    }

    @Test("trailing meta lines are skipped")
    func metaSkipped() throws {
        let fx = try makeFixture()
        try write(
            [assistantTextLine(at: now.addingTimeInterval(-10))] + metaLines,
            to: fx.dir.appendingPathComponent("s1.jsonl"))
        #expect(fx.scanner.state(forWorktreePath: worktreePath, now: now) == .needsAttention)
        try? FileManager.default.removeItem(at: fx.root)
    }

    @Test("the most recently modified session file wins")
    func newestFileWins() throws {
        let fx = try makeFixture()
        try write(
            [assistantTextLine(at: now.addingTimeInterval(-900))],
            to: fx.dir.appendingPathComponent("old.jsonl"), mtime: now.addingTimeInterval(-900))
        try write(
            [assistantToolUseLine(at: now.addingTimeInterval(-5))],
            to: fx.dir.appendingPathComponent("new.jsonl"), mtime: now.addingTimeInterval(-5))
        #expect(fx.scanner.state(forWorktreePath: worktreePath, now: now) == .working)
        try? FileManager.default.removeItem(at: fx.root)
    }

    @Test("a session file idle-old by mtime is idle without reading it")
    func staleFileIsIdle() throws {
        let fx = try makeFixture()
        try write(
            [assistantTextLine(at: now.addingTimeInterval(-7_200))],
            to: fx.dir.appendingPathComponent("s1.jsonl"), mtime: now.addingTimeInterval(-7_200))
        #expect(fx.scanner.state(forWorktreePath: worktreePath, now: now) == .idle)
        try? FileManager.default.removeItem(at: fx.root)
    }

    @Test("a tail window that opens mid-multibyte-character still parses the entries after it")
    func tailBoundaryMidCharacter() throws {
        // First line is emoji ballast; the real entry is the final line. Pick a
        // tail size that (a) covers the whole entry line and (b) makes the tail
        // offset land strictly inside one 4-byte emoji — a whole-buffer UTF-8
        // decode of such a tail fails, which must not blank the verdict.
        let entryLine = assistantToolUseLine(at: now.addingTimeInterval(-5))
        let ballast = String(repeating: "🦊", count: 300)
        let content = ballast + "\n" + entryLine + "\n"
        let size = content.utf8.count
        var tail = entryLine.utf8.count + 16
        while (size - tail) % 4 != 2 { tail += 1 }   // offset 2 bytes into an emoji

        let fx = try makeFixture(tailBytes: tail)
        let url = fx.dir.appendingPathComponent("s1.jsonl")
        try content.write(to: url, atomically: true, encoding: .utf8)
        #expect(fx.scanner.state(forWorktreePath: worktreePath, now: now) == .working)
        try? FileManager.default.removeItem(at: fx.root)
    }

    @Test("a message whose text block has landed but whose tool call has not is still working")
    func midMessageIsWorking() throws {
        let fx = try makeFixture()
        try write(
            [humanPromptLine(at: now.addingTimeInterval(-20)),
             assistantBlockLine("thinking", stop: "tool_use", at: now.addingTimeInterval(-9)),
             assistantBlockLine("text", stop: "tool_use", at: now.addingTimeInterval(-6))],
            to: fx.dir.appendingPathComponent("s1.jsonl"))
        #expect(fx.scanner.state(forWorktreePath: worktreePath, now: now) == .working)
        try? FileManager.default.removeItem(at: fx.root)
    }

    @Test("a local slash command after the turn ended keeps it waiting, not working")
    func localCommandAfterTurn() throws {
        let fx = try makeFixture()
        try write(
            [assistantTextLine(at: now.addingTimeInterval(-60))] + localCommandLines(at: now.addingTimeInterval(-5)),
            to: fx.dir.appendingPathComponent("s1.jsonl"))
        #expect(fx.scanner.state(forWorktreePath: worktreePath, now: now) == .needsAttention)
        try? FileManager.default.removeItem(at: fx.root)
    }

    @Test("an interrupted turn waits on the user")
    func interruptedTurn() throws {
        let fx = try makeFixture()
        try write(
            [assistantToolUseLine(at: now.addingTimeInterval(-20)), interruptLine(at: now.addingTimeInterval(-10))],
            to: fx.dir.appendingPathComponent("s1.jsonl"))
        #expect(fx.scanner.state(forWorktreePath: worktreePath, now: now) == .needsAttention)
        try? FileManager.default.removeItem(at: fx.root)
    }

    @Test("parallel calls: a pending quick call on the last line doesn't hide a slow sibling")
    func parallelToolCalls() throws {
        let fx = try makeFixture()
        try write(
            [toolCallLine("Bash", input: #"{"command":"swift test"}"#, at: now.addingTimeInterval(-121)),
             toolCallLine("Read", input: #"{"file_path":"/tmp/x"}"#, at: now.addingTimeInterval(-120))],
            to: fx.dir.appendingPathComponent("s1.jsonl"))
        #expect(fx.scanner.state(forWorktreePath: worktreePath, now: now) == .working)
        try? FileManager.default.removeItem(at: fx.root)
    }

    @Test("an empty or meta-only session file is idle")
    func emptyFileIsIdle() throws {
        let fx = try makeFixture()
        try write(metaLines, to: fx.dir.appendingPathComponent("s1.jsonl"))
        #expect(fx.scanner.state(forWorktreePath: worktreePath, now: now) == .idle)
        try? FileManager.default.removeItem(at: fx.root)
    }
}

// MARK: - Scanner worktree attribution (entry cwd, not launch dir)

@Suite("AgentSessionScanner worktree attribution")
struct AgentScannerAttributionTests {
    let now = Date(timeIntervalSince1970: 1_784_000_000)
    // The linked worktree lives *under* the primary (teebe's own layout for
    // agent-created worktrees), so attribution must pick the deepest match.
    let primary = "/Users/k/Documents/CODE/teebe"
    let linked = "/Users/k/Documents/CODE/teebe/.claude/worktrees/audit"
    var paths: [String] { [primary, linked] }

    struct Fixture {
        var scanner: AgentSessionScanner
        var root: URL
        var primaryDir: URL
    }

    func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("teebe-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let primaryDir = root.appendingPathComponent(
            AgentSessionScanner.projectDirName(forWorktreePath: primary), isDirectory: true)
        try FileManager.default.createDirectory(at: primaryDir, withIntermediateDirectories: true)
        let scanner = AgentSessionScanner(
            projectsRoot: root, thresholds: AgentStatusThresholds(stall: 600, idle: 1_800))
        return Fixture(scanner: scanner, root: root, primaryDir: primaryDir)
    }

    func write(_ lines: [String], to url: URL, mtime: Date) throws {
        try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
    }

    @Test("a session launched in the primary but running inside a linked worktree badges the worktree")
    func sessionFollowsCwd() throws {
        let fx = try makeFixture()
        // Entries' cwd is a *subdirectory* of the linked worktree, as real
        // sessions record (the agent cd'd into web/).
        try write(
            [assistantToolUseLine(at: now.addingTimeInterval(-5), cwd: linked + "/web")],
            to: fx.primaryDir.appendingPathComponent("s1.jsonl"), mtime: now.addingTimeInterval(-5))
        let states = fx.scanner.states(forWorktreePaths: paths, now: now)
        #expect(states[linked] == .working)
        #expect(states[primary] == .idle)
        try? FileManager.default.removeItem(at: fx.root)
    }

    @Test("a cwd outside every known worktree falls back to the launch dir")
    func unknownCwdFallsBack() throws {
        let fx = try makeFixture()
        try write(
            [assistantToolUseLine(at: now.addingTimeInterval(-5), cwd: "/somewhere/else")],
            to: fx.primaryDir.appendingPathComponent("s1.jsonl"), mtime: now.addingTimeInterval(-5))
        let states = fx.scanner.states(forWorktreePaths: paths, now: now)
        #expect(states[primary] == .working)
        #expect(states[linked] == .idle)
        try? FileManager.default.removeItem(at: fx.root)
    }

    @Test("sessions for different worktrees under one project dir badge independently")
    func concurrentSessions() throws {
        let fx = try makeFixture()
        try write(
            [assistantTextLine(at: now.addingTimeInterval(-60), cwd: primary)],
            to: fx.primaryDir.appendingPathComponent("s1.jsonl"), mtime: now.addingTimeInterval(-60))
        try write(
            [assistantToolUseLine(at: now.addingTimeInterval(-5), cwd: linked)],
            to: fx.primaryDir.appendingPathComponent("s2.jsonl"), mtime: now.addingTimeInterval(-5))
        let states = fx.scanner.states(forWorktreePaths: paths, now: now)
        #expect(states[primary] == .needsAttention)
        #expect(states[linked] == .working)
        try? FileManager.default.removeItem(at: fx.root)
    }

    @Test("for the same worktree the newer session's verdict wins")
    func newerSessionWins() throws {
        let fx = try makeFixture()
        try write(
            [assistantTextLine(at: now.addingTimeInterval(-900), cwd: linked)],
            to: fx.primaryDir.appendingPathComponent("old.jsonl"), mtime: now.addingTimeInterval(-900))
        try write(
            [assistantToolUseLine(at: now.addingTimeInterval(-5), cwd: linked)],
            to: fx.primaryDir.appendingPathComponent("new.jsonl"), mtime: now.addingTimeInterval(-5))
        let states = fx.scanner.states(forWorktreePaths: paths, now: now)
        #expect(states[linked] == .working)
        try? FileManager.default.removeItem(at: fx.root)
    }
}

// MARK: - Scanner subagents (`<project>/<sessionId>/subagents/agent-*.jsonl`)

@Suite("AgentSessionScanner subagents")
struct AgentScannerSubagentTests {
    let now = Date(timeIntervalSince1970: 1_784_000_000)
    let primary = "/Users/k/Documents/CODE/teebe"
    let linked = "/Users/k/Documents/CODE/teebe/.claude/worktrees/audit"
    var paths: [String] { [primary, linked] }

    struct Fixture {
        var scanner: AgentSessionScanner
        var root: URL
        var primaryDir: URL
    }

    func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("teebe-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let primaryDir = root.appendingPathComponent(
            AgentSessionScanner.projectDirName(forWorktreePath: primary), isDirectory: true)
        try FileManager.default.createDirectory(at: primaryDir, withIntermediateDirectories: true)
        let scanner = AgentSessionScanner(
            projectsRoot: root, thresholds: AgentStatusThresholds(stall: 600, idle: 1_800))
        return Fixture(scanner: scanner, root: root, primaryDir: primaryDir)
    }

    func write(_ lines: [String], to url: URL, mtime: Date) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
    }

    func subagentURL(_ fx: Fixture, session: String = "s1", agent: String = "agent-a1") -> URL {
        fx.primaryDir.appendingPathComponent(session, isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
            .appendingPathComponent("\(agent).jsonl")
    }

    @Test("a busy subagent badges the worktree it runs in, and its parent session's")
    func busySubagent() throws {
        let fx = try makeFixture()
        // The parent launched a background subagent and ended its turn.
        try write(
            [assistantTextLine(at: now.addingTimeInterval(-40), cwd: primary)],
            to: fx.primaryDir.appendingPathComponent("s1.jsonl"), mtime: now.addingTimeInterval(-40))
        try write(
            [assistantToolUseLine(at: now.addingTimeInterval(-8), sidechain: true, cwd: linked)],
            to: subagentURL(fx), mtime: now.addingTimeInterval(-8))
        let states = fx.scanner.states(forWorktreePaths: paths, now: now)
        #expect(states[linked] == .working)
        #expect(states[primary] == .working)
        try? FileManager.default.removeItem(at: fx.root)
    }

    @Test("a subagent mid-message (streaming block, null stop_reason) is working")
    func streamingSubagent() throws {
        let fx = try makeFixture()
        try write(
            [assistantBlockLine("text", stop: nil, at: now.addingTimeInterval(-3), sidechain: true, cwd: linked)],
            to: subagentURL(fx), mtime: now.addingTimeInterval(-3))
        #expect(fx.scanner.states(forWorktreePaths: paths, now: now)[linked] == .working)
        try? FileManager.default.removeItem(at: fx.root)
    }

    @Test("a finished subagent adds nothing — the parent's own verdict stands")
    func finishedSubagent() throws {
        let fx = try makeFixture()
        try write(
            [assistantTextLine(at: now.addingTimeInterval(-30), cwd: primary)],
            to: fx.primaryDir.appendingPathComponent("s1.jsonl"), mtime: now.addingTimeInterval(-30))
        try write(
            [assistantBlockLine("text", stop: "end_turn", at: now.addingTimeInterval(-35), sidechain: true, cwd: linked)],
            to: subagentURL(fx), mtime: now.addingTimeInterval(-35))
        let states = fx.scanner.states(forWorktreePaths: paths, now: now)
        #expect(states[primary] == .needsAttention)
        #expect(states[linked] == .idle)
        try? FileManager.default.removeItem(at: fx.root)
    }

    @Test("a subagent silent past the stall threshold is not counted as working")
    func stalledSubagent() throws {
        let fx = try makeFixture()
        try write(
            [assistantToolUseLine(at: now.addingTimeInterval(-900), sidechain: true, cwd: linked)],
            to: subagentURL(fx), mtime: now.addingTimeInterval(-900))
        #expect(fx.scanner.states(forWorktreePaths: paths, now: now)[linked] == .idle)
        try? FileManager.default.removeItem(at: fx.root)
    }
}

// MARK: - Live session registry (`~/.claude/sessions/<pid>.json`)

@Suite("AgentSessionScanner live registry")
struct AgentScannerRegistryTests {
    let now = Date(timeIntervalSince1970: 1_784_000_000)
    let worktree = "/Users/k/Documents/CODE/teebe"

    struct Fixture {
        var scanner: AgentSessionScanner
        var root: URL
        var projectDir: URL
        var sessionsDir: URL
    }

    /// `alive` lists the pids the fake process table reports as running.
    func makeFixture(alive: Set<Int32> = [101]) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("teebe-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let projectDir = root.appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(AgentSessionScanner.projectDirName(forWorktreePath: worktree), isDirectory: true)
        let sessionsDir = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        let scanner = AgentSessionScanner(
            projectsRoot: root.appendingPathComponent("projects", isDirectory: true),
            thresholds: AgentStatusThresholds(stall: 600, idle: 1_800),
            sessionsRoot: sessionsDir,
            isProcessAlive: { alive.contains($0) })
        return Fixture(scanner: scanner, root: root, projectDir: projectDir, sessionsDir: sessionsDir)
    }

    func writeLog(_ lines: [String], _ fx: Fixture, session: String = "s1", mtime: Date) throws {
        let url = fx.projectDir.appendingPathComponent("\(session).jsonl")
        try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
    }

    /// The registry file shape Claude Code writes (trimmed to what matters).
    func register(_ fx: Fixture, pid: Int32 = 101, session: String = "s1", status: String,
                  waitingFor: String? = nil, changedAt: Date) throws {
        let waiting = waitingFor.map { #","waitingFor":"\#($0)""# } ?? ""
        let json = """
        {"pid":\(pid),"sessionId":"\(session)","cwd":"\(worktree)","kind":"interactive","entrypoint":"cli",\
        "status":"\(status)"\(waiting),"statusUpdatedAt":\(Int(changedAt.timeIntervalSince1970 * 1_000))}
        """
        try json.write(to: fx.sessionsDir.appendingPathComponent("\(pid).json"), atomically: true, encoding: .utf8)
    }

    @Test("a live session waiting on a permission prompt needs attention although its log looks mid-tool")
    func permissionPrompt() throws {
        let fx = try makeFixture()
        try writeLog([toolCallLine("Bash", input: #"{"command":"rm -rf build"}"#, at: now.addingTimeInterval(-5))],
                     fx, mtime: now.addingTimeInterval(-5))
        try register(fx, status: "waiting", waitingFor: "permission prompt", changedAt: now.addingTimeInterval(-4))
        #expect(fx.scanner.state(forWorktreePath: worktree, now: now) == .needsAttention)
        try? FileManager.default.removeItem(at: fx.root)
    }

    @Test("a live busy session is working although its own turn ended (a background agent runs)")
    func busyAfterTurnEnd() throws {
        let fx = try makeFixture()
        try writeLog([assistantTextLine(at: now.addingTimeInterval(-300))], fx, mtime: now.addingTimeInterval(-300))
        try register(fx, status: "busy", changedAt: now.addingTimeInterval(-320))
        #expect(fx.scanner.state(forWorktreePath: worktree, now: now) == .working)
        try? FileManager.default.removeItem(at: fx.root)
    }

    @Test("a live busy session is working even when its log has been silent past the idle window")
    func busyWithOldLog() throws {
        let fx = try makeFixture()
        try writeLog([assistantTextLine(at: now.addingTimeInterval(-2_400))], fx, mtime: now.addingTimeInterval(-2_400))
        try register(fx, status: "busy", changedAt: now.addingTimeInterval(-2_500))
        #expect(fx.scanner.state(forWorktreePath: worktree, now: now) == .working)
        try? FileManager.default.removeItem(at: fx.root)
    }

    @Test("a live idle session whose log still looks mid-turn is waiting on the user")
    func idleOverridesStaleLog() throws {
        let fx = try makeFixture()
        try writeLog([assistantToolUseLine(at: now.addingTimeInterval(-40))], fx, mtime: now.addingTimeInterval(-40))
        try register(fx, status: "idle", changedAt: now.addingTimeInterval(-30))
        #expect(fx.scanner.state(forWorktreePath: worktree, now: now) == .needsAttention)
        try? FileManager.default.removeItem(at: fx.root)
    }

    @Test("a prompt logged after the registry last said idle is working — the log is ahead")
    func logAheadOfRegistry() throws {
        let fx = try makeFixture()
        try writeLog([humanPromptLine(at: now.addingTimeInterval(-1))], fx, mtime: now.addingTimeInterval(-1))
        try register(fx, status: "idle", changedAt: now.addingTimeInterval(-60))
        #expect(fx.scanner.state(forWorktreePath: worktree, now: now) == .working)
        try? FileManager.default.removeItem(at: fx.root)
    }

    @Test("a registry entry whose process is gone is ignored — the log decides")
    func deadProcessIgnored() throws {
        let fx = try makeFixture(alive: [])
        try writeLog([assistantTextLine(at: now.addingTimeInterval(-20))], fx, mtime: now.addingTimeInterval(-20))
        try register(fx, status: "busy", changedAt: now.addingTimeInterval(-60))
        #expect(fx.scanner.state(forWorktreePath: worktree, now: now) == .needsAttention)
        try? FileManager.default.removeItem(at: fx.root)
    }

    @Test("a subagent of a live session that is not busy is not running")
    func subagentOfIdleParent() throws {
        let fx = try makeFixture()
        try writeLog([assistantTextLine(at: now.addingTimeInterval(-60))], fx, mtime: now.addingTimeInterval(-60))
        let sub = fx.projectDir.appendingPathComponent("s1/subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try assistantToolUseLine(at: now.addingTimeInterval(-90), sidechain: true)
            .write(to: sub.appendingPathComponent("agent-a1.jsonl"), atomically: true, encoding: .utf8)
        try register(fx, status: "idle", changedAt: now.addingTimeInterval(-55))
        #expect(fx.scanner.state(forWorktreePath: worktree, now: now) == .needsAttention)
        try? FileManager.default.removeItem(at: fx.root)
    }
}
