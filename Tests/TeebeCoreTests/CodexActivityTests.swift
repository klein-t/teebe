import Foundation
import Testing
@testable import TeebeCore

// MARK: - Rollout lines, sanitised from real Codex 0.155 rollouts

private func stamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

private enum Rollout {
    static func meta(id: String, cwd: String, source: String = #""cli""#, at date: Date) -> String {
        """
        {"timestamp":"\(stamp(date))","type":"session_meta","payload":{"session_id":"\(id)","id":"\(id)",\
        "timestamp":"\(stamp(date))","cwd":"\(cwd)","originator":"codex-tui","cli_version":"0.155.1",\
        "source":\(source),"thread_source":"user","model_provider":"openai",\
        "base_instructions":{"text":"You are Codex, a coding agent. \(String(repeating: "Be concise. ", count: 400))"}}}
        """
    }

    static func context(cwd: String, policy: String = "on-request", reviewer: String = "auto_review", at date: Date) -> String {
        """
        {"timestamp":"\(stamp(date))","type":"turn_context","payload":{"turn_id":"t1","cwd":"\(cwd)",\
        "current_date":"2026-09-25","timezone":"Europe/Rome","approval_policy":"\(policy)",\
        "approvals_reviewer":"\(reviewer)","sandbox_policy":{"type":"workspace-write","network_access":false},\
        "model":"gpt-6","effort":"high","summary":"auto"}}
        """
    }

    static func event(_ type: String, at date: Date) -> String {
        switch type {
        case "task_started":
            return #"{"timestamp":"\#(stamp(date))","ordinal":1,"type":"event_msg","payload":{"type":"task_started","# +
                #""turn_id":"t1","started_at":1790334924,"model_context_window":258400,"collaboration_mode_kind":"default"}}"#
        case "task_complete":
            return #"{"timestamp":"\#(stamp(date))","type":"event_msg","payload":{"type":"task_complete","turn_id":"t1","# +
                #""started_at":1790332881,"completed_at":1790332914,"duration_ms":32613,"last_agent_message":"Done."}}"#
        case "turn_aborted":
            return #"{"timestamp":"\#(stamp(date))","type":"event_msg","payload":{"type":"turn_aborted","turn_id":"t1","# +
                #""reason":"interrupted","started_at":1790151970,"completed_at":1790152060,"duration_ms":90002}}"#
        default:
            return #"{"timestamp":"\#(stamp(date))","type":"event_msg","payload":{"type":"\#(type)","info":null}}"#
        }
    }

    static func reasoning(at date: Date) -> String {
        #"{"timestamp":"\#(stamp(date))","type":"response_item","payload":{"type":"reasoning","id":"rs_1","# +
            #""summary":[],"encrypted_content":"gAAAAB"}}"#
    }

    /// A code-mode `exec` script that patches a file through an absolute path.
    static func patch(_ path: String, call: String, at date: Date) -> String {
        #"{"timestamp":"\#(stamp(date))","type":"response_item","payload":{"type":"custom_tool_call","id":"ctc_1","# +
            #""status":"completed","call_id":"\#(call)","name":"exec","# +
            #""input":"text(await tools.apply_patch(\"*** Begin Patch\\n*** Update File: \#(path)\\n@@\\n-a\\n+b\\n*** End Patch\"));\n"}}"#
    }

    /// A code-mode `exec` script running a command with an explicit workdir.
    static func command(workdir: String, escalated: Bool = false, call: String, at date: Date) -> String {
        let extra = escalated ? #",sandbox_permissions:\"require_escalated\",justification:\"push\""# : ""
        return #"{"timestamp":"\#(stamp(date))","type":"response_item","payload":{"type":"custom_tool_call","id":"ctc_2","# +
            #""status":"completed","call_id":"\#(call)","name":"exec","# +
            #""input":"text(await tools.exec_command({cmd:\"pytest -q\",workdir:\"\#(workdir)\",max_output_tokens:2200\#(extra)}));\n"}}"#
    }

