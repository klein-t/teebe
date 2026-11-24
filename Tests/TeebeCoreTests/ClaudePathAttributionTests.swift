import Foundation
import Testing
@testable import TeebeCore

// Sanitised from real ~/.claude/projects session lines: a session started in one
// checkout that edits another through absolute paths.

private func stamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

private func toolUse(_ name: String, input: String, at date: Date, cwd: String, id: String = "msg_01") -> String {
    """
    {"parentUuid":"u1","isSidechain":false,"type":"assistant",\
    "message":{"model":"claude-opus","id":"\(id)","type":"message","role":"assistant",\
    "content":[{"type":"tool_use","id":"toolu_\(id)","name":"\(name)","input":\(input)}],\
    "stop_reason":"tool_use","stop_sequence":null},\
    "uuid":"a-\(id)","timestamp":"\(stamp(date))","cwd":"\(cwd)","sessionId":"s1","gitBranch":"main"}
    """
}

private func toolResult(at date: Date, cwd: String) -> String {
    """
    {"parentUuid":"a1","isSidechain":false,"type":"user",\
    "message":{"role":"user","content":[{"tool_use_id":"toolu_1","type":"tool_result","content":"ok"}]},\
    "uuid":"u2","timestamp":"\(stamp(date))","cwd":"\(cwd)","sessionId":"s1"}
    """
}

@Suite("Claude Code sessions are attributed by the paths they touch")
struct ClaudePathAttributionTests {
    let now = Date(timeIntervalSince1970: 1_784_000_000)
    let launch = "/Users/dev/code/teebe"
    let lens = "/private/tmp/acme-feature"
    let other = "/private/tmp/acme-hotfix"
    var paths: [String] { [launch, lens, other] }

    struct Fixture {
        var scanner: AgentSessionScanner
        var root: URL
        var launchDir: URL
    }

