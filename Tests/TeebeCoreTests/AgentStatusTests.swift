import Foundation
import Testing
@testable import TeebeCore

// MARK: - Fixture builders (mirror the real ~/.claude/projects/*.jsonl shapes)

private func iso(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

private func humanPromptLine(at date: Date, sidechain: Bool = false) -> String {
    """
    {"parentUuid":null,"isSidechain":\(sidechain),"type":"user",\
    "message":{"role":"user","content":"hey can u check the product"},\
    "uuid":"u1","timestamp":"\(iso(date))","origin":{"kind":"human"},"promptSource":"typed",\
    "cwd":"/Users/k/Documents/CODE/teebe","sessionId":"s1","gitBranch":"dev"}
    """
}

private func toolResultLine(at date: Date, sidechain: Bool = false) -> String {
    """
    {"parentUuid":"a1","isSidechain":\(sidechain),"type":"user",\
    "message":{"role":"user","content":[{"tool_use_id":"toolu_1","type":"tool_result","content":"ok"}]},\
    "uuid":"u2","timestamp":"\(iso(date))","cwd":"/Users/k/Documents/CODE/teebe","sessionId":"s1"}
    """
}

private func assistantToolUseLine(at date: Date, sidechain: Bool = false) -> String {
    """
    {"parentUuid":"u1","isSidechain":\(sidechain),"type":"assistant",\
    "message":{"role":"assistant","content":[{"type":"text","text":"Looking."},\
    {"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls"}}]},\
    "uuid":"a1","timestamp":"\(iso(date))","cwd":"/Users/k/Documents/CODE/teebe","sessionId":"s1"}
    """
}

private func assistantTextLine(at date: Date, sidechain: Bool = false) -> String {
    """
    {"parentUuid":"u2","isSidechain":\(sidechain),"type":"assistant",\
    "message":{"role":"assistant","content":[{"type":"text","text":"Done — here is the answer."}]},\
    "uuid":"a2","timestamp":"\(iso(date))","cwd":"/Users/k/Documents/CODE/teebe","sessionId":"s1"}
    """
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

    @Test("a mid-turn entry past the stall threshold needs attention")
    func stalled() {
        #expect(AgentStateDeriver.derive(lastEntry: entry(.assistantToolUse, age: 700), now: now, thresholds: thresholds)
            == .needsAttention)
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

    func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("teebe-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let projectDir = root.appendingPathComponent(
            AgentSessionScanner.projectDirName(forWorktreePath: worktreePath), isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let scanner = AgentSessionScanner(
            projectsRoot: root, thresholds: AgentStatusThresholds(stall: 600, idle: 1_800))
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

    @Test("an empty or meta-only session file is idle")
    func emptyFileIsIdle() throws {
        let fx = try makeFixture()
        try write(metaLines, to: fx.dir.appendingPathComponent("s1.jsonl"))
        #expect(fx.scanner.state(forWorktreePath: worktreePath, now: now) == .idle)
        try? FileManager.default.removeItem(at: fx.root)
    }
}
