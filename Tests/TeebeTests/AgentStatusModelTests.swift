import Foundation
@testable import Teebe
import TeebeCore
import Testing

@MainActor
@Suite("Agent status in SelectorModel")
struct AgentStatusModelTests {
    let repo = Repository(path: "/repo")

    func makeSelector(
        states: FakeAgentStates,
        spy: NotificationSpy = NotificationSpy(),
        git: FakeGitClient = FakeGitClient(),
        box: WatcherBox? = nil,
        projectsRoot: String? = nil
    ) -> SelectorModel {
        git.worktreesResult = [
            Worktree(path: "/repo", branch: "main", isPrimary: true),
            Worktree(path: "/repo-wt", branch: "feat/x")
        ]
        return SelectorModel(environment: makeTestEnvironment(
            git: git,
            makeWatcher: box.map { b in { b.make() } },
            agentStatuses: states.provider,
            agentProjectsRootPath: projectsRoot,
            notify: spy.record
        ))
    }

    @Test("refreshWorktreeInfo picks up each worktree's agent state")
    func refreshPopulatesAgentState() async {
        let states = FakeAgentStates()
        states["/repo-wt"] = .working
        let selector = makeSelector(states: states)

        await selector.selectRepo(repo)
        #expect(selector.info(for: selector.worktrees[0]).agentState == .idle)
        #expect(selector.info(for: selector.worktrees[1]).agentState == .working)
    }

    @Test("refreshAgentStates updates badges without re-running git status")
    func cheapRefresh() async {
        let states = FakeAgentStates()
        let git = FakeGitClient()
        let selector = makeSelector(states: states, git: git)
        await selector.selectRepo(repo)
        let gitCallsAfterSelect = git.statusCallCount

        states["/repo-wt"] = .working
        await selector.refreshAgentStates()
        #expect(selector.info(for: selector.worktrees[1]).agentState == .working)
        #expect(git.statusCallCount == gitCallsAfterSelect)
    }

    @Test("working → needsAttention notifies once, naming the worktree")
    func transitionNotifies() async {
        let states = FakeAgentStates()
        let spy = NotificationSpy()
        let selector = makeSelector(states: states, spy: spy)
        await selector.selectRepo(repo)

        states["/repo-wt"] = .working
        await selector.refreshAgentStates()
        #expect(spy.posted.isEmpty)

        states["/repo-wt"] = .needsAttention
        await selector.refreshAgentStates()
        #expect(spy.posted.count == 1)
        #expect(spy.posted.first?.body.contains("feat/x") == true)

        // Still needing attention on the next poll is not a new event.
        await selector.refreshAgentStates()
        #expect(spy.posted.count == 1)
    }

    @Test("a session already needing attention at discovery does not notify")
    func staleSessionDoesNotNotify() async {
        let states = FakeAgentStates()
        states["/repo-wt"] = .needsAttention
        let spy = NotificationSpy()
        let selector = makeSelector(states: states, spy: spy)

        await selector.selectRepo(repo)
        #expect(selector.info(for: selector.worktrees[1]).agentState == .needsAttention)
        #expect(spy.posted.isEmpty)
    }

    @Test("selecting a repo watches the Claude projects root; clearing stops it")
    func projectsWatcherLifecycle() async {
        let states = FakeAgentStates()
        let box = WatcherBox()
        let selector = makeSelector(states: states, box: box, projectsRoot: "/fake/.claude/projects")
        await selector.selectRepo(repo)

        let watcher = box.watching("/fake/.claude/projects")
        #expect(watcher != nil)
        #expect(watcher?.isWatching == true)

        // A session-log change re-derives states via the cheap path.
        states["/repo-wt"] = .working
        await selector.handleAgentWatchEvent()
        #expect(selector.info(for: selector.worktrees[1]).agentState == .working)

        selector.clearSelection()
        #expect(watcher?.isWatching == false)
    }

    @Test("without a projects root no agent watcher is started")
    func noRootNoWatcher() async {
        let states = FakeAgentStates()
        let box = WatcherBox()
        let selector = makeSelector(states: states, box: box, projectsRoot: nil)
        await selector.selectRepo(repo)
        #expect(box.watching(".claude") == nil)
    }
}
