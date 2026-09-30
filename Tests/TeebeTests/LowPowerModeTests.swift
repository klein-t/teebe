import Foundation
@testable import Teebe
import TeebeCore
import Testing

/// Low-power mode: with the window occluded, every FSEvents watcher stops and the
/// app relies on the Claude Code hook ping (darwin notification) plus a slow poll —
/// so notifications still fire while background CPU drops to ~zero.
@MainActor
@Suite("Low-power mode")
struct LowPowerModeTests {
    let repo = Repository(path: "/repo")

    struct Rig {
        var git: FakeGitClient
        var selector: SelectorModel
        var states: FakeAgentStates
        var spy: NotificationSpy
        var box: WatcherBox
        var ping: FakeAgentPing
    }

    func makeRig() async -> Rig {
        let git = FakeGitClient()
        git.worktreesResult = [
            Worktree(path: "/repo", branch: "main", isPrimary: true),
            Worktree(path: "/repo-wt", branch: "feat/x")
        ]
        let states = FakeAgentStates()
        let spy = NotificationSpy()
        let box = WatcherBox()
        let ping = FakeAgentPing()
        let selector = SelectorModel(environment: makeTestEnvironment(
            git: git,
            makeWatcher: { box.make() },
            agentStatuses: states.provider,
            agentProjectsRootPath: "/fake/.claude/projects",
            notify: spy.record,
            agentPing: ping
        ))
        await selector.selectRepo(repo)
        return Rig(git: git, selector: selector, states: states, spy: spy, box: box, ping: ping)
    }

    /// The four live watchers after a repo is selected: repo git dir, Claude
    /// projects root, the active worktree's tree, and every worktree's files.
    func liveWatchers(_ box: WatcherBox) -> [FakeWatcher] {
        [
            box.watching(".git"),
            box.watching("projects"),
            box.watchers.last { $0.watchedPaths == ["/repo"] },
            box.watchers.last { $0.watchedPaths == ["/repo", "/repo-wt"] }
        ].compactMap { $0 }
    }

    @Test("selecting a repo starts the hook ping listener; clearing stops it")
    func pingLifecycle() async {
        let rig = await makeRig()
        #expect(rig.ping.startCount == 1)
        rig.selector.clearSelection()
        #expect(rig.ping.stopCount >= 1)
    }

    @Test("entering low power stops every file-system watcher")
    func enteringStopsWatchers() async {
        let rig = await makeRig()
        let watchers = liveWatchers(rig.box)
        #expect(watchers.count == 4)
        #expect(watchers.allSatisfy { $0.isWatching })

        await rig.selector.setLowPower(true)
        #expect(rig.selector.isLowPower)
        #expect(watchers.allSatisfy { !$0.isWatching })
    }

    @Test("a hook ping in low power still refreshes badges and notifies")
    func pingRefreshesInLowPower() async throws {
        let rig = await makeRig()
        rig.states["/repo-wt"] = .working
        await rig.selector.refreshAgentStates()
        await rig.selector.setLowPower(true)

        // The agent finishes while we're backgrounded; the hook pings.
        rig.states["/repo-wt"] = .needsAttention
        rig.ping.fire()
        try await Task.sleep(for: .milliseconds(200))

        #expect(rig.selector.info(for: rig.selector.worktrees[1]).agentState == .needsAttention)
        #expect(rig.spy.posted.count == 1)
    }

    @Test("a ping that lands before Claude Code records the new state is followed by a catch-up re-derive")
    func pingCatchUp() async throws {
        let rig = await makeRig()
        rig.selector.agentPingSettle = 0.2
        await rig.selector.setLowPower(true)

        // UserPromptSubmit pings before the prompt is logged or the session
        // registry turns busy; the state only changes a moment later.
        rig.ping.fire()
        try await Task.sleep(for: .milliseconds(50))
        rig.states["/repo-wt"] = .working
        try await Task.sleep(for: .milliseconds(500))

        #expect(rig.selector.info(for: rig.selector.worktrees[1]).agentState == .working)
    }

