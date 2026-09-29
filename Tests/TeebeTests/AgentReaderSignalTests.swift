import Foundation
import Testing
import TeebeCore
@testable import Teebe

/// Real on-disk agent records, production readers, and the native OS signal.
/// Only Git and the final Notification Center presentation are replaced.
@MainActor
@Suite("Agent records through the native signal", .serialized)
struct AgentReaderSignalTests {
    @Test(arguments: ["claude", "codex"])
    func hiddenCompletion(provider: String) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = folder.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let path = PathUtil.standardized(project.path)
        let claudeRoot = folder.appendingPathComponent("claude/projects")
        let codexRoot = folder.appendingPathComponent("codex/sessions")
        let now = Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: now)
        let file: URL
        var records: [[String: Any]]
        let final: [String: Any]
        if provider == "claude" {
            file = claudeRoot.appendingPathComponent(AgentSessionScanner.projectDirName(forWorktreePath: path))
                .appendingPathComponent("test.jsonl")
            records = [["type": "user", "cwd": path, "timestamp": stamp, "sessionId": "test",
                        "message": ["role": "user", "content": "Test prompt"]]]
            final = ["type": "assistant", "cwd": path, "timestamp": stamp, "sessionId": "test",
                     "message": ["role": "assistant", "stop_reason": "end_turn", "content": [["type": "text", "text": "Done"]]]]
        } else {
            let date = DateFormatter()
            date.dateFormat = "yyyy/MM/dd"
            file = codexRoot.appendingPathComponent(date.string(from: now)).appendingPathComponent("rollout-test.jsonl")
            records = [
                ["timestamp": stamp, "type": "session_meta", "payload": ["id": "test", "cwd": path, "source": "cli"]],
                ["timestamp": stamp, "type": "event_msg", "payload": ["type": "task_started", "turn_id": "t1"]]
            ]
            final = ["timestamp": stamp, "type": "event_msg", "payload": ["type": "task_complete", "turn_id": "t1"]]
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write(records, to: file)
        let readers = CombinedAgentActivity([AgentSessionScanner(projectsRoot: claudeRoot), CodexRolloutScanner(sessionsRoot: codexRoot)])
        let git = FakeGitClient()
        git.worktreesResult = [Worktree(path: path, branch: "main", isPrimary: true)]
        let channel = "dev.teebe.tests." + UUID().uuidString
        let spy = NotificationSpy()
        let selector = SelectorModel(environment: makeTestEnvironment(git: git,
            agentStatuses: { paths, date in readers.states(forWorktreePaths: paths, now: date) },
            agentProjectsRootPath: claudeRoot.path, agentExtraWatchPaths: [codexRoot.path],
            notify: spy.record, agentPing: DarwinAgentPingListener(name: channel)))
        selector.agentPingSettle = 0.02
        await selector.selectRepo(Repository(path: path))
        #expect(selector.info(for: selector.worktrees[0]).agentState == .working)
        await selector.setLowPower(true)
        records.append(final)
        try write(records, to: file)
        let ping = Process()
        ping.executableURL = URL(fileURLWithPath: "/usr/bin/notifyutil")
        ping.arguments = ["-p", channel]
        try ping.run()
        ping.waitUntilExit()
        #expect(ping.terminationStatus == 0)
        for _ in 0..<100 where spy.posted.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(selector.info(for: selector.worktrees[0]).agentState == .needsAttention)
        #expect(spy.posted.count == 1)
        selector.clearSelection()
    }

    private func write(_ records: [[String: Any]], to file: URL) throws {
        var data = Data()
        for record in records {
            data.append(try JSONSerialization.data(withJSONObject: record))
            data.append(0x0A)
        }
        try data.write(to: file, options: .atomic)
    }
}
