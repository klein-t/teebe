import Foundation
@testable import Teebe
import TeebeCore
import Testing

/// Harness-agnostic activity in SelectorModel: file changes in every worktree of
/// the open repo (not only the selected one) and busy processes light the
/// working orb, and it fades a window after the last sign of work.
@MainActor
@Suite("Generic worktree activity")
struct GenericActivityModelTests {
    let repo = Repository(path: "/repo")

    final class ProcessScript: @unchecked Sendable {
        private let lock = NSLock()
        private var active: Set<String> = []
        func set(_ paths: Set<String>) { lock.lock(); active = paths; lock.unlock() }
        var provider: @Sendable ([String], Date) -> Set<String> {
            { [self] _, _ in lock.lock(); defer { lock.unlock() }; return active }
        }
    }

    func makeSelector(git: FakeGitClient = FakeGitClient(), box: WatcherBox, monitor: WorktreeActivityMonitor,
                      processes: ProcessScript? = nil) async -> SelectorModel {
        git.worktreesResult = [
            Worktree(path: "/repo", branch: "main", isPrimary: true),
            Worktree(path: "/repo-wt", branch: "feat/lens")
        ]
        let selector = SelectorModel(environment: makeTestEnvironment(
            git: git, monitor: monitor, makeWatcher: { box.make() }, processActivity: processes?.provider))
        selector.processPollInterval = 3_600 // tests drive the probe by hand
        await selector.selectRepo(repo)
        return selector
    }

    func worktreesWatcher(_ box: WatcherBox) -> FakeWatcher? {
        box.watchers.last { Set($0.watchedPaths) == ["/repo", "/repo-wt"] }
    }

    @Test("one stream watches every worktree of the repo")
    func watchesAllWorktrees() async {
        let box = WatcherBox()
        let selector = await makeSelector(box: box, monitor: WorktreeActivityMonitor())
        let watcher = worktreesWatcher(box)
        #expect(watcher?.isWatching == true)
        await selector.setLowPower(true)
        #expect(watcher?.isWatching == false)
        await selector.setLowPower(false)
        #expect(worktreesWatcher(box)?.isWatching == true)
        selector.clearSelection()
        #expect(worktreesWatcher(box)?.isWatching == false)
    }

    @Test("a write in a worktree that isn't selected lights it for the activity window, then it fades")
    func unselectedWorktreeLights() async {
        let box = WatcherBox()
        let monitor = WorktreeActivityMonitor()
        let selector = await makeSelector(box: box, monitor: monitor)
        let t = Date(timeIntervalSince1970: 5_000)
        await selector.handleWorktreeFileEvents(["/repo-wt/web/lib/a.test.ts"], now: t)
        selector.refreshLiveState(now: t.addingTimeInterval(60))
        #expect(selector.info(for: selector.worktrees[1]).isLive)
        #expect(!selector.info(for: selector.worktrees[0]).isLive)
        selector.refreshLiveState(now: t.addingTimeInterval(GenericActivity.window + 1))
        #expect(!selector.info(for: selector.worktrees[1]).isLive)
    }

    @Test("build output and Git bookkeeping don't count as activity")
    func ignoredWrites() async {
        let box = WatcherBox()
        let monitor = WorktreeActivityMonitor()
        let selector = await makeSelector(box: box, monitor: monitor)
        let t = Date(timeIntervalSince1970: 5_000)
        await selector.handleWorktreeFileEvents(["/repo/.git/index", "/repo-wt/node_modules/x/y.js",
                                                 "/repo-wt/.build/debug/a.o"], now: t)
        selector.refreshLiveState(now: t.addingTimeInterval(1))
        #expect(!selector.info(for: selector.worktrees[0]).isLive)
        #expect(!selector.info(for: selector.worktrees[1]).isLive)
    }

    @Test("a write refreshes the touched worktree's uncommitted count right away")
    func changeCountFollowsWrites() async {
        let box = WatcherBox()
        let git = FakeGitClient()
        let selector = await makeSelector(git: git, box: box, monitor: WorktreeActivityMonitor())
        #expect(selector.info(for: selector.worktrees[1]).changeCount == 0)
        git.statusResult = StatusResult(changes: [FileChange(path: "web/lib/a.test.ts", indexStatus: .unmodified,
                                                             worktreeStatus: .untracked)])
        await selector.handleWorktreeFileEvents(["/repo-wt/web/lib/a.test.ts"], now: Date())
        #expect(selector.info(for: selector.worktrees[1]).changeCount == 1)
    }

    @Test("a busy process in a worktree lights it; the probe is paused in low power")
    func processesLight() async {
        let box = WatcherBox()
        let processes = ProcessScript()
        let selector = await makeSelector(box: box, monitor: WorktreeActivityMonitor(), processes: processes)
        let t = Date(timeIntervalSince1970: 5_000)
        processes.set(["/repo-wt"])
        await selector.pollProcessActivity(now: t)
        selector.refreshLiveState(now: t.addingTimeInterval(1))
        #expect(selector.info(for: selector.worktrees[1]).isLive)
        #expect(selector.isPollingProcesses)
        await selector.setLowPower(true)
        #expect(!selector.isPollingProcesses)
        await selector.setLowPower(false)
        #expect(selector.isPollingProcesses)
    }
}
