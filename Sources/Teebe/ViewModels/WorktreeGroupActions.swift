import Foundation
import Observation
import TeebeCore

/// The work behind the group-header actions and the row trash: removing merged
/// worktrees that are safe to remove (optionally deleting their local branches),
/// and pruning registrations whose folders are gone. Both end in a rescan, so the
/// list tells the truth again straight away.
@MainActor
@Observable
final class WorktreeGroupActions {
    /// Owned by `AppModel`, which outlives this.
    @ObservationIgnored private unowned let app: AppModel
    @ObservationIgnored private let service: WorktreeCleanupChecking
    /// A removal or prune is running: the actions stand down until it finishes.
    private(set) var isWorking = false

    init(app: AppModel, service: WorktreeCleanupChecking? = nil) {
        self.app = app
        self.service = service ?? WorktreeCleanupService(git: app.environment.git)
    }

    /// The merged rows that may actually be removed in bulk. Protection wins over
    /// merge state: the primary checkout, a merge target's own checkout, a locked,
    /// bare or detached worktree and the one being browsed all simply stay.
    func eligibleEntries(for worktrees: [Worktree]) -> [CleanupEntry] {
        let paths = Set(worktrees.map(\.path))
        return (app.mergeStatus.snapshot?.entries ?? []).filter {
            paths.contains($0.id) && $0.canRemove(includingIgnored: true) && isEligible($0, includingBrowsed: false)
        }
    }

    func confirmationTitle(_ entries: [CleanupEntry]) -> String {
        entries.count == 1 ? "Remove 1 worktree folder?" : "Remove \(entries.count) worktree folders?"
    }

    func confirmationMessage(_ entries: [CleanupEntry], deleteBranch: Bool) -> String {
        "The folders will be deleted from your Mac. "
            + (deleteBranch ? "Their local branches will be deleted too; remote branches are kept."
                : "Branches will be kept.")
    }

    /// Only worth saying when it is true: ignored files go with the folders.
    func confirmationFacts(_ entries: [CleanupEntry]) -> [WorktreeCardFact] {
        [WorktreeWording.ignoredFact(entries)].compactMap { $0 }
    }

    /// Remove the confirmed folders one at a time. A failure is reported and the
    /// rest still run: one worktree Git refuses must not strand the others. With
    /// `deleteBranch`, each local branch is deleted after its folder, only if it is
    /// still merged into an unchanged target. `includingBrowsed` lets a single
    /// explicitly chosen row be the one being browsed; bulk clean-up skips it.
    @discardableResult
    func remove(_ entries: [CleanupEntry], deleteBranch: Bool, includingBrowsed: Bool = false) -> Task<Void, Never>? {
        guard !isWorking, !entries.isEmpty, let repo = app.selector.selectedRepo else { return nil }
        isWorking = true
        return Task { await performRemoval(entries, repo: repo, deleteBranch: deleteBranch, includingBrowsed: includingBrowsed) }
    }

    /// The row trash: remove a merged row, or prune when the row is missing.
    @discardableResult
    func perform(_ action: WorktreeStatus.TrashAction, deleteBranch: Bool) -> Task<Void, Never>? {
        switch action {
        case .remove(let entry): return remove([entry], deleteBranch: deleteBranch, includingBrowsed: true)
        case .prune: return prune()
        }
    }

    @discardableResult
    func prune() -> Task<Void, Never>? {
        guard !isWorking, let repo = app.selector.selectedRepo else { return nil }
        isWorking = true
        return Task {
            do {
                try await app.environment.git.pruneWorktrees(repoPath: repo.path)
            } catch {
                app.setError("Couldn't prune worktrees: \(WorktreeModel.describe(error))")
            }
            isWorking = false
            await rescan(repo)
        }
    }

    private func performRemoval(_ entries: [CleanupEntry], repo: Repository, deleteBranch: Bool, includingBrowsed: Bool) async {
        // Await each removal: cleanup writes never run concurrently.
        for entry in entries {
            let scanAgent = app.environment.agentStatuses
            let states = await Task.detached { scanAgent([entry.id], Date()) }.value
            guard isEligible(entry, includingBrowsed: includingBrowsed), !isActive(entry), states[entry.id] != .working else {
                app.setError("Couldn't remove \(name(entry)): it is in use.")
                continue
            }
            do {
                let branch = try await service.remove(repoPath: repo.path, entry: entry,
                                                      includingIgnored: true, deleteBranch: deleteBranch)
                if branch == .kept {
                    app.setError("Removed \(name(entry)), but kept its branch: it changed or Git refused to delete it.")
                }
            } catch {
                let reason = (error as? CleanupError)?.errorDescription ?? "Git refused removal; the worktree was kept."
                app.setError("Couldn't remove \(name(entry)): \(reason)")
            }
        }
        isWorking = false
        await rescan(repo)
    }

    /// Re-discover the worktrees and check them again, so the groups and their
    /// counts reflect what is on disk rather than what was there before.
    private func rescan(_ repo: Repository) async {
        guard app.selector.selectedRepo?.path == repo.path else { return }
        await app.selector.refreshWorktrees()
        await app.mergeStatus.refresh(repo: repo, extraTarget: app.extraMergeTarget(for: repo.path),
                                      enabled: true, revision: app.selector.mergeRevision)
    }

    private func isEligible(_ entry: CleanupEntry, includingBrowsed: Bool) -> Bool {
        !entry.worktree.isPrimary && !entry.isTarget && !entry.worktree.isLocked
            && !entry.worktree.isBare && !entry.worktree.isDetached
            && (includingBrowsed || entry.id != app.selector.selectedWorktree?.path)
    }

    /// Something is writing to the folder right now. Read fresh, immediately before
    /// the removal, never from the scan that produced the row.
    private func isActive(_ entry: CleanupEntry) -> Bool {
        let info = app.selector.info(for: entry.worktree)
        return info.agentState == .working || info.isLive
            || app.environment.activityMonitor.isBusy(worktreePath: entry.id, within: 5, now: Date())
    }

    private func name(_ entry: CleanupEntry) -> String {
        entry.worktree.branch ?? entry.worktree.name
    }
}
