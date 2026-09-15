import Foundation
import Testing
import TeebeCore
@testable import Teebe

private actor CleanupStub: WorktreeCleanupChecking {
    let snapshot: CleanupSnapshot
    var removed: [String] = []
    var fetchCount = 0
    var gate: Gate?
    var started = false
    init(snapshot: CleanupSnapshot) { self.snapshot = snapshot }
    func hold(_ value: Gate) { gate = value }
    func scan(repoPath: String, targetOverride: String?) async throws -> CleanupSnapshot {
        started = true
        if let gate {
            self.gate = nil
            await gate.wait()
        }
        return CleanupSnapshot(targets: snapshot.targets, target: snapshot.targets.resolve(targetOverride), entries: snapshot.entries)
    }
    func fetch(repoPath: String) { fetchCount += 1 }
    func remove(repoPath: String, entry: CleanupEntry, target: CleanupBranch, includingIgnored: Bool) {
        removed.append(entry.id)
    }
}

@MainActor
@Suite("Cleanup view model")
struct WorktreeCleanupModelTests {
    private func snapshot() -> CleanupSnapshot {
        let targets = CleanupTargets.parse("refs/heads/main\u{0}abc\u{0}\u{0}\n")
        var clean = CleanupEntry(worktree: Worktree(path: "/clean", branch: "feature", head: "abc"))
        clean.mergeStatus = .merged
        var dirty = CleanupEntry(worktree: Worktree(path: "/dirty", branch: "dirty", head: "abc"))
        dirty.mergeStatus = .merged
        dirty.hasLocalChanges = true
        var ignored = clean
        ignored.worktree.path = "/ignored"
        ignored.hasIgnoredFiles = true
        return CleanupSnapshot(targets: targets, target: targets.automatic, entries: [clean, dirty, ignored])
    }

    @Test("target overrides persist per repository and auto clears the override")
    func preference() async throws {
        let env = makeTestEnvironment()
        let app = AppModel(environment: env)
        let model = WorktreeCleanupModel(app: app, repo: Repository(path: "/repo"), service: CleanupStub(snapshot: snapshot()))
        await model.chooseTarget("refs/heads/dev")
        #expect(AppModel(environment: env).cleanupTarget(for: "/repo") == "refs/heads/dev")
        #expect(app.cleanupTarget(for: "/another") == nil)
        app.floatOnTop = true
        #expect(env.store.load().cleanupTargetByRepo?["/repo"] == "refs/heads/dev")
        await model.chooseTarget("")
        #expect(env.store.load().cleanupTargetByRepo?["/repo"] == nil)
    }

    @Test("selection is explicit, removal needs confirmation, and ignored files need consent")
    func confirmation() async {
        let stub = CleanupStub(snapshot: snapshot())
        let model = WorktreeCleanupModel(app: AppModel(environment: makeTestEnvironment()), repo: Repository(path: "/repo"), service: stub)
        await model.refresh()
        #expect(model.selectedPaths.isEmpty)
        model.selectEligible()
        #expect(model.selectedPaths == ["/clean"])
        await model.confirmRemoval()?.value
        #expect(await stub.removed.isEmpty)
        model.includeIgnored = true
        #expect(model.selectedPaths.isEmpty)
        model.selectEligible()
        #expect(model.selectedPaths == ["/clean", "/ignored"])
        model.requestRemoval()
        #expect(model.pendingRemoval?.entries.count == 2)
        let removal = model.confirmRemoval()
        model.pendingRemoval = nil // The dialog resets its binding after the action returns.
        #expect(model.isRemoving)
        await removal?.value
        #expect(await stub.removed == ["/clean", "/ignored"])
        #expect(model.selectedPaths.isEmpty)
        #expect(await stub.fetchCount == 0)
    }

    @Test("a fresh activity signal blocks previously selected worktrees")
    func activeGuard() async {
        let monitor = WorktreeActivityMonitor()
        let stub = CleanupStub(snapshot: snapshot())
        let model = WorktreeCleanupModel(app: AppModel(environment: makeTestEnvironment(monitor: monitor)), repo: Repository(path: "/repo"), service: stub)
        await model.refresh()
        model.selectEligible()
        model.requestRemoval()
        monitor.recordActivity(worktreePath: "/clean", at: Date())
        await model.confirmRemoval()?.value
        #expect(await stub.removed.isEmpty)
    }

    @Test("closing a pending scan prevents late results, fetch happens only on request")
    func cancellation() async {
        let stub = CleanupStub(snapshot: snapshot())
        let gate = Gate()
        await stub.hold(gate)
        let model = WorktreeCleanupModel(app: AppModel(environment: makeTestEnvironment()), repo: Repository(path: "/repo"), service: stub)
        let task = Task { await model.refresh(fetch: true) }
        while await !stub.started { await Task.yield() }
        model.cancel()
        await gate.open()
        await task.value
        #expect(model.snapshot == nil)
        #expect(!model.isChecking)
        #expect(await stub.fetchCount == 1)
    }
    @Test("a late scan cannot overwrite a newly chosen comparison branch")
    func latestTargetWins() async {
        let stub = CleanupStub(snapshot: snapshot())
        let gate = Gate()
        await stub.hold(gate)
        let model = WorktreeCleanupModel(app: AppModel(environment: makeTestEnvironment()), repo: Repository(path: "/repo"), service: stub)
        let oldScan = Task { await model.refresh() }
        while await !stub.started { await Task.yield() }
        await model.chooseTarget("refs/heads/missing")
        await gate.open()
        await oldScan.value
        #expect(model.targetOverride == "refs/heads/missing")
        #expect(model.snapshot?.target == nil)
        #expect(!model.isChecking)
    }

    @Test("agent activity is read again before deleting a previously eligible worktree")
    func freshAgentGuard() async {
        let stub = CleanupStub(snapshot: snapshot())
        let env = makeTestEnvironment(agentStatuses: { paths, _ in Dictionary(uniqueKeysWithValues: paths.map { ($0, .working) }) })
        let model = WorktreeCleanupModel(app: AppModel(environment: env), repo: Repository(path: "/repo"), service: stub)
        await model.refresh()
        model.selectEligible()
        model.requestRemoval()
        await model.confirmRemoval()?.value
        #expect(await stub.removed.isEmpty)
    }

}
