import Foundation
import Testing
import TeebeCore
@testable import Teebe

/// Removal stub: records what it was asked to remove and can refuse one worktree,
/// the way Git does when the folder changed under the confirmation.
private actor RemovalStub: WorktreeCleanupChecking {
    let snapshot: CleanupSnapshot
    private(set) var removed: [String] = []
    /// The worktree this refuses to remove.
    var refuses: String?
    init(snapshot: CleanupSnapshot, refuses: String? = nil) {
        self.snapshot = snapshot
        self.refuses = refuses
    }
    func scan(repoPath: String, targetOverride: String?) async throws -> CleanupSnapshot { snapshot }
    func fetch(repoPath: String) async throws {}
    func remove(repoPath: String, entry: CleanupEntry, target: CleanupBranch, includingIgnored: Bool) async throws {
        guard entry.id != refuses else { throw CleanupError.changed }
        removed.append(entry.id)
    }
}

/// Counts how often the repository's worktrees were re-discovered.
private final class DiscoveryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() { lock.lock(); value += 1; lock.unlock() }
    func reset() { lock.lock(); value = 0; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

@MainActor
@Suite("Worktree group actions")
struct WorktreeGroupActionsTests {
    private let repo = Repository(path: "/repo")

    private func merged(_ path: String, branch: String) -> CleanupEntry {
        var entry = CleanupEntry(worktree: Worktree(path: path, branch: branch, head: "abc"))
        entry.mergeStatus = .merged
        return entry
    }

    private func snapshot(_ entries: [CleanupEntry]) -> CleanupSnapshot {
        let targets = CleanupTargets.parse("refs/heads/main\u{0}abc\u{0}\u{0}\n")
        return CleanupSnapshot(targets: targets, target: targets.branches.first, entries: entries)
    }

    /// Bring an app up on `repo` with `snapshot` as the merge result the rows show.
    private func app(_ git: FakeGitClient, snapshot: CleanupSnapshot) async -> AppModel {
        let app = AppModel(environment: makeTestEnvironment(git: git))
        app.mergeStatus.scanDebounce = .zero
        _ = await app.addRepository(path: repo.path)
        await app.mergeStatus.refresh(repo: repo, targetOverride: nil, enabled: true, revision: nil)
        app.mergeStatus.adopt(snapshot, repoPath: repo.path, target: nil, revision: nil)
        return app
    }

    @Test("only worktrees nothing protects count towards the cleanup")
    func eligibleSet() async {
        let primary = Worktree(path: "/repo", branch: "main", isPrimary: true)
        let target = Worktree(path: "/dev", branch: "main")
        let locked = Worktree(path: "/locked", branch: "locked", isLocked: true)
        let browsed = Worktree(path: "/browsed", branch: "browsed")
        let free = Worktree(path: "/free", branch: "free")
        let git = FakeGitClient()
        git.worktreesResult = [primary, target, locked, browsed, free]
        var targetEntry = merged("/dev", branch: "main")
        targetEntry.isTarget = true
        var lockedEntry = merged("/locked", branch: "locked")
        lockedEntry.worktree.isLocked = true
        var primaryEntry = merged("/repo", branch: "main")
        primaryEntry.worktree.isPrimary = true
        let entries = [primaryEntry, targetEntry, lockedEntry,
                       merged("/browsed", branch: "browsed"), merged("/free", branch: "free")]
        let app = await app(git, snapshot: snapshot(entries))
        await app.selector.selectWorktree(browsed)
        let actions = WorktreeGroupActions(app: app, service: RemovalStub(snapshot: snapshot(entries)))

        #expect(actions.eligibleEntries(for: git.worktreesResult).map(\.id) == ["/free"])
    }

    @Test("the confirmation counts what it will remove and mentions ignored files only when there are some")
    func confirmationCopy() async {
        var ignored = merged("/ignored", branch: "ignored")
        ignored.hasIgnoredFiles = true
        ignored.ignoredPaths = [".build/"]
        let plain = merged("/plain", branch: "plain")
        let app = await app(FakeGitClient(), snapshot: snapshot([plain, ignored]))
        let actions = WorktreeGroupActions(app: app, service: RemovalStub(snapshot: snapshot([])))

        #expect(actions.confirmationTitle([plain]) == "Remove 1 worktree folder?")
        #expect(actions.confirmationTitle([plain, ignored]) == "Remove 2 worktree folders?")
        #expect(actions.confirmationMessage([plain])
                == "The folders will be deleted from your Mac. Branches will be kept.")
        #expect(actions.confirmationMessage([plain, ignored])
                == "The folders will be deleted from your Mac. Branches will be kept. "
                + "Ignored files such as build output will be deleted too.")
    }

    @Test("one refused removal is reported and the rest still run, then the list is rescanned")
    func removalContinuesAfterFailure() async {
        let counter = DiscoveryCounter()
        let git = FakeGitClient()
        let primary = Worktree(path: "/repo", branch: "main", isPrimary: true)
        git.worktreesResult = [primary, Worktree(path: "/a", branch: "a"), Worktree(path: "/b", branch: "b")]
        git.beforeWorktrees = { counter.bump() }
        let entries = [merged("/a", branch: "a"), merged("/b", branch: "b")]
        let app = await app(git, snapshot: snapshot(entries))
        let stub = RemovalStub(snapshot: snapshot(entries), refuses: "/a")
        let actions = WorktreeGroupActions(app: app, service: stub)

        // Git removed one of the two folders, so that is what a rescan must find.
        git.worktreesResult = [primary, Worktree(path: "/a", branch: "a")]
        counter.reset()
        await actions.remove(entries)?.value

        #expect(await stub.removed == ["/b"])
        #expect(app.errorMessage == "Couldn't remove a: " + (CleanupError.changed.errorDescription ?? ""))
        #expect(!actions.isWorking)
        // One rescan: the worktree list, then the merge check that regroups it.
        #expect(counter.count == 2)
        #expect(app.selector.worktrees.map(\.path) == ["/repo", "/a"])
    }

    @Test("an in-use worktree is left alone even though it was eligible when confirmed")
    func activeWorktreeIsKept() async {
        let monitor = WorktreeActivityMonitor()
        let git = FakeGitClient()
        git.worktreesResult = [Worktree(path: "/repo", branch: "main", isPrimary: true),
                               Worktree(path: "/busy", branch: "busy")]
        let entries = [merged("/busy", branch: "busy")]
        let app = AppModel(environment: makeTestEnvironment(git: git, monitor: monitor))
        app.mergeStatus.scanDebounce = .zero
        _ = await app.addRepository(path: repo.path)
        await app.mergeStatus.refresh(repo: repo, targetOverride: nil, enabled: true, revision: nil)
        app.mergeStatus.adopt(snapshot(entries), repoPath: repo.path, target: nil, revision: nil)
        let stub = RemovalStub(snapshot: snapshot(entries))
        let actions = WorktreeGroupActions(app: app, service: stub)

        monitor.recordActivity(worktreePath: "/busy", at: Date())
        await actions.remove(entries)?.value

        #expect(await stub.removed.isEmpty)
        #expect(app.errorMessage == "Couldn't remove busy: it is in use.")
    }

    @Test("prune asks git to forget the missing folders, then rescans")
    func prune() async {
        let counter = DiscoveryCounter()
        let git = FakeGitClient()
        git.worktreesResult = [Worktree(path: "/repo", branch: "main", isPrimary: true)]
        git.beforeWorktrees = { counter.bump() }
        let app = await app(git, snapshot: snapshot([]))
        let actions = WorktreeGroupActions(app: app, service: RemovalStub(snapshot: snapshot([])))
        counter.reset()

        await actions.prune()?.value

        #expect(git.prunedRepos == ["/repo"])
        #expect(counter.count == 2)
        #expect(!actions.isWorking)
    }

    @Test("the comparison branch is remembered per repository and forgotten with it")
    func comparisonBranchPreference() async {
        let git = FakeGitClient()
        git.worktreesResult = [Worktree(path: "/repo", branch: "main", isPrimary: true)]
        let env = makeTestEnvironment(git: git)
        let app = AppModel(environment: env)
        _ = await app.addRepository(path: repo.path)

        app.setCleanupTarget("refs/heads/dev", for: repo.path)
        app.saveLayout(SectionLayout(windowHeight: 400), forRepo: repo.path)
        #expect(AppModel(environment: env).cleanupTarget(for: repo.path) == "refs/heads/dev")
        #expect(app.cleanupTarget(for: "/another") == nil)

        app.setCleanupTarget(nil, for: repo.path)
        #expect(env.store.load().cleanupTargetByRepo?[repo.path] == nil)

        app.setCleanupTarget("refs/heads/dev", for: repo.path)
        app.removeRepository(repo)
        let reopened = AppModel(environment: env)
        #expect(reopened.cleanupTarget(for: repo.path) == nil)
        #expect(reopened.layout(forRepo: repo.path) == nil)
    }
}
