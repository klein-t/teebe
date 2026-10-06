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
        #expect(rig.selector.lowPowerAgentPollInterval == 15)
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

    @Test(arguments: [false, true])
    func reenablingBeforeTheNextPollDiscardsMutedTurnsAndKeepsNewTurns(newBeforeFirstScan: Bool) async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        await rig.selector.selectRepo(Repository(path: rig.path))
        let enabledAt = Date().addingTimeInterval(1)
        try rig.record("task_started", turn: "muted", at: enabledAt.addingTimeInterval(-0.5))
        await rig.selector.refreshAgentStates(now: enabledAt.addingTimeInterval(-0.4))
        rig.selector.notificationsEnabled = false
        try rig.record("task_complete", turn: "muted", at: enabledAt.addingTimeInterval(-0.1))
        rig.selector.setNotificationsEnabled(true, now: enabledAt)
        if !newBeforeFirstScan {
            await rig.selector.refreshAgentStates(now: enabledAt.addingTimeInterval(0.1))
            #expect(rig.spy.posted.isEmpty)
        }
        // Use explicit times because rollout timestamps round to milliseconds.
        // The new ending is provably after the toggle, without timing sleeps.
        try rig.turn("new", at: enabledAt.addingTimeInterval(0.2))
        await rig.selector.refreshAgentStates(now: enabledAt.addingTimeInterval(0.3))
        #expect(rig.spy.posted.count == 1)
        await rig.selector.refreshAgentStates(now: enabledAt.addingTimeInterval(0.4))
        #expect(rig.spy.posted.count == 1)
    }

    @Test func reenablingBaselinesDelayedBadgeEdgesButKeepsLaterTransitions() async throws {
        let states = FakeAgentStates()
        let rig = try Rig(states: states)
        defer { rig.cleanUp() }
        await rig.selector.selectRepo(Repository(path: rig.path))
        states[rig.path] = .working
        await rig.selector.refreshAgentStates()
        rig.selector.notificationsEnabled = false
        states[rig.path] = .needsAttention
        rig.selector.notificationsEnabled = true
        await rig.selector.refreshAgentStates()
        #expect(rig.spy.posted.isEmpty)
        states[rig.path] = .working
        await rig.selector.refreshAgentStates()
        states[rig.path] = .needsAttention
        await rig.selector.refreshAgentStates()
        #expect(rig.spy.posted.count == 1)
    }

    @Test func reenablingRejectsAnInFlightMutedSnapshotBeforeBaselining() async throws {
        let states = FakeAgentStates()
        let gate = SnapshotGate()
        let rig = try Rig(states: states, afterStateRead: gate.pauseIfArmed)
        defer { gate.release(); rig.cleanUp() }
        await rig.selector.selectRepo(Repository(path: rig.path))
        states[rig.path] = .working
        await rig.selector.refreshAgentStates()
        rig.selector.notificationsEnabled = false
        gate.arm()
        let pending = Task { await rig.selector.refreshAgentStates() }
        for await _ in gate.started { break }
        states[rig.path] = .needsAttention
        rig.selector.notificationsEnabled = true
        gate.release()
        await pending.value
        await rig.selector.refreshAgentStates()
        #expect(rig.spy.posted.isEmpty)
        states[rig.path] = .working
        await rig.selector.refreshAgentStates()
        states[rig.path] = .needsAttention
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

    @Test func completionInTheSnapshotMillisecondDoesNotDuplicateTheNextBadgeEdge() async throws {
        let states = FakeAgentStates()
        let rig = try Rig(states: states)
        defer { rig.cleanUp() }
        await rig.selector.selectRepo(Repository(path: rig.path))
        let millisecond = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 * 1_000) / 1_000 + 1)
        states[rig.path] = .working
        await rig.selector.refreshAgentStates(now: millisecond.addingTimeInterval(-0.1))
        // The completion is read after the badge snapshot but its rounded
        // timestamp is slightly earlier than the exact scan-start Date.
        try rig.turn("same-millisecond", at: millisecond.addingTimeInterval(0.0003))
        await rig.selector.refreshAgentStates(now: millisecond.addingTimeInterval(0.0001))
        #expect(rig.spy.posted.count == 1)
        states[rig.path] = .needsAttention
        await rig.selector.refreshAgentStates(now: millisecond.addingTimeInterval(0.002))
        #expect(rig.spy.posted.count == 1)
    }

    private final class SnapshotGate: @unchecked Sendable {
        private let lock = NSLock()
        private let resume = DispatchSemaphore(value: 0)
        private var armed = false
        let started: AsyncStream<Void>
        private let continuation: AsyncStream<Void>.Continuation

        init() { (started, continuation) = AsyncStream.makeStream() }
        func arm() { lock.lock(); armed = true; lock.unlock() }
        func release() { resume.signal() }
        @Sendable func pauseIfArmed() {
            lock.lock()
            let pause = armed
            armed = false
            lock.unlock()
            guard pause else { return }
            continuation.yield(())
            resume.wait()
        }
    }

    @MainActor
    private struct Rig {
        let folder: URL
        let file: URL
        let path: String
        let spy = NotificationSpy()
        let selector: SelectorModel

        init(states: FakeAgentStates? = nil, afterStateRead: (@Sendable () -> Void)? = nil) throws {
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
                agentStatuses: { paths, now in
                    let snapshot = states?.provider(paths, now) ?? scanner.states(forWorktreePaths: paths, now: now)
                    afterStateRead?()
                    return snapshot
                },
                agentTurnEnds: { scanner.turnEnds(forWorktreePaths: $0, now: $1) }, notify: spy.record))
            selector.notificationsEnabled = true
        }

        func record(_ kind: String, turn: String, at date: Date = Date()) throws {
            let stamp = ISO8601DateFormatter()
            stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let record: [String: Any] = ["timestamp": stamp.string(from: date), "type": "event_msg",
                                         "payload": ["type": kind, "turn_id": turn]]
            var data = try JSONSerialization.data(withJSONObject: record); data.append(10)
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: data)
        }

        func turn(_ id: String, at date: Date = Date()) throws {
            try record("task_started", turn: id, at: date)
            try record("task_complete", turn: id, at: date)
        }

        func cleanUp() {
            selector.clearSelection()
            try? FileManager.default.removeItem(at: folder)
        }
    }
}
