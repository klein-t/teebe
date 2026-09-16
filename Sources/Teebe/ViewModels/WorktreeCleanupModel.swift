import Foundation
import Observation
import TeebeCore

/// Why a worktree cannot be removed. A value, not a sentence: the view used to
/// compare against the English text, so rewording a label silently broke the rows.
enum CleanupBlocker: Equatable {
    case primaryCheckout, currentlyBrowsing, comparisonBranch, locked, bare, detached
    case problem(String)
    case localChanges, submodules, uncheckedFiles, ignoredFiles, active, notMerged

    /// The badge on the row. Shares the worktree-group vocabulary wherever the
    /// state is the same one.
    var shortLabel: String {
        switch self {
        case .primaryCheckout: "Primary checkout"
        case .currentlyBrowsing: "Currently browsing"
        case .comparisonBranch: "Comparison branch"
        case .locked: "Locked"
        case .bare: "Bare repository"
        case .detached: "Detached checkout"
        case .problem: WorktreeGroup.broken.title
        case .localChanges: WorktreeGroup.localChanges.title
        case .submodules, .uncheckedFiles: WorktreeGroup.notChecked.title
        case .ignoredFiles: "Ignored files"
        case .active: "Active"
        case .notMerged: WorktreeGroup.notMerged.title
        }
    }

    /// The sentence behind the badge, for the row's tooltip.
    var detail: String {
        switch self {
        case .primaryCheckout: "The repository's primary checkout is never removed."
        case .currentlyBrowsing: "This is the worktree you have open."
        case .comparisonBranch: "This is the branch everything else is compared against."
        case .locked: "The worktree is locked in Git."
        case .bare: "A bare repository has no working files to remove."
        case .detached: "The checkout is not on a branch."
        case .problem(let problem): problem
        case .localChanges: "Uncommitted changes in this folder."
        case .submodules: "Contains a submodule."
        case .uncheckedFiles: "Some files are marked unchanged in Git."
        case .ignoredFiles: "Ignored files remain. Include them from the options menu to remove anyway."
        case .active: "Something is writing to this worktree right now."
        case .notMerged: "Commits not found in the comparison branch."
        }
    }
}

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
    /// Folders already gone in the current removal pass, so the list can mark each row
    /// as it completes instead of blanking itself behind a spinner.
    private(set) var removedPaths: Set<String> = []
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
    /// One name for the automatic choice, everywhere, with the branch it resolved to.
    var automaticLabel: String { targets.automatic.map { "Automatic (\($0.name))" } ?? "Automatic" }
    var isBusy: Bool { isChecking || isRemoving }

    private func protection(for entry: CleanupEntry) -> CleanupBlocker? {
        if entry.worktree.isPrimary { return .primaryCheckout }
        if entry.id == app.selector.selectedWorktree?.path { return .currentlyBrowsing }
        if entry.isTarget { return .comparisonBranch }
        if entry.worktree.isLocked { return .locked }
        if entry.worktree.isBare { return .bare }
        if entry.worktree.isDetached { return .detached }
        return nil
    }

    func blocker(for entry: CleanupEntry) -> CleanupBlocker? {
        if let reason = protection(for: entry) { return reason }
        if let problem = entry.problem { return .problem(problem) }
        if entry.hasLocalChanges { return .localChanges }
        if entry.hasSubmodules { return .submodules }
        if entry.hasUncheckedFiles { return .uncheckedFiles }
        if entry.hasIgnoredFiles && !includeIgnored { return .ignoredFiles }
        let info = app.selector.info(for: entry.worktree)
        if info.agentState == .working || info.isLive
            || app.environment.activityMonitor.isBusy(worktreePath: entry.id, within: 5, now: Date()) { return .active }
        if entry.mergeStatus != .merged { return .notMerged }
        return nil
    }

    func selectEligible() {
        selectedPaths = Set(eligibleEntries.map(\.id))
    }

    /// Every removable row is ticked, so the control can offer the opposite action —
    /// rather than flipping to "Clear selection" the moment one box is ticked.
    var allEligibleSelected: Bool {
        let eligible = Set(eligibleEntries.map(\.id))
        return !eligible.isEmpty && selectedPaths == eligible
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
        removedPaths = []
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
                failures.append("\(entry.worktree.branch ?? entry.worktree.name) is now in use.")
                continue
            }
            do {
                try await service.remove(repoPath: repo.path, entry: entry, target: plan.target,
                                         includingIgnored: plan.includingIgnored)
                removed += 1
                removedPaths.insert(entry.id)
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