    /// A direct `exec_command` function call (JSON arguments).
    static func execCommand(workdir: String, call: String, at date: Date) -> String {
        #"{"timestamp":"\#(stamp(date))","type":"response_item","payload":{"type":"function_call","name":"exec_command","# +
            #""arguments":"{\"cmd\":\"sed -n '1,220p' README.md\",\"workdir\":\"\#(workdir)\",\"yield_time_ms\":1000}","# +
            #""call_id":"\#(call)"}}"#
    }

    static func ask(call: String, at date: Date) -> String {
        #"{"timestamp":"\#(stamp(date))","type":"response_item","payload":{"type":"function_call","# +
            #""name":"request_user_input","arguments":"{\"questions\":[{\"title\":\"Which lens?\"}]}","call_id":"\#(call)"}}"#
    }

    static func output(call: String, custom: Bool = true, at date: Date) -> String {
        let type = custom ? "custom_tool_call_output" : "function_call_output"
        return #"{"timestamp":"\#(stamp(date))","type":"response_item","payload":{"type":"\#(type)","id":"o1","# +
            #""call_id":"\#(call)","output":[{"type":"input_text","text":"Script completed\nWall time 0.2 seconds"}]}}"#
    }

    static func fileChange(_ path: String, at date: Date) -> String {
        #"{"timestamp":"\#(stamp(date))","type":"event_msg","payload":{"type":"item_completed","thread_id":"x","# +
            #""turn_id":"t1","item":{"type":"FileChange","id":"fc1","status":"completed","stdout":"","stderr":"","# +
            #""changes":{"\#(path)":{"type":"add","content":"x"}}}}}"#
    }

    static func commandDone(cwd: String, at date: Date) -> String {
        #"{"timestamp":"\#(stamp(date))","type":"event_msg","payload":{"type":"item_completed","thread_id":"x","# +
            #""turn_id":"t1","item":{"type":"CommandExecution","id":"ce1","cwd":"file://\#(cwd)","# +
            #""command":["/bin/zsh","-lc","pytest -q"],"exit_code":0,"status":"completed"}}}"#
    }

    static func subagentSource(parent: String) -> String {
        #"{"subagent":{"thread_spawn":{"parent_thread_id":"\#(parent)","depth":1,"agent_path":"/root/backend","# +
            #""agent_nickname":"Volta","agent_role":null}}}"#
    }

    static let guardianSource = #"{"subagent":{"other":"guardian"}}"#
}

// MARK: - Parsing

@Suite("Codex rollout records")
struct CodexRolloutRecordTests {
    let now = Date(timeIntervalSince1970: 1_790_335_000)
    let lens = "/private/tmp/acme-feature"

