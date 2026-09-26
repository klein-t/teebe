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
    func scan(repoPath: String, extraTarget: String?) async throws -> CleanupSnapshot {
        calls += 1
        requestedTarget = extraTarget
        if let gate { self.gate = nil; await gate.wait() }
        if fails { throw CleanupError.gitFailed }
        let targets = CleanupTargets.parse("refs/heads/dev\u{0}abc\u{0}\u{0}\nrefs/heads/main\u{0}def\u{0}\u{0}\n")
        var entry = CleanupEntry(worktree: Worktree(path: repoPath + "/feature", branch: "feature"))
        entry.mergeStatus = .merged
        return CleanupSnapshot(targets: targets, mergeTargets: targets.mergeTargets(extra: extraTarget), entries: [entry])
    }
    func remove(repoPath: String, entry: CleanupEntry, includingIgnored: Bool, deleteBranch: Bool) -> BranchDeletion {
        Issue.record("Row indicators must never remove a worktree")
        return .notRequested
    }
}

/// Two worktrees. `/repo/other` is merged only while `dev` is where it started,
/// so a moved target shows up in every row. Each scan is stamped with its call
/// number (as `problem`), and any call can be held open.
private actor ScriptedScan: WorktreeCleanupChecking {
    private(set) var calls = 0
    private var devSHA = "abc"
    private var dirtyFeature = false
    private var gates: [Int: Gate] = [:]
    func moveDev(to sha: String) { devSHA = sha }
    func setFeatureDirty(_ dirty: Bool) { dirtyFeature = dirty }
    func hold(call: Int, _ gate: Gate) { gates[call] = gate }
    func scan(repoPath: String, extraTarget: String?) async throws -> CleanupSnapshot {
        calls += 1
        let call = calls
        // A real scan reads the refs first, then inspects the checkouts.
        let dev = devSHA
        let dirty = dirtyFeature
        if let gate = gates[call] { await gate.wait() }
        let targets = CleanupTargets.parse("refs/heads/dev\u{0}\(dev)\u{0}\u{0}\n")
        var feature = CleanupEntry(worktree: Worktree(path: repoPath + "/feature", branch: "feature"))
        feature.mergeStatus = .merged
        feature.hasLocalChanges = dirty
        feature.problem = "scan \(call)"
        var other = CleanupEntry(worktree: Worktree(path: repoPath + "/other", branch: "other"))
        other.mergeStatus = dev == "abc" ? .merged : .notConfirmed
        other.problem = "scan \(call)"
        return CleanupSnapshot(targets: targets, mergeTargets: targets.mergeTargets(extra: extraTarget),
                               entries: [feature, other])
    }
    func remove(repoPath: String, entry: CleanupEntry, includingIgnored: Bool, deleteBranch: Bool) -> BranchDeletion {
        Issue.record("Row indicators must never remove a worktree")
        return .notRequested
    }
}

@MainActor
@Suite("Worktree merge indicators")
struct WorktreeMergeModelTests {
    @Test("disabled indicators skip scanning and clear previous results")
    func visibility() async {
        let service = MergeScanStub()
        let model = makeModel(service)
        await model.refresh(repo: Repository(path: "/repo"), extraTarget: "refs/heads/dev", enabled: false)
        #expect(await service.calls == 0)
        await model.refresh(repo: Repository(path: "/repo"), extraTarget: "refs/heads/dev", enabled: true)
        #expect(model.entry(for: "/repo/feature")?.entry.mergeStatus == .merged)
        #expect(await service.requestedTarget == "refs/heads/dev")
        await model.refresh(repo: Repository(path: "/repo"), extraTarget: nil, enabled: false)
        #expect(model.snapshot == nil)
        #expect(await service.calls == 1)
    }