    func makeFixture(knownWorktrees: KnownWorktrees = KnownWorktrees()) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("teebe-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let launchDir = root.appendingPathComponent(
            AgentSessionScanner.projectDirName(forWorktreePath: launch), isDirectory: true)
        try FileManager.default.createDirectory(at: launchDir, withIntermediateDirectories: true)
        return Fixture(scanner: AgentSessionScanner(projectsRoot: root, knownWorktrees: knownWorktrees), root: root, launchDir: launchDir)
    }

    func write(_ lines: [String], _ fx: Fixture) throws {
        let url = fx.launchDir.appendingPathComponent("s1.jsonl")
        try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-2)], ofItemAtPath: url.path)
    }

    @Test("tool targets name the path a call works on")
    func targets() {
        #expect(AgentSessionEntry.target(ofToolInput: ["file_path": "/a/b.swift"]) == "/a/b.swift")
        #expect(AgentSessionEntry.target(ofToolInput: ["notebook_path": "/a/n.ipynb"]) == "/a/n.ipynb")
        #expect(AgentSessionEntry.target(ofToolInput: ["pattern": "x", "path": "/a/src"]) == "/a/src")
        #expect(AgentSessionEntry.target(ofToolInput: ["pattern": "x", "path": "src"]) == nil)
        #expect(AgentSessionEntry.target(ofToolInput: ["command": "cd /a/web && npm test"]) == "/a/web")
        #expect(AgentSessionEntry.target(ofToolInput: ["command": "git status; cd \"/a/b c\" && ls"]) == "/a/b c")
        #expect(AgentSessionEntry.target(ofToolInput: ["command": "swift test"]) == nil)
    }

    @Test("a session launched in one checkout that edits another badges the one it edits")
    func editsElsewhere() throws {
        let fx = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fx.root) }
        try write([
            toolUse("Edit", input: #"{"file_path":"\#(lens)/src/acme/api/v1/maps.py","old_string":"a","new_string":"b"}"#,
                    at: now.addingTimeInterval(-20), cwd: launch, id: "msg_01"),
            toolResult(at: now.addingTimeInterval(-19), cwd: launch),
            toolUse("Bash", input: #"{"command":"cd \#(lens) && pytest -q tests/api","timeout":600000}"#,
                    at: now.addingTimeInterval(-5), cwd: launch, id: "msg_02")
        ], fx)
        let states = fx.scanner.states(forWorktreePaths: paths, now: now)
        #expect(states[lens] == .working)
        #expect(states[launch] == .idle)
    }

    @Test("when it touches several worktrees the most recent target wins")
    func mostRecentTargetWins() throws {
        let fx = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fx.root) }
        try write([
            toolUse("Write", input: #"{"file_path":"\#(lens)/notes.md","content":"x"}"#,
                    at: now.addingTimeInterval(-40), cwd: launch, id: "msg_01"),
            toolResult(at: now.addingTimeInterval(-39), cwd: launch),
            toolUse("Read", input: #"{"file_path":"\#(other)/README.md"}"#,
                    at: now.addingTimeInterval(-5), cwd: launch, id: "msg_02")
        ], fx)
        let states = fx.scanner.states(forWorktreePaths: paths, now: now)
        #expect(states[other] == .working)
        #expect(states[lens] == .idle)
    }

    @Test("paths typed through the /tmp symlink still land on the /private/tmp worktree")
    func tmpSymlink() throws {
        let fx = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fx.root) }
        try write([
            toolUse("Edit", input: #"{"file_path":"/tmp/acme-feature/web/lib/a.ts","old_string":"a","new_string":"b"}"#,
                    at: now.addingTimeInterval(-5), cwd: launch)
        ], fx)
        #expect(fx.scanner.states(forWorktreePaths: paths, now: now)[lens] == .working)
    }

    @Test("targets outside every known worktree, or older than the window, leave the cwd in charge")
    func fallsBackToCwd() throws {
        let fx = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fx.root) }
        try write([
            toolUse("Edit", input: #"{"file_path":"\#(lens)/old.py","old_string":"a","new_string":"b"}"#,
                    at: now.addingTimeInterval(-900), cwd: launch, id: "msg_01"),
            toolResult(at: now.addingTimeInterval(-899), cwd: launch),
            toolUse("Read", input: #"{"file_path":"/Users/dev/.claude/CLAUDE.md"}"#,
                    at: now.addingTimeInterval(-5), cwd: launch, id: "msg_02")
        ], fx)
        let states = fx.scanner.states(forWorktreePaths: paths, now: now)
        #expect(states[launch] == .working)
        #expect(states[lens] == .idle)
    }

    @Test("another known repository owns a session by targets or entry cwd", arguments: [true, false])
    func knownRepositoryOwnsSession(byTarget: Bool) throws {
        let known = KnownWorktrees()
        let fx = try makeFixture(knownWorktrees: known)
        defer { try? FileManager.default.removeItem(at: fx.root) }
        try write([toolUse("Read", input: byTarget ? #"{"file_path":"\#(lens)/file.swift"}"# : #"{"file_path":"/outside/file"}"#,
                           at: now.addingTimeInterval(-5), cwd: byTarget ? launch : lens)], fx)
        let original = fx.scanner.snapshot(forWorktreePaths: [launch], now: now)
        #expect(original.states[launch] == .working)
        #expect(original.contexts[launch] != nil)
        known.update([launch, lens])
        let local = fx.scanner.snapshot(forWorktreePaths: [launch], now: now)
        #expect(local.states == [launch: .idle])
        #expect(local.contexts.isEmpty)
        #expect(fx.scanner.turnEnds(forWorktreePaths: [launch], now: now).isEmpty)
        let all = fx.scanner.snapshot(forWorktreePaths: [launch, lens], now: now)
        #expect(all.states == [launch: .idle, lens: .working])
        #expect(Set(all.contexts.keys) == [lens])
    }

    @Test("targets and cwd outside all known worktrees keep the launch fallback")
    func unknownWorktreeKeepsLaunchFallback() throws {
        let known = KnownWorktrees()
        known.update([launch, lens])
        let fx = try makeFixture(knownWorktrees: known)
        defer { try? FileManager.default.removeItem(at: fx.root) }
        try write([toolUse("Read", input: #"{"file_path":"/outside/file"}"#,
                           at: now.addingTimeInterval(-5), cwd: "/outside")], fx)
        let snapshot = fx.scanner.snapshot(forWorktreePaths: [launch], now: now)
        #expect(snapshot.states[launch] == .working)
        #expect(snapshot.contexts[launch] != nil)
    }

    @Test("a busy subagent in another repository marks only where it and its parent are owned, in every scan",
          arguments: [true, false], [true, false])
    func busySubagentInKnownRepository(byTarget: Bool, parentHere: Bool) throws {
        let known = KnownWorktrees()
        let fx = try makeFixture(knownWorktrees: known)
        defer { try? FileManager.default.removeItem(at: fx.root) }
        try write([toolResult(at: now.addingTimeInterval(-4_000), cwd: parentHere ? launch : lens)], fx)
        let directory = fx.launchDir.appendingPathComponent("s1/subagents")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("agent-child.jsonl")
        let line = toolUse("Read", input: byTarget ? #"{"file_path":"\#(lens)/file.swift"}"# : #"{"file_path":"/outside/file"}"#,
                           at: now.addingTimeInterval(-5), cwd: byTarget ? launch : lens)
            .replacingOccurrences(of: #""isSidechain":false"#, with: #""isSidechain":true"#)
        try (line + "\n").write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-2)], ofItemAtPath: file.path)
        // Nothing else known: the launch worktree is all there is to mark.
        #expect(fx.scanner.states(forWorktreePaths: [launch], now: now)[launch] == .working)
        known.update([launch, lens])
        // A parent owned here is still busy while its subagent works elsewhere;
        // the subagent itself no longer falls back to the launch worktree.
        let here: AgentActivityState = parentHere ? .working : .idle
        #expect(fx.scanner.states(forWorktreePaths: [launch], now: now) == [launch: here])
        #expect(fx.scanner.states(forWorktreePaths: [launch, lens], now: now) == [launch: here, lens: .working])
    }
}