    @Test("exiting low power restarts watchers and re-derives state")
    func exitingRestartsAndRefreshes() async {
        let rig = await makeRig()
        await rig.selector.setLowPower(true)

        // State changed while backgrounded, with no ping delivered.
        rig.states["/repo-wt"] = .working
        await rig.selector.setLowPower(false)

        #expect(!rig.selector.isLowPower)
        #expect(liveWatchers(rig.box).filter(\.isWatching).count == 4)
        #expect(rig.selector.info(for: rig.selector.worktrees[1]).agentState == .working)
    }

    @Test("returning to a visible window invalidates merge checks missed while hidden")
    func exitingInvalidatesMergeChecks() async {
        let rig = await makeRig()
        await rig.selector.setLowPower(true)
        let revision = rig.selector.mergeRevision

        rig.git.showRefOutput = "new-oid refs/remotes/origin/dev\n"
        // No ref watcher event is delivered while hidden, including a merge
        // committed externally. Visibility must recheck local refs without fetching.
        await rig.selector.setLowPower(false)

        #expect(rig.selector.mergeRevision > revision)
    }

    @Test("unreadable refs invalidate merge checks conservatively on return")
    func unreadableRefs() async {
        let rig = await makeRig()
        rig.git.showRefExitCode = 128
        await rig.selector.setLowPower(true)
        let revision = rig.selector.mergeRevision
        await rig.selector.setLowPower(false)
        #expect(rig.selector.mergeRevision > revision)
    }

    @Test("a hidden ref read completing after a repository switch cannot stop its watchers")
    func staleHiddenRead() async {
        let rig = await makeRig()
        let started = Gate()
        let finish = Gate()
        rig.git.runGate = { args, _ in
            if args == ["show-ref"] { await started.open(); await finish.wait() }
        }
        let hiding = Task { await rig.selector.setLowPower(true) }
        await started.wait()
        await rig.selector.selectRepo(Repository(path: "/another"))
        let watcher = rig.box.watching(".git")
        await finish.open()
        await hiding.value
        #expect(watcher?.isWatching != true)
    }

    @Test("an obsolete hidden ref read cannot overwrite a newer hidden baseline")
    func staleVisibilityRead() async {
        let rig = await makeRig()
        let started = Gate()
        let finish = Gate()
        rig.git.runGate = { args, _ in
            if args == ["show-ref"] { await started.open(); await finish.wait() }
        }
        let firstHide = Task { await rig.selector.setLowPower(true) }
        await started.wait()
        rig.git.runGate = nil
        rig.git.showRefOutput = "current refs/heads/main\n"
        await rig.selector.setLowPower(false)
        await rig.selector.setLowPower(true)
        rig.git.showRefOutput = "obsolete refs/heads/main\n"
        await finish.open()
        await firstHide.value
        rig.git.showRefOutput = "current refs/heads/main\n"
        let revision = rig.selector.mergeRevision
        await rig.selector.setLowPower(false)
        #expect(rig.selector.mergeRevision == revision)
    }

    @Test("refs changed before watcher shutdown are rechecked even when its pending event is dropped")
    func pendingRefEventAtHideBoundary() async {
        let rig = await makeRig()
        let revision = rig.selector.mergeRevision
        // The last visible scan read old refs. Git now changes them, but the
        // watcher's debounce has not delivered the event before the window hides.
        rig.git.showRefOutput = "new-oid refs/heads/main\n"
        await rig.selector.setLowPower(true)
        #expect(rig.selector.mergeRevision == revision)
        await rig.selector.setLowPower(false)
        #expect(rig.selector.mergeRevision > revision)
        let refreshed = rig.selector.mergeRevision
        await rig.selector.setLowPower(true)
        await rig.selector.setLowPower(false)
        #expect(rig.selector.mergeRevision == refreshed)
    }

    @Test("setLowPower is idempotent")
    func idempotent() async {
        let rig = await makeRig()
        let stopsBefore = liveWatchers(rig.box).map(\.stopCount)
        await rig.selector.setLowPower(false)   // already off — must not churn watchers
        #expect(liveWatchers(rig.box).map(\.stopCount) == stopsBefore)

        await rig.selector.setLowPower(true)
        let stopsAfter = liveWatchers(rig.box).map(\.stopCount)
        await rig.selector.setLowPower(true)    // already on — no double stop
        #expect(liveWatchers(rig.box).map(\.stopCount) == stopsAfter)
    }
}