    @Test("a late scan cannot replace the newly selected project")
    func staleScan() async {
        let service = MergeScanStub()
        let gate = Gate()
        await service.hold(gate)
        let model = makeModel(service)
        let first = Task { await model.refresh(repo: Repository(path: "/old"), extraTarget: nil, enabled: true) }
        while await service.calls == 0 { await Task.yield() }
        await model.refresh(repo: Repository(path: "/new"), extraTarget: "refs/heads/dev", enabled: true)
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
        let first = Task { await model.refresh(repo: Repository(path: "/repo"), extraTarget: nil, enabled: true) }
        while await service.calls == 0 { await Task.yield() }
        await model.refresh(repo: Repository(path: "/repo"), extraTarget: nil, enabled: false)
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
            await model.refresh(repo: Repository(path: "/repo"), extraTarget: nil, enabled: true, revision: 1)
        }
        #expect(await service.calls == 1)
        #expect(model.snapshot != nil)
    }

    @Test("background refresh retains visible results but a failed check clears them")
    func backgroundRefresh() async {
        let service = MergeScanStub()
        let model = makeModel(service)
        await model.refresh(repo: Repository(path: "/repo"), extraTarget: nil, enabled: true, revision: 1)
        let gate = Gate()
        await service.hold(gate)
        let refresh = Task {
            await model.refresh(repo: Repository(path: "/repo"), extraTarget: nil, enabled: true, revision: 2)
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
        await model.refresh(repo: Repository(path: "/one"), extraTarget: nil, enabled: true)
        await model.refresh(repo: Repository(path: "/two"), extraTarget: nil, enabled: true)
        let gate = Gate()
        await service.hold(gate)
        let refresh = Task { await model.refresh(repo: Repository(path: "/one"), extraTarget: nil, enabled: true) }
        while await service.calls < 3 { await Task.yield() }
        #expect(model.entry(for: "/one/feature") != nil)
        #expect(model.entry(for: "/two/feature") == nil)
        await gate.open()
        await refresh.value
    }

    @Test("switching the extra target cannot show a late result for the previous one")
    func targetSwitch() async {
        let service = MergeScanStub()
        let gate = Gate()
        await service.hold(gate)
        let model = makeModel(service)
        let repo = Repository(path: "/repo")
        let old = Task { await model.refresh(repo: repo, extraTarget: "refs/heads/main", enabled: true) }
        while await service.calls == 0 { await Task.yield() }
        await model.refresh(repo: repo, extraTarget: "refs/heads/release", enabled: true)
        await gate.open()
        await old.value
        #expect(await service.requestedTarget == "refs/heads/release")
        #expect(!model.isChecking)
    }

    @Test("a rescan of the same repository keeps showing the last result until the new one lands")
    func staleWhileRevalidate() async {
        let service = MergeScanStub()
        let model = makeModel(service)
        let repo = Repository(path: "/repo")
        await model.refresh(repo: repo, extraTarget: nil, enabled: true, revision: 1)
        let gate = Gate()
        await service.hold(gate)
        // A new extra target has no cached result: the ✓ must stay while it is checked.
        let refresh = Task { await model.refresh(repo: repo, extraTarget: "refs/heads/main", enabled: true, revision: 2) }
        while await service.calls < 2 { await Task.yield() }
        #expect(model.isChecking)
        #expect(model.entry(for: "/repo/feature")?.entry.mergeStatus == .merged)
        await gate.open()
        await refresh.value
        #expect(model.entry(for: "/repo/feature")?.entry.mergeStatus == .merged)
        // Another repository never inherits this one's rows.
        let otherGate = Gate()
        await service.hold(otherGate)
        let other = Task { await model.refresh(repo: Repository(path: "/other"), extraTarget: nil, enabled: true) }
        while await service.calls < 3 { await Task.yield() }
        #expect(model.snapshot == nil)
        await otherGate.open()
        await other.value
    }

    @Test("active file status updates one row without scanning or masking new commits")
    func localOverlay() async {
        let service = MergeScanStub()
        let model = makeModel(service)
        await model.refresh(repo: Repository(path: "/repo"), extraTarget: nil, enabled: true)
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
        await model.refresh(repo: Repository(path: "/repo"), extraTarget: nil, enabled: true)
        let settled = model.entry(for: "/repo/feature")
        #expect(group(settled) == .merged)

        // The user commits in the worktree they are browsing: HEAD moves ahead of
        // the scan. The row must not fall into the catch-all group and bounce back.
        let committed = model.entry(for: "/repo/feature", localStatus: StatusResult(oid: "new-head"))
        #expect(committed?.isRechecking == true)
        #expect(committed?.entry.mergeStatus == .merged)
        #expect(group(committed) == .merged)
        // Known to be stale: the ring while it is rechecked, never a ✓ to act on.
        #expect(mark(committed) == .notMerged)

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
            runs.append(Task { await model.refresh(repo: repo, extraTarget: nil, enabled: true, revision: revision) })
        }
        for run in runs.dropLast() { run.cancel() }
        for run in runs { await run.value }
        #expect(await service.calls == 1)
        #expect(model.snapshot != nil)
        #expect(!model.isChecking)
    }

    @Test("a row recheck during a full refresh neither discards it nor leaves it checking")
    func recheckDuringRefresh() async {
        let service = ScriptedScan()
        let model = makeModel(service)
        let repo = Repository(path: "/repo")
        await model.refresh(repo: repo, extraTarget: nil, enabled: true, revision: 1)
        let gate = Gate()
        await service.hold(call: 2, gate)
        await service.moveDev(to: "moved")
        let refresh = Task { await model.refresh(repo: repo, extraTarget: nil, enabled: true, revision: 2) }
        while await service.calls < 2 { await Task.yield() }
        // The user commits while the refresh is scanning.
        let recheck = Task { await model.recheck(path: "/repo/feature") }
        for _ in 0..<20 { await Task.yield() }
        #expect(model.entry(for: "/repo/feature")?.isRechecking == true)
        await gate.open()
        await refresh.value
        await recheck.value
        #expect(!model.isChecking)
        // The refresh's result landed: the moved target and the row it changed.
        #expect(model.snapshot?.mergeTargets.first?.sha == "moved")
        #expect(model.entry(for: "/repo/other")?.entry.mergeStatus == .notConfirmed)
        // The commit came after the refresh began scanning, so the row is checked
        // once more, after it, and nothing is left marked as rechecking.
        #expect(await service.calls == 3)
        #expect(model.entry(for: "/repo/feature")?.entry.problem == "scan 3")
        #expect(model.entry(for: "/repo/feature")?.isRechecking == false)
    }

    @Test("a recheck asked for before a refresh scans is answered by that refresh, not a second scan")
    func recheckCoveredByRefresh() async {
        let service = ScriptedScan()
        let model = makeModel(service)
        let repo = Repository(path: "/repo")
        await model.refresh(repo: repo, extraTarget: nil, enabled: true, revision: 1)
        model.scanDebounce = .milliseconds(150)
        let gate = Gate()
        await service.hold(call: 2, gate)
        await service.moveDev(to: "moved")
        let refresh = Task { await model.refresh(repo: repo, extraTarget: nil, enabled: true, revision: 2) }
        let recheck = Task { await model.recheck(path: "/repo/feature") }
        while await service.calls < 2 { await Task.yield() }
        await gate.open()
        await refresh.value
        await recheck.value
        #expect(await service.calls == 2)
        // The refresh's whole result landed, not just the rechecked row.
        #expect(model.entry(for: "/repo/other")?.entry.mergeStatus == .notConfirmed)
        #expect(model.entry(for: "/repo/feature")?.isRechecking == false)
        #expect(!model.isChecking)
    }

    @Test("a recheck that finds a merge target moved shows the whole result")
    func recheckWithMovedTarget() async {
        let service = ScriptedScan()
        let model = makeModel(service)
        await model.refresh(repo: Repository(path: "/repo"), extraTarget: nil, enabled: true, revision: 1)
        #expect(model.entry(for: "/repo/other")?.entry.mergeStatus == .merged)
        // A commit on dev in its own worktree: the row rechecked is not the only one
        // whose result the move changed.
        await service.moveDev(to: "moved")
        await model.recheck(path: "/repo/feature")
        #expect(model.snapshot?.mergeTargets.first?.sha == "moved")
        #expect(model.snapshot?.targets.branch("refs/heads/dev")?.sha == "moved")
        #expect(model.entry(for: "/repo/other")?.entry.mergeStatus == .notConfirmed)
    }

    @Test("a recheck with the targets unchanged replaces only its own row")
    func recheckKeepsOtherRows() async {
        let service = ScriptedScan()
        let model = makeModel(service)
        await model.refresh(repo: Repository(path: "/repo"), extraTarget: nil, enabled: true, revision: 1)
        await model.recheck(path: "/repo/feature")
        #expect(model.entry(for: "/repo/feature")?.entry.problem == "scan 2")
        #expect(model.entry(for: "/repo/other")?.entry.problem == "scan 1")
    }

    @Test("a refresh that starts while a recheck is scanning wins, and nothing is left checking")
    func refreshDuringRecheck() async {
        let service = ScriptedScan()
        let model = makeModel(service)
        let repo = Repository(path: "/repo")
        await model.refresh(repo: repo, extraTarget: nil, enabled: true, revision: 1)
        let gate = Gate()
        await service.hold(call: 2, gate)
        let recheck = Task { await model.recheck(path: "/repo/feature") }
        while await service.calls < 2 { await Task.yield() }
        await model.refresh(repo: repo, extraTarget: nil, enabled: true, revision: 2)
        #expect(model.entry(for: "/repo/feature")?.entry.problem == "scan 3")
        await gate.open()
        await recheck.value
        // The recheck's scan is older than the refresh's, so it must not land.
        #expect(model.entry(for: "/repo/feature")?.entry.problem == "scan 3")
        #expect(model.entry(for: "/repo/feature")?.isRechecking == false)
        #expect(!model.isChecking)
    }

    @Test("any row's status read overlays its scan: clean clears changes, unknown keeps them")
    func statusOverlayForEveryRow() async {
        let service = ScriptedScan()
        await service.setFeatureDirty(true)
        let model = makeModel(service)
        await model.refresh(repo: Repository(path: "/repo"), extraTarget: nil, enabled: true)
        #expect(model.entry(for: "/repo/feature", localChangeCount: nil)?.entry.hasLocalChanges == true)
        let clean = model.entry(for: "/repo/feature", localChangeCount: 0)
        #expect(clean?.entry.hasLocalChanges == false)
        #expect(group(clean) == .merged)
        #expect(model.entry(for: "/repo/other", localChangeCount: 2)?.entry.hasLocalChanges == true)
    }

    @Test("discarding changes in a worktree that is not open clears its uncommitted state")
    func discardInUnselectedWorktree() async {
        let git = FakeGitClient()
        git.worktreesResult = [Worktree(path: "/repo", branch: "main", isPrimary: true),
                               Worktree(path: "/repo/feature", branch: "feature")]
        git.statusResult = StatusParser.parse("? new.txt\u{0}")
        let service = ScriptedScan()
        await service.setFeatureDirty(true)
        let app = AppModel(environment: makeTestEnvironment(git: git), mergeService: service)
        app.mergeStatus.scanDebounce = .zero
        _ = await app.addRepository(path: "/repo")
        await app.mergeStatus.refresh(repo: app.selector.selectedRepo, extraTarget: nil, enabled: true)
        let feature = Worktree(path: "/repo/feature", branch: "feature")
        #expect(app.selector.selectedWorktree?.path == "/repo")
        #expect(app.worktreeStatus(for: feature).group == .localChanges)

        // Changes discarded from a terminal: the files change, status reads clean.
        git.statusResult = StatusResult()
        await app.selector.handleWorktreeFileEvents(["/repo/feature/new.txt"])
        #expect(app.selector.info(for: feature).changeCount == 0)
        #expect(app.worktreeStatus(for: feature).group == .merged)
    }

    private func status(_ merge: WorktreeMergeEntry?) -> WorktreeStatus {
        WorktreeStatus(worktree: Worktree(path: "/repo/feature", branch: "feature"), merge: merge, info: .init(),
                       targetNames: ["dev"], isChecking: true)
    }
    private func group(_ merge: WorktreeMergeEntry?) -> WorktreeGroup { status(merge).group }
    private func mark(_ merge: WorktreeMergeEntry?) -> WorktreeMark { status(merge).mark }

    private func makeModel(_ service: WorktreeCleanupChecking) -> WorktreeMergeModel {
        let model = WorktreeMergeModel(service: service)
        model.scanDebounce = .zero
        return model
    }
}
