import Foundation
import Observation
import TeebeCore

@MainActor
@Observable
final class WorktreeCleanupModel {
    let repo: Repository
    private let app: AppModel
    private let service: WorktreeCleanupChecking
    private var generation = UUID()
    private(set) var targetOverride: String
    private(set) var snapshot: CleanupSnapshot?
    private(set) var targets = CleanupTargets.parse("")
    private(set) var isChecking = false
    private(set) var isRemoving = false
    private(set) var errorMessage: String?
    private(set) var resultMessage: String?
    var selectedPaths: Set<String> = []
    var mergedOnly = false
    var includeIgnored = false {
        didSet {
            selectedPaths.removeAll()
            pendingRemoval = nil
        }
    }
    var pendingRemoval: RemovalPlan?

    struct RemovalPlan {
        let entries: [CleanupEntry]
        let target: CleanupBranch
        let includingIgnored: Bool
    }

    init(app: AppModel, repo: Repository, service: WorktreeCleanupChecking? = nil) {
        self.app = app
        self.repo = repo
        self.service = service ?? WorktreeCleanupService(git: app.environment.git)
        self.targetOverride = app.cleanupTarget(for: repo.path) ?? ""
    }

    var entries: [CleanupEntry] { snapshot?.entries ?? [] }
    var visibleEntries: [CleanupEntry] { entries.filter { !mergedOnly || $0.mergeStatus == .merged } }
    var eligibleEntries: [CleanupEntry] { entries.filter { blocker(for: $0) == nil } }
    var selectedEntries: [CleanupEntry] { eligibleEntries.filter { selectedPaths.contains($0.id) } }
    var automaticLabel: String { targets.automatic.map { "Auto (\($0.name))" } ?? "Auto (choose a branch)" }
    var isBusy: Bool { isChecking || isRemoving }

    private func protection(for entry: CleanupEntry) -> String? {
        if entry.worktree.isPrimary { return "Primary checkout" }
        if entry.id == app.selector.selectedWorktree?.path { return "Currently browsing" }
        if entry.isTarget { return "Comparison branch" }
        if entry.worktree.isLocked { return "Locked worktree" }
        if entry.worktree.isBare { return "Bare repository" }
        if entry.worktree.isDetached { return "Detached checkout" }
        return nil
    }

    func blocker(for entry: CleanupEntry) -> String? {
        if let reason = protection(for: entry) { return reason }
        if let problem = entry.problem { return problem }
        if entry.hasLocalChanges { return "Has local changes or untracked files" }
        if entry.hasSubmodules { return "Contains submodules" }
        if entry.hasUncheckedFiles { return "Some files are excluded from Git checks" }
        if entry.hasIgnoredFiles && !includeIgnored { return "Contains ignored files" }
        let info = app.selector.info(for: entry.worktree)
        if info.agentState == .working || info.isLive
            || app.environment.activityMonitor.isBusy(worktreePath: entry.id, within: 5, now: Date()) { return "Worktree is active" }
        if entry.mergeStatus != .merged { return "Merge not confirmed" }
        return nil
    }

    func selectEligible() {
        selectedPaths = Set(eligibleEntries.map(\.id))
    }

    func chooseTarget(_ ref: String) async {
        guard !isRemoving else { return }
        targetOverride = ref
        app.setCleanupTarget(ref.isEmpty ? nil : ref, for: repo.path)
        // A different comparison branch means different results — what was ticked
        // before it was not chosen against this target.
        selectedPaths.removeAll()
        await refresh()
    }

    /// Opening the sheet shows the scan the worktree rows already ran: same
    /// repository, same comparison branch, one scan. Recheck, Fetch & recheck and a
    /// target change are the only things that force a fresh one.
    func load() async {
        guard !isRemoving else { return }
        let override = targetOverride.isEmpty ? nil : targetOverride
        guard let shared = app.mergeStatus.cachedSnapshot(repoPath: repo.path, target: override) else {
            await refresh()
            return
        }
        snapshot = shared
        targets = shared.targets
    }

    func refresh(fetch: Bool = false) async {
        guard !isRemoving else { return }
        let token = UUID()
        generation = token
        let override = targetOverride.isEmpty ? nil : targetOverride
        // The previous results stay on screen while the new scan runs — blanking the
        // list on every recheck loses the user's place for no reason.
        pendingRemoval = nil
        errorMessage = nil
        isChecking = true
        do {
            if fetch { try await service.fetch(repoPath: repo.path) }
            try Task.checkCancellation()
            let result = try await service.scan(repoPath: repo.path, targetOverride: override)
            guard generation == token, !Task.isCancelled else { return }
            snapshot = result
            targets = result.targets
            // The rows need exactly this scan; hand it over so they don't repeat it.
            app.mergeStatus.adopt(result, repoPath: repo.path, target: override,
                                  revision: app.selector.mergeRevision)
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            // Results that could not be confirmed must not stay on screen as if they
            // had been: this is the one case that clears the list.
            snapshot = nil
            errorMessage = fetch ? "Couldn't fetch and recheck. Check your remote access, then try again."
                : "Couldn't check this repository. Its folder may have moved or become unavailable."
        }
        if generation == token { isChecking = false }
    }

    func cancel() {
        guard !isRemoving else { return }
        generation = UUID()
        isChecking = false
        pendingRemoval = nil
    }

    func requestRemoval() {
        guard !isBusy, let target = snapshot?.target, !selectedEntries.isEmpty else { return }
        pendingRemoval = RemovalPlan(entries: selectedEntries, target: target, includingIgnored: includeIgnored)
    }

    /// Capture the confirmed plan synchronously: SwiftUI clears the dialog's
    /// binding as soon as its button returns, before a newly scheduled Task runs.
    @discardableResult
    func confirmRemoval() -> Task<Void, Never>? {
        guard !isBusy, let plan = pendingRemoval else { return nil }
        pendingRemoval = nil
        isRemoving = true
        return Task { await remove(plan) }
    }

    private func remove(_ plan: RemovalPlan) async {
        var removed = 0
        var failures: [String] = []
        // Await each removal: cleanup writes never run concurrently.
        for entry in plan.entries {
            let scanAgent = app.environment.agentStatuses
            let states = await Task.detached { scanAgent([entry.id], Date()) }.value
            if blocker(for: entry) != nil || states[entry.id] == .working {
                failures.append("\(entry.worktree.branch ?? entry.worktree.name): now active or no longer eligible.")
                continue
            }
            do {
                try await service.remove(repoPath: repo.path, entry: entry, target: plan.target,
                                         includingIgnored: plan.includingIgnored)
                removed += 1
            } catch {
                let reason = (error as? CleanupError)?.errorDescription ?? "Git refused removal; the worktree was kept."
                failures.append("\(entry.worktree.branch ?? entry.worktree.name): \(reason)")
            }
        }
        if app.selector.selectedRepo?.path == repo.path {
            await app.selector.refreshWorktrees()
        }
        isRemoving = false
        selectedPaths.removeAll()
        await refresh()
        resultMessage = "Removed \(removed) \(removed == 1 ? "worktree" : "worktrees"). Branches were kept."
        if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
    }
}
