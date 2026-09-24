import Foundation
import Testing
import TeebeCore
@testable import Teebe

/// Removal stub: records what it was asked to remove and can refuse one worktree,
/// the way Git does when the folder changed under the confirmation.
private actor RemovalStub: WorktreeCleanupChecking {
    let snapshot: CleanupSnapshot
    private(set) var removed: [String] = []
    private(set) var branchRequests: [Bool] = []
    /// What a removal says happened to the branch when deletion was asked for.
    var branchOutcome: BranchDeletion = .deleted
    func setBranchOutcome(_ outcome: BranchDeletion) { branchOutcome = outcome }
    /// The worktree this refuses to remove.
    var refuses: String?
    init(snapshot: CleanupSnapshot, refuses: String? = nil) {
        self.snapshot = snapshot
        self.refuses = refuses
    }
    private(set) var scans = 0
    func resetScans() { scans = 0 }
    func scan(repoPath: String, extraTarget: String?) async throws -> CleanupSnapshot {
        scans += 1
        return snapshot
    }
    func remove(repoPath: String, entry: CleanupEntry, includingIgnored: Bool, deleteBranch: Bool) async throws -> BranchDeletion {
        guard entry.id != refuses else { throw CleanupError.changed }
        removed.append(entry.id)
        branchRequests.append(deleteBranch)
        return deleteBranch ? branchOutcome : .notRequested
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
        return CleanupSnapshot(targets: targets, mergeTargets: targets.branches, entries: entries)
    }

    /// Bring an app up on `repo` with `stub`'s scan as the merge result the rows show.
    private func app(_ git: FakeGitClient, stub: RemovalStub,
                     monitor: WorktreeActivityMonitor = WorktreeActivityMonitor()) async -> AppModel {
        let app = AppModel(environment: makeTestEnvironment(git: git, monitor: monitor), mergeService: stub)
        app.mergeStatus.scanDebounce = .zero
        _ = await app.addRepository(path: repo.path)
        await app.mergeStatus.refresh(repo: repo, extraTarget: nil, enabled: true, revision: nil)
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
        let stub = RemovalStub(snapshot: snapshot(entries))
        let app = await app(git, stub: stub)
        await app.selector.selectWorktree(browsed)
        let actions = WorktreeGroupActions(app: app, service: stub)

        #expect(actions.eligibleEntries(for: git.worktreesResult).map(\.id) == ["/free"])
    }

    @Test("the confirmation counts what it will remove and mentions ignored files only when there are some")
    func confirmationCopy() async {
        var ignored = merged("/ignored", branch: "ignored")
        ignored.hasIgnoredFiles = true
        ignored.ignoredPaths = [".build/"]
        let plain = merged("/plain", branch: "plain")
        let stub = RemovalStub(snapshot: snapshot([plain, ignored]))
        let app = await app(FakeGitClient(), stub: stub)
        let actions = WorktreeGroupActions(app: app, service: stub)

        #expect(actions.confirmationTitle([plain]) == "Remove 1 worktree folder?")
        #expect(actions.confirmationTitle([plain, ignored]) == "Remove 2 worktree folders?")
        #expect(actions.confirmationMessage([plain], deleteBranch: false)
                == "The folders will be deleted from your Mac. Branches will be kept.")
        #expect(actions.confirmationMessage([plain, ignored], deleteBranch: false)
                == "The folders will be deleted from your Mac. Branches will be kept. "
                + "Ignored files such as build output will be deleted too.")
        #expect(actions.confirmationMessage([plain], deleteBranch: true)
                == "The folders will be deleted from your Mac. "
                + "Their local branches will be deleted too; remote branches are kept.")
    }

    @Test("one refused removal is reported and the rest still run, then the list is rescanned")
    func removalContinuesAfterFailure() async {
        let counter = DiscoveryCounter()
        let git = FakeGitClient()
        let primary = Worktree(path: "/repo", branch: "main", isPrimary: true)
        git.worktreesResult = [primary, Worktree(path: "/a", branch: "a"), Worktree(path: "/b", branch: "b")]
        git.beforeWorktrees = { counter.bump() }
        let entries = [merged("/a", branch: "a"), merged("/b", branch: "b")]
        let stub = RemovalStub(snapshot: snapshot(entries), refuses: "/a")
        let app = await app(git, stub: stub)
        let actions = WorktreeGroupActions(app: app, service: stub)

        // Git removed one of the two folders, so that is what a rescan must find.
        git.worktreesResult = [primary, Worktree(path: "/a", branch: "a")]
        counter.reset()
        await stub.resetScans()
        await actions.remove(entries, deleteBranch: false)?.value

        #expect(await stub.removed == ["/b"])
        #expect(app.errorMessage == "Couldn't remove a: " + (CleanupError.changed.errorDescription ?? ""))
        #expect(!actions.isWorking)
        // Rescanned once: the worktree list, then the merge check that regroups it.
        #expect(counter.count == 1)
        #expect(await stub.scans == 1)
        #expect(app.selector.worktrees.map(\.path) == ["/repo", "/a"])
    }

    @Test("an in-use worktree is left alone even though it was eligible when confirmed")
    func activeWorktreeIsKept() async {
        let monitor = WorktreeActivityMonitor()
        let git = FakeGitClient()
        git.worktreesResult = [Worktree(path: "/repo", branch: "main", isPrimary: true),
                               Worktree(path: "/busy", branch: "busy")]
        let entries = [merged("/busy", branch: "busy")]
        let stub = RemovalStub(snapshot: snapshot(entries))
        let app = await app(git, stub: stub, monitor: monitor)
        let actions = WorktreeGroupActions(app: app, service: stub)

        monitor.recordActivity(worktreePath: "/busy", at: Date())
        await actions.remove(entries, deleteBranch: true)?.value

        #expect(await stub.removed.isEmpty)
        #expect(app.errorMessage == "Couldn't remove busy: it is in use.")
    }

    @Test("prune asks git to forget the missing folders, then rescans")
    func prune() async {
        let counter = DiscoveryCounter()
        let git = FakeGitClient()
        git.worktreesResult = [Worktree(path: "/repo", branch: "main", isPrimary: true)]
        git.beforeWorktrees = { counter.bump() }
        let stub = RemovalStub(snapshot: snapshot([]))
        let app = await app(git, stub: stub)
        let actions = WorktreeGroupActions(app: app, service: stub)
        counter.reset()
        await stub.resetScans()

        await actions.prune()?.value

        #expect(git.prunedRepos == ["/repo"])
        #expect(counter.count == 1)
        #expect(await stub.scans == 1)
        #expect(!actions.isWorking)
    }

    @Test("the row trash removes a merged row, browsed or not, passing the branch choice through")
    func trashRemovesMergedRow() async {
        let git = FakeGitClient()
        let feature = Worktree(path: "/feature", branch: "feature", head: "abc")
        git.worktreesResult = [Worktree(path: "/repo", branch: "main", isPrimary: true), feature]
        let entry = merged("/feature", branch: "feature")
        let stub = RemovalStub(snapshot: snapshot([entry]))
        let app = await app(git, stub: stub)
        await app.selector.selectWorktree(feature)
        let actions = WorktreeGroupActions(app: app, service: stub)
        // Bulk clean-up leaves the browsed row alone…
        #expect(actions.eligibleEntries(for: git.worktreesResult).isEmpty)
        // …but the row's own trash is an explicit choice.
        await stub.setBranchOutcome(.kept)
        await actions.perform(.remove(entry), deleteBranch: true)?.value
        #expect(await stub.removed == ["/feature"])
        #expect(await stub.branchRequests == [true])
        #expect(app.errorMessage == "Removed feature, but kept its branch: it changed or Git refused to delete it.")
    }

    @Test("the trash on a missing row prunes")
    func trashPrunesMissingRow() async {
        let git = FakeGitClient()
        git.worktreesResult = [Worktree(path: "/repo", branch: "main", isPrimary: true)]
        let stub = RemovalStub(snapshot: snapshot([]))
        let app = await app(git, stub: stub)
        await WorktreeGroupActions(app: app, service: stub).perform(.prune, deleteBranch: true)?.value
        #expect(git.prunedRepos == ["/repo"])
    }

    @Test("the extra merge target is remembered per repository and forgotten with it")
    func extraMergeTargetPreference() async {
        let git = FakeGitClient()
        git.worktreesResult = [Worktree(path: "/repo", branch: "main", isPrimary: true)]
        let env = makeTestEnvironment(git: git)
        let app = AppModel(environment: env)
        _ = await app.addRepository(path: repo.path)

        let revision = app.mergeTargetRevision
        app.setExtraMergeTarget("refs/heads/dev", for: repo.path)
        #expect(app.mergeTargetRevision == revision + 1)
        app.saveLayout(SectionLayout(windowHeight: 400), forRepo: repo.path)
        #expect(AppModel(environment: env).extraMergeTarget(for: repo.path) == "refs/heads/dev")
        #expect(app.extraMergeTarget(for: "/another") == nil)

        app.setExtraMergeTarget(nil, for: repo.path)
        #expect(env.store.load().cleanupTargetByRepo?[repo.path] == nil)

        app.setExtraMergeTarget("refs/heads/dev", for: repo.path)
        app.removeRepository(repo)
        let reopened = AppModel(environment: env)
        #expect(reopened.extraMergeTarget(for: repo.path) == nil)
        #expect(reopened.layout(forRepo: repo.path) == nil)
    }

    @Test("deleting the branch on removal defaults on and remembers the last choice")
    func deleteBranchPreference() {
        let env = makeTestEnvironment()
        #expect(AppModel(environment: env).deleteBranchOnRemove)
        AppModel(environment: env).deleteBranchOnRemove = false
        #expect(!AppModel(environment: env).deleteBranchOnRemove)
        #expect(env.store.load().deleteBranchOnRemove == false)
    }
}
