import Foundation
import Testing
import TeebeCore
@testable import Teebe

@MainActor
struct WorktreeLoadingTests {
    @Test func slowIgnoredFileScanDoesNotDelayChanges() async {
        let git = FakeGitClient()
        let gate = Gate()
        git.runGate = { arguments, _ in
            if arguments.contains("--ignored") { await gate.wait() }
        }
        git.statusResult = StatusResult(changes: [FileChange(path: "new.txt", worktreeStatus: .modified)])
        let model = WorktreeModel(environment: makeTestEnvironment(git: git))
        let load = Task { await model.load(worktreePath: "/new", repo: Repository(path: "/new")) }
        // A bounded wait so a regression fails rather than hanging the suite.
        for _ in 0..<100 where model.statusPath != "/new" {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.statusPath == "/new")
        #expect(model.changes.map(\.path) == ["new.txt"])
        await gate.open()
        await load.value
    }

    @Test func oldIgnoredScanCannotReplaceTheNewSelectionsWatcher() async {
        let git = FakeGitClient()
        let gate = Gate()
        let entered = Gate()
        git.runGate = { arguments, directory in
            if arguments.contains("--ignored"), directory == "/old" {
                await entered.open()
                await gate.wait()
            }
        }
        let box = WatcherBox()
        let model = WorktreeModel(environment: makeTestEnvironment(git: git, makeWatcher: { box.make() }))
        let old = Task { await model.load(worktreePath: "/old", repo: Repository(path: "/old")) }
        await entered.wait()
        await model.load(worktreePath: "/new", repo: Repository(path: "/new"))
        await gate.open()
        await old.value
        #expect(model.worktreePath == "/new")
        #expect(model.statusPath == "/new")
        #expect(box.watching("/new")?.isWatching == true)
        #expect(box.watching("/old")?.isWatching != true)
    }

    @Test func clearingWhileIgnoredScanRunsCannotRestartWatching() async {
        let git = FakeGitClient()
        let gate = Gate()
        let entered = Gate()
        git.runGate = { _, _ in await entered.open(); await gate.wait() }
        let box = WatcherBox()
        let model = WorktreeModel(environment: makeTestEnvironment(git: git, makeWatcher: { box.make() }))
        let load = Task { await model.load(worktreePath: "/old", repo: Repository(path: "/old")) }
        await entered.wait()
        model.clear()
        await gate.open()
        await load.value
        #expect(model.worktreePath == nil)
        #expect(model.statusPath == nil)
        #expect(box.watchers.allSatisfy { !$0.isWatching })
    }
}
