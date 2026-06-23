import Foundation
import Observation
import TeebeCore

/// Drives the `Repo ▾ · Worktree ▾` selectors. Switching a selector repopulates
/// downstream state and the worktree view.
@MainActor
@Observable
final class SelectorModel {
    /// Per-worktree sync/activity summary for the WORKTREES list.
    struct WorktreeInfo: Equatable {
        var ahead: Int = 0
        var behind: Int = 0
        var changeCount: Int = 0
        var isLive: Bool = false
    }

    private(set) var repositories: [Repository] = []
    private(set) var selectedRepo: Repository?
    private(set) var worktrees: [Worktree] = []
    private(set) var selectedWorktree: Worktree?
    private(set) var branches: [Branch] = []
    /// Sync/activity info keyed by worktree path.
    private(set) var worktreeInfo: [String: WorktreeInfo] = [:]
    var errorMessage: String?

    let worktree: WorktreeModel

    /// Invoked whenever the selected repo/worktree changes, so the owner can persist
    /// the new selection (drives "reopen where I left off").
    var onSelectionChange: (() -> Void)?

    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
        self.worktree = WorktreeModel(environment: environment)
        // An external write to the active worktree should re-light its live dot
        // immediately, without waiting for a manual refresh.
        self.worktree.onActivity = { [weak self] _ in self?.refreshLiveState() }
    }

    /// Recompute only the cheap `isLive` flags from the activity monitor (no git),
    /// e.g. after a file-watch event reports external activity.
    func refreshLiveState(now: Date = Date()) {
        for wt in worktrees {
            var info = worktreeInfo[wt.path] ?? WorktreeInfo()
            info.isLive = environment.activityMonitor.isBusy(worktreePath: wt.path, within: 5, now: now)
            worktreeInfo[wt.path] = info
        }
    }

    func setRepositories(_ repos: [Repository]) {
        repositories = repos
    }

    func clearSelection() {
        selectedRepo = nil
        worktrees = []
        selectedWorktree = nil
        branches = []
        worktree.clear()
        onSelectionChange?()
    }

    /// Select a repo: discover its worktrees + branches, then focus the primary
    /// worktree.
    func selectRepo(_ repo: Repository) async {
        selectedRepo = repo
        do {
            worktrees = try await environment.worktreeService.worktrees(for: repo)
            branches = try await environment.branchService.branches(for: repo)
            errorMessage = nil
        } catch {
            worktrees = []
            branches = []
            errorMessage = "\(error)"
        }
        await refreshWorktreeInfo()
        if let primary = worktrees.first(where: { $0.isPrimary }) ?? worktrees.first {
            await selectWorktree(primary)
        }
        onSelectionChange?()
    }

    /// Load per-worktree ahead/behind + change count + live state for the
    /// WORKTREES list (drives the sync arrows and pulse dot).
    func refreshWorktreeInfo(now: Date = Date()) async {
        var info: [String: WorktreeInfo] = [:]
        for worktree in worktrees {
            let status = try? await environment.statusService.status(worktreePath: worktree.path)
            let live = environment.activityMonitor.isBusy(worktreePath: worktree.path, within: 5, now: now)
            info[worktree.path] = WorktreeInfo(
                ahead: status?.ahead ?? 0,
                behind: status?.behind ?? 0,
                changeCount: status?.changes.count ?? 0,
                isLive: live
            )
        }
        worktreeInfo = info
    }

    func info(for worktree: Worktree) -> WorktreeInfo {
        worktreeInfo[worktree.path] ?? WorktreeInfo()
    }

    func selectWorktree(_ wt: Worktree) async {
        selectedWorktree = wt
        await worktree.load(worktreePath: wt.path, repo: selectedRepo)
        onSelectionChange?()
    }
}
