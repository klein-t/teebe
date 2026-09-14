import Testing
import TeebeCore
@testable import Teebe

private actor MergeScanStub: WorktreeCleanupChecking {
    private(set) var calls = 0
    private(set) var requestedTarget: String?
    var gate: Gate?
    func hold(_ gate: Gate) { self.gate = gate }
    func scan(repoPath: String, targetOverride: String?) async throws -> CleanupSnapshot {
        calls += 1
        requestedTarget = targetOverride
        if let gate { self.gate = nil; await gate.wait() }
        let targets = CleanupTargets.parse("refs/heads/dev\u{0}abc\u{0}\u{0}\n")
        var entry = CleanupEntry(worktree: Worktree(path: repoPath + "/feature", branch: "feature"))
        entry.mergeStatus = .merged
        return CleanupSnapshot(targets: targets, target: targets.resolve(targetOverride), entries: [entry])
    }
    func fetch(repoPath: String) { Issue.record("Row indicators must never fetch") }
    func remove(repoPath: String, entry: CleanupEntry, target: CleanupBranch, includingIgnored: Bool) {
        Issue.record("Row indicators must never remove a worktree")
    }
}

@MainActor
@Suite("Worktree merge indicators")
struct WorktreeMergeModelTests {
    @Test("disabled indicators skip scanning and clear previous results")
    func visibility() async {
        let service = MergeScanStub()
        let model = WorktreeMergeModel(service: service)
        await model.refresh(repo: Repository(path: "/repo"), targetOverride: "refs/heads/dev", enabled: false)
        #expect(await service.calls == 0)
        await model.refresh(repo: Repository(path: "/repo"), targetOverride: "refs/heads/dev", enabled: true)
        #expect(model.entry(for: "/repo/feature")?.mergeStatus == .merged)
        #expect(await service.requestedTarget == "refs/heads/dev")
        await model.refresh(repo: Repository(path: "/repo"), targetOverride: nil, enabled: false)
        #expect(model.snapshot == nil)
        #expect(await service.calls == 1)
    }

    @Test("a late scan cannot replace the newly selected project")
    func staleScan() async {
        let service = MergeScanStub()
        let gate = Gate()
        await service.hold(gate)
        let model = WorktreeMergeModel(service: service)
        let first = Task { await model.refresh(repo: Repository(path: "/old"), targetOverride: nil, enabled: true) }
        while await service.calls == 0 { await Task.yield() }
        await model.refresh(repo: Repository(path: "/new"), targetOverride: "refs/heads/dev", enabled: true)
        await gate.open()
        await first.value
        #expect(model.entry(for: "/old/feature") == nil)
        #expect(model.entry(for: "/new/feature")?.mergeStatus == .merged)
        #expect(!model.isChecking)
    }

    @Test("turning icons off while checking cannot restore old icons")
    func disableWhileChecking() async {
        let service = MergeScanStub()
        let gate = Gate()
        await service.hold(gate)
        let model = WorktreeMergeModel(service: service)
        let first = Task { await model.refresh(repo: Repository(path: "/repo"), targetOverride: nil, enabled: true) }
        while await service.calls == 0 { await Task.yield() }
        await model.refresh(repo: Repository(path: "/repo"), targetOverride: nil, enabled: false)
        await gate.open()
        await first.value
        #expect(model.snapshot == nil)
        #expect(!model.isChecking)
    }
}
