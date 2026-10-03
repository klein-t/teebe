import Foundation
import Testing
import TeebeCore
@testable import Teebe

@MainActor
@Suite("Hidden agent polling", .serialized)
struct HiddenAgentPollingTests {
    @Test("hiding reschedules the visible wait and detects short turns without replay")
    func hiddenCadenceAndDelivery() async throws {
        let clock = PollClock()
        let probe = PollProbe()
        let spy = NotificationSpy()
        let git = FakeGitClient()
        git.worktreesResult = [Worktree(path: "/repo", branch: "feature", isPrimary: true)]
        let model = selector(clock: clock, probe: probe, git: git, spy: spy)
        defer { model.clearSelection() }
        var waits = clock.requests.makeAsyncIterator()
        var cancellations = clock.cancellations.makeAsyncIterator()
        await model.selectRepo(Repository(path: "/repo"))
        let visible = try #require(await waits.next())
        #expect(visible.seconds == 30)
        let initialScans = probe.scanCount
        let initialGitCalls = git.statusCallCount
        await model.setLowPower(true)
        #expect(await cancellations.next() == visible.id)
        var hidden = try #require(await waits.next())
        #expect(hidden.seconds == 15)
        #expect(probe.scanCount == initialScans)
        probe.append("short")
        clock.release(hidden.id)
        hidden = try #require(await waits.next())
        #expect(hidden.seconds == 15)
        #expect(spy.posted.count == 1)
        #expect(probe.scanCount == initialScans + 1)
        #expect(git.statusCallCount == initialGitCalls)
        clock.release(hidden.id)
        hidden = try #require(await waits.next())
        #expect(spy.posted.count == 1)
        model.notificationsEnabled = false
        probe.append("muted")
        clock.release(hidden.id)
        hidden = try #require(await waits.next())
        #expect(spy.posted.count == 1)
        #expect(probe.maxConcurrentScans == 1)
        model.clearSelection()
        #expect(await cancellations.next() == hidden.id)
        #expect(clock.pendingCount == 0)
    }

    @Test("changing visibility during a scan waits for that scan before polling again")
    func visibilityDuringScanRemainsSerial() async throws {
        let clock = PollClock()
        let probe = PollProbe()
        let git = FakeGitClient()
        git.worktreesResult = [Worktree(path: "/repo", branch: "feature", isPrimary: true)]
        let model = selector(clock: clock, probe: probe, git: git)
        defer {
            probe.releaseScan()
            model.clearSelection()
        }
        var waits = clock.requests.makeAsyncIterator()
        var scans = probe.started.makeAsyncIterator()
        await model.selectRepo(Repository(path: "/repo"))
        let visible = try #require(await waits.next())
        probe.pauseNextScan()
        clock.release(visible.id)
        _ = try #require(await scans.next())
        await model.setLowPower(true)
        #expect(clock.pendingCount == 0)
        probe.releaseScan()
        let hidden = try #require(await waits.next())
        #expect(hidden.seconds == 15)
        clock.release(hidden.id)
        _ = try #require(await waits.next())
        #expect(probe.maxConcurrentScans == 1)
    }

    private func selector(clock: PollClock, probe: PollProbe, git: FakeGitClient,
                          spy: NotificationSpy = NotificationSpy()) -> SelectorModel {
        let model = SelectorModel(environment: makeTestEnvironment(git: git,
            agentStatuses: probe.states, agentTurnEnds: probe.endings,
            agentProjectsRootPath: "/fake-projects", notify: spy.record))
        model.waitForAgentPoll = clock.wait
        model.notificationsEnabled = true
        return model
    }
}

@MainActor
private final class PollClock {
    struct Request {
        let id: UUID
        let seconds: TimeInterval
    }
    let requests: AsyncStream<Request>
    let cancellations: AsyncStream<UUID>
    private let requestsSink: AsyncStream<Request>.Continuation
    private let cancellationsSink: AsyncStream<UUID>.Continuation
    private var pending: [UUID: CheckedContinuation<Void, any Error>] = [:]
    var pendingCount: Int { pending.count }

    init() {
        (requests, requestsSink) = AsyncStream.makeStream()
        (cancellations, cancellationsSink) = AsyncStream.makeStream()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            self?.requestsSink.finish()
            self?.cancellationsSink.finish()
        }
    }

    func wait(_ seconds: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending[id] = continuation
                requestsSink.yield(Request(id: id, seconds: seconds))
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id) }
        }
    }

    func release(_ id: UUID) { pending.removeValue(forKey: id)?.resume() }
    private func cancel(_ id: UUID) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(throwing: CancellationError())
        cancellationsSink.yield(id)
    }
}

private final class PollProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let resume = DispatchSemaphore(value: 0)
    private var pause = false
    private var active = 0
    private var maximum = 0
    private var scans = 0
    private var events: [AgentTurnEnd] = []
    let started: AsyncStream<Void>
    private let startedSink: AsyncStream<Void>.Continuation
    var scanCount: Int { lock.withLock { scans } }
    var maxConcurrentScans: Int { lock.withLock { maximum } }

    init() {
        (started, startedSink) = AsyncStream.makeStream()
        let sink = startedSink
        Task {
            try? await Task.sleep(for: .seconds(5))
            sink.finish()
        }
    }
    func pauseNextScan() { lock.withLock { pause = true } }
    func releaseScan() { resume.signal() }
    func append(_ id: String) {
        lock.withLock { events.append(AgentTurnEnd(id: id, worktreePath: "/repo", endedAt: Date())) }
    }
    @Sendable func states(_ paths: [String], _ now: Date) -> [String: AgentActivityState] {
        let shouldPause = lock.withLock {
            scans += 1
            active += 1
            maximum = max(maximum, active)
            let requested = pause
            pause = false
            return requested
        }
        if shouldPause {
            startedSink.yield(())
            resume.wait()
        }
        lock.withLock { active -= 1 }
        return Dictionary(uniqueKeysWithValues: paths.map { ($0, .idle) })
    }
    @Sendable func endings(_ paths: [String], _ now: Date) -> [AgentTurnEnd] { lock.withLock { events } }
}
