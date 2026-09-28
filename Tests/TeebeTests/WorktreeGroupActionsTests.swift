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

/// A value a test changes while the app reads it from another thread.
private final class Box<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
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
        entry.isInspected = true
        return entry
    }

    private func snapshot(_ entries: [CleanupEntry]) -> CleanupSnapshot {
        let targets = CleanupTargets.parse("refs/heads/main\u{0}abc\u{0}\u{0}\n")
        return CleanupSnapshot(targets: targets, mergeTargets: targets.branches, entries: entries)
    }

    /// Bring an app up on `repo` with `stub`'s scan as the merge result the rows show.
    private func app(_ git: FakeGitClient, stub: RemovalStub,
                     monitor: WorktreeActivityMonitor = WorktreeActivityMonitor(),
                     agents: Box<[String: AgentActivityState]> = Box([:]),
                     inUse: Box<Set<String>> = Box([])) async -> AppModel {
        let env = makeTestEnvironment(git: git, monitor: monitor, agentStatuses: { _, _ in agents.value },
                                      worktreesInUse: { _, _ in inUse.value })
        let app = AppModel(environment: env, mergeService: stub)
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

    @Test("the confirmation counts what it will remove, lists each worktree, and mentions ignored files only when there are some")
    func confirmationCopy() async {
        var ignored = merged("/ignored", branch: "ignored")
        ignored.hasIgnoredFiles = true
        ignored.ignoredPaths = [".build/"]
        let plain = merged("/plain", branch: "plain")
        let stub = RemovalStub(snapshot: snapshot([plain, ignored]))
        let app = await app(FakeGitClient(), stub: stub)
        let actions = WorktreeGroupActions(app: app, service: stub)

        #expect(actions.confirmationTitle([plain]) == "Remove 1 worktree?")
        #expect(actions.confirmationTitle([plain, ignored]) == "Remove 2 worktrees?")
        #expect(actions.confirmationItems([plain, ignored])
                == [WorktreeRemovalItem(name: "plain", path: "/plain", isMerged: true),
                    WorktreeRemovalItem(name: "ignored", path: "/ignored", isMerged: true)])
        // A detached checkout is named by its folder; a home path is shortened for display only.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let detached = CleanupEntry(worktree: Worktree(path: home + "/wt/loose", head: "abc", isDetached: true))
        let item = actions.confirmationItems([detached])[0]
        #expect(item == WorktreeRemovalItem(name: "loose", path: home + "/wt/loose", isMerged: false))
        #expect(item.displayPath == "~/wt/loose")
        #expect(actions.confirmationMessage([plain], deleteBranch: false)
                == "The folder will be deleted from your Mac. The branch will be kept.")
        #expect(actions.confirmationMessage([plain, ignored], deleteBranch: false)
                == "The folders will be deleted from your Mac. Branches will be kept.")
        // Only the worktree that has gitignored files says so, by name.
        #expect(actions.confirmationNotices([plain]).isEmpty)
        #expect(actions.confirmationNotices([plain, ignored]).map(\.summary)
                == ["“ignored” also deletes its gitignored files. Git can’t restore these files."])
        #expect(actions.confirmationMessage([plain], deleteBranch: true)
                == "The folder will be deleted from your Mac. "
                + "Its local branch will be deleted too; the remote branch is kept.")
        #expect(actions.confirmationMessage([plain, ignored], deleteBranch: true)
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

    @Test("removing all re-checks each worktree as it goes: ones that no longer qualify are skipped and every one is reported")
    func bulkRemovalSkipsAndReportsEach() async {
        let monitor = WorktreeActivityMonitor()
        let git = FakeGitClient()
        git.worktreesResult = [Worktree(path: "/repo", branch: "main", isPrimary: true)]
            + ["a", "busy", "changed", "b"].map { Worktree(path: "/" + $0, branch: $0, head: "abc") }
        let entries = ["a", "busy", "changed", "b"].map { merged("/" + $0, branch: $0) }
        // Git finds "changed" no longer qualifies when asked to remove it.
        let stub = RemovalStub(snapshot: snapshot(entries), refuses: "/changed")
        let app = await app(git, stub: stub, monitor: monitor)
        let actions = WorktreeGroupActions(app: app, service: stub)
        #expect(actions.eligibleEntries(for: git.worktreesResult).map(\.id) == ["/a", "/busy", "/changed", "/b"])

        // Something started in "busy" after the sheet opened.
        monitor.recordActivity(worktreePath: "/busy", at: Date())
        await actions.remove(entries, deleteBranch: true)?.value

        #expect(await stub.removed == ["/a", "/b"])
        #expect(app.errorMessage == "Couldn't remove busy: files are changing or a command is running in it. "
                + "Couldn't remove changed: " + (CleanupError.changed.errorDescription ?? ""))
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

        // Written to a minute ago: still inside the window the working orb uses.
        monitor.recordActivity(worktreePath: "/busy", at: Date().addingTimeInterval(-60))
        await actions.remove(entries, deleteBranch: true)?.value

        #expect(await stub.removed.isEmpty)
        #expect(app.errorMessage == "Couldn't remove busy: files are changing or a command is running in it.")
    }

    @Test("an agent working or waiting, or anything open in the folder, stops a removal at the moment it runs")
    func freshActivityRefuses() async {
        let git = FakeGitClient()
        let feature = Worktree(path: "/feature", branch: "feature")
        git.worktreesResult = [Worktree(path: "/repo", branch: "main", isPrimary: true), feature]
        let entry = merged("/feature", branch: "feature")
        let stub = RemovalStub(snapshot: snapshot([entry]))
        let agents = Box<[String: AgentActivityState]>([:])
        let inUse = Box<Set<String>>([])
        let app = await app(git, stub: stub, agents: agents, inUse: inUse)
        let actions = WorktreeGroupActions(app: app, service: stub)
        // Eligible when the sheet opened; what runs is the captured action.
        let action = app.removalAction(for: feature)
        #expect(action == .remove(entry))
        let steps: [(state: [String: AgentActivityState], inUse: Set<String>)] = [
            (["/feature": .needsAttention], []), (["/feature": .working], []), ([:], ["/feature"])
        ]
        let reasons = ["an agent is waiting for you in it.", "an agent is working in it.",
                       "it is open in a terminal, editor or agent."]
        for (step, reason) in zip(steps, reasons) {
            agents.value = step.state
            inUse.value = step.inUse
            await actions.perform(.remove(entry), deleteBranch: true)?.value
            #expect(app.errorMessage == "Couldn't remove feature: " + reason)
        }
        #expect(await stub.removed.isEmpty)
        agents.value = [:]
        inUse.value = []
        await actions.perform(.remove(entry), deleteBranch: false)?.value
        #expect(await stub.removed == ["/feature"])
    }

    @Test("rows an agent is in, or a result being rechecked, stay out of the clean-up and the sheet says why")
    func skippedRows() async {
        let git = FakeGitClient()
        let rows = ["free", "waiting", "working", "live", "moved", "browsed"].map {
            Worktree(path: "/" + $0, branch: $0, head: $0 == "moved" ? "def" : "abc")
        }
        git.worktreesResult = [Worktree(path: "/repo", branch: "main", isPrimary: true)] + rows
        let stub = RemovalStub(snapshot: snapshot(rows.map { merged($0.path, branch: $0.branch ?? "") }))
        let monitor = WorktreeActivityMonitor()
        monitor.recordActivity(worktreePath: "/live", at: Date())
        let agents = Box<[String: AgentActivityState]>(["/waiting": .needsAttention, "/working": .working])
        let app = await app(git, stub: stub, monitor: monitor, agents: agents)
        await app.selector.refreshWorktreeInfo()
        await app.selector.selectWorktree(rows[5])
        let actions = WorktreeGroupActions(app: app, service: stub)

        #expect(actions.eligibleEntries(for: rows).map(\.id) == ["/free"])
        // The group agrees with the bin: only the browsed row, removable from its own trash, is kept out of it.
        #expect(rows.filter { app.worktreeStatus(for: $0).group == .merged }.map(\.path) == ["/free", "/browsed"])
        #expect(rows.filter { app.worktreeStatus(for: $0).mark == .merged }.map(\.path) == ["/free", "/browsed"])
        #expect(actions.skippedFacts(for: rows).map(\.text) == [
            "“waiting” is skipped: an agent is waiting for you here",
            "“working” is skipped: an agent is working here",
            "“live” is skipped: files are changing or a command is running here",
            "“moved” is skipped: it is still being checked",
            "“browsed” is skipped: it’s the worktree you’re viewing"
        ])
    }

    @Test("what the list and the sheets read runs no git, no probe and no save: it is drawn on every layout pass")
    func viewReadsArePure() async throws {
        let git = FakeGitClient()
        let rows = [Worktree(path: "/free", branch: "free", head: "abc"), Worktree(path: "/moved", branch: "moved", head: "def")]
        git.worktreesResult = [Worktree(path: "/repo", branch: "main", isPrimary: true)] + rows
        let discoveries = DiscoveryCounter()
        git.beforeWorktrees = { discoveries.bump() }
        let probes = DiscoveryCounter()
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tb-test-\(UUID().uuidString)").appendingPathComponent("state.json")
        let env = makeTestEnvironment(git: git, store: AppStateStore(url: storeURL),
                                      agentStatuses: { _, _ in probes.bump(); return ["/free": .needsAttention] },
                                      worktreesInUse: { _, _ in probes.bump(); return ["/free"] })
        let stub = RemovalStub(snapshot: snapshot(rows.map { merged($0.path, branch: $0.branch ?? "") }))
        let app = AppModel(environment: env, mergeService: stub)
        app.mergeStatus.scanDebounce = .zero
        _ = await app.addRepository(path: repo.path)
        await app.mergeStatus.refresh(repo: repo, extraTarget: nil, enabled: true, revision: nil)
        await app.selector.refreshWorktreeInfo()
        let actions = WorktreeGroupActions(app: app, service: stub)
        let saved = try? Data(contentsOf: storeURL)
        let (statusReads, found, probed) = (git.statusCallCount, discoveries.count, probes.count)
        await stub.resetScans()

        for _ in 0..<3 {
            _ = app.worktreeList(collapsed: [])
            for row in app.selector.worktrees {
                _ = app.worktreeStatus(for: row)
                _ = app.removalPrompt(for: row)
                _ = app.removalAction(for: row)
            }
            _ = actions.eligibleEntries(for: rows)
            _ = actions.skippedFacts(for: rows)
        }
        await Task.yield()

        #expect(git.statusCallCount == statusReads)
        #expect(discoveries.count == found)
        #expect(probes.count == probed)
        #expect(await stub.scans == 0)
        #expect((try? Data(contentsOf: storeURL)) == saved)
    }

    @Test("a removal asked for while another runs is refused out loud")
    func busyRefusal() async {
        let git = FakeGitClient()
        git.worktreesResult = [Worktree(path: "/repo", branch: "main", isPrimary: true), Worktree(path: "/a", branch: "a")]
        let entry = merged("/a", branch: "a")
        let stub = RemovalStub(snapshot: snapshot([entry]))
        let app = await app(git, stub: stub)
        let actions = WorktreeGroupActions(app: app, service: stub)
        let first = actions.remove([entry], deleteBranch: false)
        #expect(actions.perform(.remove(entry), deleteBranch: false) == nil)
        #expect(app.errorMessage == "Couldn't remove a: another removal is still running.")
        await first?.value
    }

    @Test("a broken-link row offers a removal the prompt refuses, and a row being rechecked has nothing to confirm yet")
    func removalActions() async {
        let git = FakeGitClient()
        let unlinked = Worktree(path: "/unlinked", branch: "unlinked", head: "abc")
        let moved = Worktree(path: "/moved", branch: "moved", head: "def")
        git.worktreesResult = [Worktree(path: "/repo", branch: "main", isPrimary: true), unlinked, moved]
        var broken = merged("/unlinked", branch: "unlinked")
        broken.isBroken = true
        let stub = RemovalStub(snapshot: snapshot([broken, merged("/moved", branch: "moved")]))
        let app = await app(git, stub: stub)
        #expect(app.removalAction(for: unlinked) == .remove(broken))
        #expect(!app.removalPrompt(for: unlinked).canRemove)
        #expect(app.removalAction(for: moved) == nil)
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

    @Test("asking for a row's card from the keyboard names the row, and asking again asks anew")
    func keyboardCardReveal() {
        let app = AppModel(environment: makeTestEnvironment())
        #expect(app.worktreeCardReveal == nil)
        app.revealWorktreeCard(for: "/a")
        #expect(app.worktreeCardReveal?.path == "/a")
        let first = app.worktreeCardReveal?.count
        app.revealWorktreeCard(for: "/a")
        #expect(app.worktreeCardReveal?.count != first)
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