    @Test("lifecycle, calls, outputs and targets are read from real record shapes")
    func parse() throws {
        let started = try #require(CodexRolloutRecord.parse(line: Rollout.event("task_started", at: now)))
        #expect(started.kind == .turnStarted)
        #expect(CodexRolloutRecord.parse(line: Rollout.event("task_complete", at: now))?.kind == .turnCompleted)
        #expect(CodexRolloutRecord.parse(line: Rollout.event("turn_aborted", at: now))?.kind == .turnAborted)
        #expect(CodexRolloutRecord.parse(line: Rollout.meta(id: "a", cwd: "/x", at: now)) == nil)

        let patch = try #require(CodexRolloutRecord.parse(line: Rollout.patch(lens + "/src/maps.py", call: "c1", at: now)))
        #expect(patch.kind == .toolCall(callID: "c1", question: false, escalated: false))
        #expect(patch.targets == [lens + "/src/maps.py"])
        let command = try #require(CodexRolloutRecord.parse(
            line: Rollout.command(workdir: lens, escalated: true, call: "c2", at: now)))
        #expect(command.kind == .toolCall(callID: "c2", question: false, escalated: true))
        #expect(command.targets == [lens])
        #expect(CodexRolloutRecord.parse(line: Rollout.execCommand(workdir: "/Users/dev/acme", call: "c3", at: now))?
            .targets == ["/Users/dev/acme"])
        #expect(CodexRolloutRecord.parse(line: Rollout.ask(call: "c4", at: now))?.kind
            == .toolCall(callID: "c4", question: true, escalated: false))
        #expect(CodexRolloutRecord.parse(line: Rollout.output(call: "c1", at: now))?.kind == .toolOutput(callID: "c1"))
        #expect(CodexRolloutRecord.parse(line: Rollout.fileChange(lens + "/web/a.ts", at: now))?.targets == [lens + "/web/a.ts"])
        #expect(CodexRolloutRecord.parse(line: Rollout.commandDone(cwd: lens, at: now))?.targets == ["file://" + lens])
        #expect(CodexRolloutRecord.parse(line: Rollout.context(cwd: "/x", reviewer: "user", at: now))?.kind
            == .turnContext(cwd: "/x", humanApproves: true))
        #expect(CodexRolloutRecord.parse(line: Rollout.context(cwd: "/x", at: now))?.kind
            == .turnContext(cwd: "/x", humanApproves: false))
    }

    @Test("a script's later calls are its newest targets")
    func scriptOrder() {
        let body = #"await tools.exec_command({cmd:"ls",workdir:"/a"}); await tools.apply_patch("*** Begin Patch\n*** Add File: /b/x.py\n+1")"#
        #expect(CodexRolloutRecord.callTargets(body) == ["/b/x.py", "/a"])
    }
}

// MARK: - Scanner

@Suite("Codex rollout scanner")
struct CodexRolloutScannerTests {
    let now = Date(timeIntervalSince1970: 1_790_335_000)
    let launch = "/Users/dev/code/teebe"
    let acme = "/Users/dev/acme"
    let lens = "/private/tmp/acme-feature"
    var acmePaths: [String] { [acme, lens] }

    struct Fixture {
        var root: URL
        var scanner: CodexRolloutScanner
    }

    func makeFixture(tailBytes: Int = 256 * 1_024) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("teebe-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Fixture(root: root, scanner: CodexRolloutScanner(sessionsRoot: root, tailBytes: tailBytes))
    }

