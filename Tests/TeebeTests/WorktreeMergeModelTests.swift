import Testing
import TeebeCore
@testable import Teebe

private actor MergeScanStub: WorktreeCleanupChecking {
    private(set) var calls = 0
    private(set) var requestedTarget: String?
    var fails = false
    func fail() { fails = true }
    var gate: Gate?
    func hold(_ gate: Gate) { self.gate = gate }
    func scan(repoPath: String, targetOverride: String?) async throws -> CleanupSnapshot {
        calls += 1
        requestedTarget = targetOverride
        if let gate { self.gate = nil; await gate.wait() }
        if fails { throw CleanupError.gitFailed }
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
        let model = makeModel(service)
        await model.refresh(repo: Repository(path: "/repo"), targetOverride: "refs/heads/dev", enabled: false)
        #expect(await service.calls == 0)
        await model.refresh(repo: Repository(path: "/repo"), targetOverride: "refs/heads/dev", enabled: true)
        #expect(model.entry(for: "/repo/feature")?.entry.mergeStatus == .merged)
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
        let model = makeModel(service)
        let first = Task { await model.refresh(repo: Repository(path: "/old"), targetOverride: nil, enabled: true) }
        while await service.calls == 0 { await Task.yield() }
        await model.refresh(repo: Repository(path: "/new"), targetOverride: "refs/heads/dev", enabled: true)
        await gate.open()
        await first.value
        #expect(model.entry(for: "/old/feature") == nil)
        #expect(model.entry(for: "/new/feature")?.entry.mergeStatus == .merged)
        #expect(!model.isChecking)
    }

    @Test("turning icons off while checking cannot restore old icons")
    func disableWhileChecking() async {
        let service = MergeScanStub()
        let gate = Gate()
        await service.hold(gate)
        let model = makeModel(service)
        let first = Task { await model.refresh(repo: Repository(path: "/repo"), targetOverride: nil, enabled: true) }
        while await service.calls == 0 { await Task.yield() }
        await model.refresh(repo: Repository(path: "/repo"), targetOverride: nil, enabled: false)
        await gate.open()
        await first.value
        #expect(model.snapshot == nil)
        #expect(!model.isChecking)
    }
    @Test("unchanged refresh identity reuses recent results without another scan")
    func reuse() async {
        let service = MergeScanStub()
        let model = makeModel(service)
        for _ in 0..<3 {
            await model.refresh(repo: Repository(path: "/repo"), targetOverride: nil, enabled: true, revision: 1)
        }
        #expect(await service.calls == 1)
        #expect(model.snapshot != nil)
    }

    @Test("background refresh retains visible results but a failed check clears them")
    func backgroundRefresh() async {
        let service = MergeScanStub()
        let model = makeModel(service)
        await model.refresh(repo: Repository(path: "/repo"), targetOverride: nil, enabled: true, revision: 1)
        let gate = Gate()
        await service.hold(gate)
        let refresh = Task {
            await model.refresh(repo: Repository(path: "/repo"), targetOverride: nil, enabled: true, revision: 2)
        }
        while await service.calls < 2 { await Task.yield() }
        #expect(model.snapshot != nil)
        #expect(model.isChecking)
        await service.fail()
        await gate.open()
        await refresh.value
        #expect(model.snapshot == nil)
        #expect(!model.isChecking)
    }

    @Test("returning to a project displays its own cached result while checking")
    func returnToProject() async {
        let service = MergeScanStub()
        let model = makeModel(service)
        await model.refresh(repo: Repository(path: "/one"), targetOverride: nil, enabled: true)
        await model.refresh(repo: Repository(path: "/two"), targetOverride: nil, enabled: true)
        let gate = Gate()
        await service.hold(gate)
        let refresh = Task { await model.refresh(repo: Repository(path: "/one"), targetOverride: nil, enabled: true) }
        while await service.calls < 3 { await Task.yield() }
        #expect(model.entry(for: "/one/feature") != nil)
        #expect(model.entry(for: "/two/feature") == nil)
        await gate.open()
        await refresh.value
    }

    @Test("switching comparison branch cannot show a late result for the previous target")
    func targetSwitch() async {
        let service = MergeScanStub()
        let gate = Gate()
        await service.hold(gate)
        let model = makeModel(service)
        let repo = Repository(path: "/repo")
        let old = Task { await model.refresh(repo: repo, targetOverride: "refs/heads/main", enabled: true) }
        while await service.calls == 0 { await Task.yield() }
        await model.refresh(repo: repo, targetOverride: "refs/heads/dev", enabled: true)
        await gate.open()
        await old.value
        #expect(model.snapshot?.target?.ref == "refs/heads/dev")
        #expect(!model.isChecking)
    }

    @Test("active file status updates one row without scanning or masking new commits")
    func localOverlay() async {
        let service = MergeScanStub()
        let model = makeModel(service)
        await model.refresh(repo: Repository(path: "/repo"), targetOverride: nil, enabled: true)
        let changed = StatusParser.parse("? new.txt\u{0}")
        #expect(model.entry(for: "/repo/feature", localStatus: changed)?.entry.hasLocalChanges == true)
        #expect(model.entry(for: "/repo/feature", localStatus: changed)?.localChangeCount == 1)
        #expect(model.entry(for: "/repo/feature", localStatus: StatusResult())?.entry.hasLocalChanges == false)
        #expect(await service.calls == 1)
    }

    @Test("a commit in one worktree keeps its group and rechecks only that row")
    func movedHeadStaysInItsGroup() async {
        let service = MergeScanStub()
        let model = makeModel(service)
        await model.refresh(repo: Repository(path: "/repo"), targetOverride: nil, enabled: true)
        let settled = model.entry(for: "/repo/feature")
        #expect(WorktreeGroup.classify(settled) == .merged)

        // The user commits in the worktree they are browsing: HEAD moves ahead of
        // the scan. The row must not fall into the catch-all group and bounce back.
        let committed = model.entry(for: "/repo/feature", localStatus: StatusResult(oid: "new-head"))
        #expect(committed?.isRechecking == true)
        #expect(committed?.entry.mergeStatus == .merged)
        #expect(WorktreeGroup.classify(committed) == .merged)

        await model.recheck(path: "/repo/feature")
        #expect(await service.calls == 2)
        #expect(model.entry(for: "/repo/feature")?.isRechecking == false)
        #expect(model.entry(for: "/repo/feature")?.entry.mergeStatus == .merged)
    }

    @Test("a burst of refresh keys collapses into a single scan")
    func burstCoalescing() async {
        let service = MergeScanStub()
        let model = WorktreeMergeModel(service: service)
        model.scanDebounce = .milliseconds(40)
        let repo = Repository(path: "/repo")
        // SwiftUI restarts `.task(id:)` on every key change and cancels the previous
        // run: ten bumps in a burst must still cost one scan, not ten.
        var runs: [Task<Void, Never>] = []
        for revision in 0..<10 {
            runs.append(Task { await model.refresh(repo: repo, targetOverride: nil, enabled: true, revision: revision) })
        }
        for run in runs.dropLast() { run.cancel() }
        for run in runs { await run.value }
        #expect(await service.calls == 1)
        #expect(model.snapshot != nil)
        #expect(!model.isChecking)
    }

    private func makeModel(_ service: WorktreeCleanupChecking) -> WorktreeMergeModel {
        let model = WorktreeMergeModel(service: service)
        model.scanDebounce = .zero
        return model
    }
}
