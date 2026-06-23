import Foundation
import Observation
import TreebranchCore

/// Drives the `Repo ▾ · Worktree ▾ · Branch ▾` selectors. Switching a selector
/// repopulates downstream state and the worktree view. Branch selection defaults
/// to read-only snapshot browse (D2).
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
    /// Branch chosen for read-only browse (nil = viewing the worktree's own branch).
    private(set) var browseBranch: Branch?
    /// Sync/activity info keyed by worktree path.
    private(set) var worktreeInfo: [String: WorktreeInfo] = [:]
    var errorMessage: String?

    let worktree: WorktreeModel

    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
        self.worktree = WorktreeModel(environment: environment)
    }

    func setRepositories(_ repos: [Repository]) {
        repositories = repos
    }

    func clearSelection() {
        selectedRepo = nil
        worktrees = []
        selectedWorktree = nil
        branches = []
        browseBranch = nil
        worktree.clear()
    }

    /// Select a repo: discover its worktrees + branches, then focus the primary
    /// worktree.
    func selectRepo(_ repo: Repository) async {
        selectedRepo = repo
        browseBranch = nil
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
        browseBranch = nil
        await worktree.load(worktreePath: wt.path, repo: selectedRepo)
    }

    /// Browse another branch read-only (snapshot), without checkout (D2).
    func browse(branch: Branch) async {
        browseBranch = branch
        guard let repo = selectedRepo else { return }
        await worktree.loadSnapshot(repo: repo, ref: branch.name)
    }

    /// Return to viewing the worktree's own working tree.
    func stopBrowsing() async {
        browseBranch = nil
        if let wt = selectedWorktree {
            await worktree.load(worktreePath: wt.path, repo: selectedRepo)
        }
    }
}
