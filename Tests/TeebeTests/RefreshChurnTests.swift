import Foundation
import Observation
@testable import Teebe
import TeebeCore
import Testing

/// Every write to `worktreeInfo` re-renders the whole worktree list, so the
/// periodic and event-driven refreshes must only write when a row's facts really
/// changed.
@MainActor
@Suite("Refreshes that change nothing stay quiet")
struct RefreshChurnTests {
    let repo = Repository(path: "/repo")

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false
        func raise() { lock.lock(); raised = true; lock.unlock() }
        var isRaised: Bool { lock.lock(); defer { lock.unlock() }; return raised }
    }

    /// Counts scans, so a test can see whether an event triggered one.
    final class CountingStates: @unchecked Sendable {
        let states = FakeAgentStates()
        private let lock = NSLock()
        private var calls = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
        var provider: @Sendable ([String], Date) -> [String: AgentActivityState] {
            let inner = states.provider
            return { [self] paths, now in
                lock.lock(); calls += 1; lock.unlock()
                return inner(paths, now)
            }
        }
    }

    func makeSelector(states: CountingStates = CountingStates(), monitor: WorktreeActivityMonitor = .init(),
                      projectsRoot: String? = nil) async -> SelectorModel {
        let box = WatcherBox()
        let git = FakeGitClient()
        git.worktreesResult = [
            Worktree(path: "/repo", branch: "main", isPrimary: true),
            Worktree(path: "/repo-wt", branch: "feat/x")
        ]
        let selector = SelectorModel(environment: makeTestEnvironment(
            git: git, monitor: monitor, makeWatcher: { box.make() }, agentStatuses: states.provider,
            agentProjectsRootPath: projectsRoot))
        selector.processPollInterval = 3_600
        await selector.selectRepo(repo)
        return selector
    }

    /// Whether `body` notified observers of `worktreeInfo`.
    func publishes(_ selector: SelectorModel, _ body: () async -> Void) async -> Bool {
        let flag = Flag()
        withObservationTracking { _ = selector.worktreeInfo } onChange: { flag.raise() }
        await body()
        return flag.isRaised
    }

    @Test("an agent re-derive with the same states does not publish; a change does")
    func agentRefresh() async {
        let states = CountingStates()
        let selector = await makeSelector(states: states)
        #expect(await !publishes(selector) { await selector.refreshAgentStates() })
        states.states["/repo-wt"] = .working
        #expect(await publishes(selector) { await selector.refreshAgentStates() })
    }

    @Test("a live-state pass with nothing new does not publish")
    func liveRefresh() async {
        let monitor = WorktreeActivityMonitor()
        let selector = await makeSelector(monitor: monitor)
        let t = Date()
        #expect(await !publishes(selector) { selector.refreshLiveState(now: t) })
        monitor.recordActivity(worktreePath: "/repo-wt", at: t)
        #expect(await publishes(selector) { selector.refreshLiveState(now: t) })
        // Still busy on the next event: nothing to redraw.
        monitor.recordActivity(worktreePath: "/repo-wt", at: t.addingTimeInterval(1))
        #expect(await !publishes(selector) { selector.refreshLiveState(now: t.addingTimeInterval(1)) })
    }

    @Test("more writes in an already-working worktree with the same change count do not publish")
    func repeatedFileEvents() async {
        let selector = await makeSelector()
        let t = Date()
        await selector.handleWorktreeFileEvents(["/repo-wt/a.txt"], now: t)
        #expect(await !publishes(selector) {
            await selector.handleWorktreeFileEvents(["/repo-wt/b.txt"], now: t.addingTimeInterval(1))
        })
    }

    @Test("a full re-read that finds the same facts does not publish")
    func fullRefresh() async {
        let selector = await makeSelector()
        #expect(await !publishes(selector) { await selector.refreshWorktreeInfo() })
    }
}
