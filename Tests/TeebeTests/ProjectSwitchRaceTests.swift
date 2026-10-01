import Foundation
@testable import Teebe
import TeebeCore
import Testing

/// Picking one project and then quickly another: whichever was picked last wins,
/// even when the earlier project's reads finish after it.
@MainActor
struct ProjectSwitchRaceTests {
    /// Holds only the first call that reaches it; later calls pass straight through.
    final class FirstCallGate: @unchecked Sendable {
        let gate = Gate()
        private let lock = NSLock()
        private var calls = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
        func pass() async {
            let isFirst: Bool = { lock.lock(); defer { lock.unlock() }; calls += 1; return calls == 1 }()
            if isFirst { await gate.wait() }
        }
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<1_000 where !condition() { try? await Task.sleep(for: .milliseconds(2)) }
    }

    private func repoWatchers(_ box: WatcherBox, _ repo: String) -> [FakeWatcher] {
        box.watchers.filter { $0.isWatching && $0.watchedPaths == [repo + "/.git"] }
    }

    @Test func aSlowerLoadOfTheEarlierProjectKeepsTheLaterOne() async {
        let box = WatcherBox()
        let git = FakeGitClient()
        let gate = Gate()
        git.runGate = { arguments, directory in
            if directory == "/a", arguments == ["rev-parse", "--git-common-dir"] { await gate.wait() }
        }
        let selector = SelectorModel(environment: makeTestEnvironment(git: git, makeWatcher: { box.make() }))
        let first = Task { await selector.selectRepo(Repository(path: "/a")) }
        await waitUntil { git.touchedDirectories.contains("/a") }
        git.worktreesResult = [Worktree(path: "/b", branch: "main", isPrimary: true)]
        await selector.selectRepo(Repository(path: "/b"))
        git.worktreesResult = [Worktree(path: "/a", branch: "main", isPrimary: true)]
        await gate.open()
        await first.value

        #expect(selector.selectedRepo?.path == "/b")
        #expect(selector.worktrees.map(\.path) == ["/b"])
        #expect(selector.selectedWorktree?.path == "/b")
        #expect(selector.worktree.worktreePath == "/b")
        #expect(!selector.isLoading)
        #expect(repoWatchers(box, "/a").isEmpty)
        #expect(repoWatchers(box, "/b").count == 1)
    }

    @Test func selectingTheSameProjectTwiceLeavesOneRepositoryWatcher() async {
        let box = WatcherBox()
        let git = FakeGitClient()
        git.worktreesResult = [Worktree(path: "/a", branch: "main", isPrimary: true)]
        let gate = Gate()
        git.runGate = { arguments, directory in
            if directory == "/a", arguments == ["rev-parse", "--git-common-dir"] { await gate.wait() }
        }
        let selector = SelectorModel(environment: makeTestEnvironment(git: git, makeWatcher: { box.make() }))
        let first = Task { await selector.selectRepo(Repository(path: "/a")) }
        let second = Task { await selector.selectRepo(Repository(path: "/a")) }
        await waitUntil { git.touchedDirectories.filter { $0 == "/a" }.count >= 2 }
        await gate.open()
        await first.value
        await second.value

        #expect(selector.worktrees.map(\.path) == ["/a"])
        #expect(repoWatchers(box, "/a").count == 1)
    }

    @Test func aRescanOfTheEarlierProjectKeepsTheLaterOne() async {
        let box = WatcherBox()
        let git = FakeGitClient()
        git.worktreesResult = [Worktree(path: "/a", branch: "main", isPrimary: true)]
        let selector = SelectorModel(environment: makeTestEnvironment(git: git, makeWatcher: { box.make() }))
        await selector.selectRepo(Repository(path: "/a"))

        let held = FirstCallGate()
        git.beforeWorktrees = { await held.pass() }
        let rescan = Task { await selector.refreshWorktrees() }
        await waitUntil { held.count == 1 }
        git.worktreesResult = [Worktree(path: "/b", branch: "main", isPrimary: true)]
        await selector.selectRepo(Repository(path: "/b"))
        git.worktreesResult = [Worktree(path: "/a", branch: "main", isPrimary: true), Worktree(path: "/a-wt", branch: "x")]
        await held.gate.open()
        await rescan.value

        #expect(selector.selectedRepo?.path == "/b")
        #expect(selector.worktrees.map(\.path) == ["/b"])
        #expect(selector.selectedWorktree?.path == "/b")
        #expect(selector.worktree.worktreePath == "/b")
    }
}
