import Foundation
import Testing
import TeebeCore
@testable import Teebe

@MainActor
@Suite("Codex completions between polls", .serialized)
struct CodexCompletionNotificationTests {
    @Test func hiddenShortTurnsNotifyWithoutAnObservedWorkingState() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        await rig.selector.selectRepo(Repository(path: rig.path))
        await rig.selector.setLowPower(true)
        try rig.turn("one")
        try rig.turn("two")
        await rig.selector.refreshAgentStates()
        #expect(rig.spy.posted.count == 2)
        await rig.selector.refreshAgentStates()
        #expect(rig.spy.posted.count == 2)
        #expect(rig.selector.isLowPower)
        #expect(rig.selector.lowPowerAgentPollInterval == 120)
    }

    @Test func startupDisabledAndAbortedTurnsStaySilent() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        try rig.turn("old")
        await rig.selector.selectRepo(Repository(path: rig.path))
        #expect(rig.spy.posted.isEmpty)
        rig.selector.notificationsEnabled = false
        try rig.turn("muted")
        await rig.selector.refreshAgentStates()
        rig.selector.notificationsEnabled = true
        await rig.selector.refreshAgentStates()
        #expect(rig.spy.posted.isEmpty)
        try rig.record("task_started", turn: "aborted")
        await rig.selector.refreshAgentStates()
        try rig.record("turn_aborted", turn: "aborted")
        await rig.selector.refreshAgentStates()
        #expect(rig.spy.posted.isEmpty)
        try rig.turn("new")
        await rig.selector.refreshAgentStates()
        #expect(rig.spy.posted.count == 1)
    }

    @Test func observedCompletionDoesNotDuplicateTheBadgeTransition() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        await rig.selector.selectRepo(Repository(path: rig.path))
        try rig.record("task_started", turn: "observed")
        await rig.selector.refreshAgentStates()
        try rig.record("task_complete", turn: "observed")
        await rig.selector.refreshWorktreeInfo()
        await rig.selector.refreshAgentStates()
        #expect(rig.spy.posted.count == 1)
    }

    @Test func completionBetweenBadgeAndJournalReadsDoesNotDuplicateOnTheNextPoll() async throws {
        let states = FakeAgentStates()
        let rig = try Rig(states: states)
        defer { rig.cleanUp() }
        await rig.selector.selectRepo(Repository(path: rig.path))
        states[rig.path] = .working
        await rig.selector.refreshAgentStates()
        let scanBegan = Date().addingTimeInterval(-0.005)
        try rig.turn("racing")
        // Model the badge snapshot just before the append, then the journal
        // snapshot just after it, in the same refresh.
        await rig.selector.refreshAgentStates(now: scanBegan)
        #expect(rig.spy.posted.count == 1)
        states[rig.path] = .needsAttention
        await rig.selector.refreshAgentStates()
        #expect(rig.spy.posted.count == 1)
    }

    @MainActor
    private struct Rig {
        let folder: URL
        let file: URL
        let path: String
        let spy = NotificationSpy()
        let selector: SelectorModel

        init(states: FakeAgentStates? = nil) throws {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let root = folder.appendingPathComponent("sessions")
            let project = folder.appendingPathComponent("repo")
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            path = project.path
            let date = DateFormatter(); date.dateFormat = "yyyy/MM/dd"
            file = root.appendingPathComponent(date.string(from: Date())).appendingPathComponent("rollout-test.jsonl")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let meta: [String: Any] = ["type": "session_meta", "payload": ["id": "test", "cwd": path, "source": "cli"]]
            var data = try JSONSerialization.data(withJSONObject: meta); data.append(10)
            try data.write(to: file)
            let scanner = CodexRolloutScanner(sessionsRoot: root)
            let git = FakeGitClient()
            git.worktreesResult = [Worktree(path: path, branch: "feature", isPrimary: true)]
            selector = SelectorModel(environment: makeTestEnvironment(git: git,
                agentStatuses: { paths, now in states?.provider(paths, now) ?? scanner.states(forWorktreePaths: paths, now: now) },
                agentTurnEnds: { scanner.turnEnds(forWorktreePaths: $0, now: $1) }, notify: spy.record))
        }

        func record(_ kind: String, turn: String) throws {
            let stamp = ISO8601DateFormatter()
            stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let record: [String: Any] = ["timestamp": stamp.string(from: Date()), "type": "event_msg",
                                         "payload": ["type": kind, "turn_id": turn]]
            var data = try JSONSerialization.data(withJSONObject: record); data.append(10)
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: data)
        }

        func turn(_ id: String) throws {
            try record("task_started", turn: id)
            try record("task_complete", turn: id)
        }

        func cleanUp() {
            selector.clearSelection()
            try? FileManager.default.removeItem(at: folder)
        }
    }
}