    /// Writes a rollout in the date folder `daysAgo` before `now`.
    @discardableResult
    func write(_ lines: [String], id: String, _ fx: Fixture, daysAgo: Int = 0, mtime: Date? = nil) throws -> URL {
        let day = Calendar(identifier: .gregorian).date(byAdding: .day, value: -daysAgo, to: now) ?? now
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: day)
        let dir = fx.root.appendingPathComponent(String(format: "%04d/%02d/%02d", parts.year!, parts.month!, parts.day!))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("rollout-2026-09-25T11-13-32-\(id).jsonl")
        try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: mtime ?? now.addingTimeInterval(-1)], ofItemAtPath: url.path)
        return url
    }

    let parentID = "01a0d7d7-65f3-77e1-b9ae-fda843868332"
    let childID = "01a0d846-f616-7a53-b1ef-2eafab1f808b"
    let guardianID = "01a0d846-f674-7533-aab9-8df384a9a379"

    /// The user's case: a TUI launched in the teebe checkout editing another
    /// project's worktree through absolute paths, mid-turn.
    func userTurn(_ tail: [String]) -> [String] {
        [Rollout.meta(id: parentID, cwd: launch, at: now.addingTimeInterval(-600)),
         Rollout.context(cwd: launch, at: now.addingTimeInterval(-300)),
         Rollout.event("task_started", at: now.addingTimeInterval(-300))] + tail
    }

    @Test("a thread launched elsewhere that patches a worktree makes that worktree work")
    func editsElsewhere() throws {
        let fx = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fx.root) }
        try write(userTurn([
            Rollout.patch(lens + "/src/acme/api/v1/maps.py", call: "c1", at: now.addingTimeInterval(-30)),
            Rollout.output(call: "c1", at: now.addingTimeInterval(-29)),
            Rollout.reasoning(at: now.addingTimeInterval(-3))
        ]), id: parentID, fx)
        let states = fx.scanner.states(forWorktreePaths: acmePaths, now: now)
        #expect(states[lens] == .working)
        #expect(states[acme] == .idle)
        // Seen from the repo it was launched in, it is still that checkout's session.
        #expect(fx.scanner.states(forWorktreePaths: [launch], now: now)[launch] == .working)
    }

    @Test("a completed or interrupted turn waits for the user")
    func turnEnded() throws {
        for end in ["task_complete", "turn_aborted"] {
            let fx = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fx.root) }
            try write(userTurn([
                Rollout.command(workdir: lens, call: "c1", at: now.addingTimeInterval(-40)),
                Rollout.output(call: "c1", at: now.addingTimeInterval(-39)),
                Rollout.event(end, at: now.addingTimeInterval(-20)),
                Rollout.event("token_count", at: now.addingTimeInterval(-19))
            ]), id: parentID, fx)
            #expect(fx.scanner.states(forWorktreePaths: acmePaths, now: now)[lens] == .needsAttention)
        }
    }

    @Test("a pending question to the user waits; an unanswered escalation waits only when a human reviews it")
    func pendingCalls() throws {
        let fx = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fx.root) }
        try write(userTurn([
            Rollout.command(workdir: lens, call: "c0", at: now.addingTimeInterval(-50)),
            Rollout.ask(call: "c1", at: now.addingTimeInterval(-5))
        ]), id: parentID, fx)
        #expect(fx.scanner.states(forWorktreePaths: acmePaths, now: now)[lens] == .needsAttention)

        for (reviewer, age, expected) in [("user", 90.0, AgentActivityState.needsAttention),
                                          ("user", 10.0, .working), ("auto_review", 90.0, .working)] {
            let fx = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fx.root) }
            let lines = [Rollout.meta(id: parentID, cwd: launch, at: now.addingTimeInterval(-600)),
                         Rollout.context(cwd: lens, reviewer: reviewer, at: now.addingTimeInterval(-300)),
                         Rollout.event("task_started", at: now.addingTimeInterval(-300)),
                         Rollout.command(workdir: lens, escalated: true, call: "c2", at: now.addingTimeInterval(-age))]
            try write(lines, id: parentID, fx)
            #expect(fx.scanner.states(forWorktreePaths: acmePaths, now: now)[lens] == expected)
        }
    }

    @Test("a turn silent past the stall threshold waits; past the idle threshold it is gone")
    func silence() throws {
        let fx = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fx.root) }
        try write(userTurn([Rollout.reasoning(at: now.addingTimeInterval(-700))]).map { $0 }, id: parentID, fx,
                  mtime: now.addingTimeInterval(-700))
        #expect(fx.scanner.states(forWorktreePaths: [launch], now: now)[launch] == .needsAttention)
        #expect(fx.scanner.states(forWorktreePaths: [launch], now: now.addingTimeInterval(1_800))[launch] == .idle)
    }

    @Test("a turn longer than the tail window is still a turn in progress")
    func longTurn() throws {
        let fx = try makeFixture(tailBytes: 2_048)
        defer { try? FileManager.default.removeItem(at: fx.root) }
        let filler = (0..<40).map { Rollout.reasoning(at: now.addingTimeInterval(-200 + Double($0))) }
        try write(userTurn(filler + [Rollout.fileChange(lens + "/web/lib/a.ts", at: now.addingTimeInterval(-2))]),
                  id: parentID, fx)
        #expect(fx.scanner.states(forWorktreePaths: acmePaths, now: now)[lens] == .working)
    }

    @Test("a working subagent lights its worktree and its parent's; a finished one and guardians add nothing")
    func subagents() throws {
        let fx = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fx.root) }
        // The parent's turn ended long enough ago to be idle on its own.
        try write([Rollout.meta(id: parentID, cwd: acme, at: now.addingTimeInterval(-4_000)),
                   Rollout.context(cwd: acme, at: now.addingTimeInterval(-4_000)),
                   Rollout.event("task_complete", at: now.addingTimeInterval(-3_900))],
                  id: parentID, fx, mtime: now.addingTimeInterval(-3_900))
        try write([Rollout.meta(id: childID, cwd: launch, source: Rollout.subagentSource(parent: parentID),
                                at: now.addingTimeInterval(-300)),
                   Rollout.event("task_started", at: now.addingTimeInterval(-300)),
                   Rollout.commandDone(cwd: lens, at: now.addingTimeInterval(-4))], id: childID, fx)
        try write([Rollout.meta(id: guardianID, cwd: launch, source: Rollout.guardianSource, at: now.addingTimeInterval(-60)),
                   Rollout.context(cwd: launch, at: now.addingTimeInterval(-60)),
                   Rollout.event("task_started", at: now.addingTimeInterval(-60))], id: guardianID, fx)
        var states = fx.scanner.states(forWorktreePaths: acmePaths + [launch], now: now)
        #expect(states[lens] == .working)
        #expect(states[acme] == .working)
        #expect(states[launch] == .idle)

        try write([Rollout.meta(id: childID, cwd: launch, source: Rollout.subagentSource(parent: parentID),
                                at: now.addingTimeInterval(-300)),
                   Rollout.event("task_started", at: now.addingTimeInterval(-300)),
                   Rollout.commandDone(cwd: lens, at: now.addingTimeInterval(-40)),
                   Rollout.event("task_complete", at: now.addingTimeInterval(-4))], id: childID, fx)
        states = fx.scanner.states(forWorktreePaths: acmePaths + [launch], now: now)
        #expect(states == [lens: .idle, acme: .idle, launch: .idle])
    }

    @Test("resumed threads are read from their date folder, however old")
    func dateFolders() throws {
        let fx = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fx.root) }
        try write(userTurn([Rollout.patch(lens + "/a.py", call: "c1", at: now.addingTimeInterval(-3))]),
                  id: parentID, fx, daysAgo: 4)
        #expect(fx.scanner.states(forWorktreePaths: acmePaths, now: now)[lens] == .working)
        try FileManager.default.removeItem(at: fx.root)
        // Started 45 days ago, resumed today: the rollout is written where it began.
        let fresh = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fresh.root) }
        try write(userTurn([Rollout.patch(lens + "/a.py", call: "c1", at: now.addingTimeInterval(-3))]),
                  id: parentID, fresh, daysAgo: 45)
        #expect(fresh.scanner.states(forWorktreePaths: acmePaths, now: now)[lens] == .working)
    }

    @Test("an old thread resumed after a scan is found by the next look at the older folders, and followed after")
    func resumedAfterAScan() throws {
        let fx = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fx.root) }
        let lines = userTurn([Rollout.patch(lens + "/a.py", call: "c1", at: now.addingTimeInterval(-3))])
        try write(lines, id: parentID, fx, daysAgo: 90, mtime: now.addingTimeInterval(-90 * 86_400))
        #expect(fx.scanner.states(forWorktreePaths: acmePaths, now: now)[lens] == .idle)

        // Resumed: new records, a fresh modification time.
        let later = now.addingTimeInterval(fx.scanner.archiveInterval + 1)
        let resumed = lines.dropLast() + [Rollout.patch(lens + "/a.py", call: "c1", at: later.addingTimeInterval(-3))]
        try write(Array(resumed), id: parentID, fx, daysAgo: 90, mtime: later.addingTimeInterval(-1))
        #expect(fx.scanner.states(forWorktreePaths: acmePaths, now: later)[lens] == .working)

        // Between looks at the older folders, a thread already found is still read
        // on every scan: its turn ending shows at once.
        let soon = later.addingTimeInterval(2)
        try write(Array(resumed) + [Rollout.event("task_complete", at: soon.addingTimeInterval(-1))],
                  id: parentID, fx, daysAgo: 90, mtime: soon.addingTimeInterval(-1))
        #expect(fx.scanner.states(forWorktreePaths: acmePaths, now: soon)[lens] == .needsAttention)
    }
}
