import Foundation
import Observation
import TeebeCore

/// The work behind the two group-header actions: removing the merged worktrees
/// that are safe to remove, and pruning registrations whose folders are gone.
/// Both end in a rescan, so the list tells the truth again straight away.
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

    /// The merged rows that may actually be removed. Protection wins over merge
    /// state: the primary checkout, the comparison branch's own checkout, a locked,
    /// bare or detached worktree and the one being browsed all simply stay.
    func eligibleEntries(for worktrees: [Worktree]) -> [CleanupEntry] {
        let paths = Set(worktrees.map(\.path))
        return (app.mergeStatus.snapshot?.entries ?? []).filter { paths.contains($0.id) && isEligible($0) }
    }

    func confirmationTitle(_ entries: [CleanupEntry]) -> String {
        entries.count == 1 ? "Remove 1 worktree folder?" : "Remove \(entries.count) worktree folders?"
    }

    func confirmationMessage(_ entries: [CleanupEntry]) -> String {
        var text = "The folders will be deleted from your Mac. Branches will be kept."
        // Only worth saying when it is true: ignored files go with the folder.
        if entries.contains(where: \.hasIgnoredFiles) {
            text += " Ignored files such as build output will be deleted too."
        }
        return text
    }

    /// Remove the confirmed folders one at a time. A failure is reported and the
    /// rest still run: one worktree Git refuses must not strand the others.
    @discardableResult
    func remove(_ entries: [CleanupEntry]) -> Task<Void, Never>? {
        guard !isWorking, !entries.isEmpty,
              let repo = app.selector.selectedRepo,
              let target = app.mergeStatus.snapshot?.target else { return nil }
        isWorking = true
        return Task { await performRemoval(entries, repo: repo, target: target) }
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

    private func performRemoval(_ entries: [CleanupEntry], repo: Repository, target: CleanupBranch) async {
        // Await each removal: cleanup writes never run concurrently.
        for entry in entries {
            let scanAgent = app.environment.agentStatuses
            let states = await Task.detached { scanAgent([entry.id], Date()) }.value
            guard isEligible(entry), !isActive(entry), states[entry.id] != .working else {
                app.setError("Couldn't remove \(name(entry)): it is in use.")
                continue
            }
            do {
                try await service.remove(repoPath: repo.path, entry: entry, target: target, includingIgnored: true)
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
        await app.mergeStatus.refresh(repo: repo, targetOverride: app.cleanupTarget(for: repo.path),
                                      enabled: app.showMergeStatus, revision: app.selector.mergeRevision)
    }

    private func isEligible(_ entry: CleanupEntry) -> Bool {
        !entry.worktree.isPrimary && !entry.isTarget && !entry.worktree.isLocked
            && !entry.worktree.isBare && !entry.worktree.isDetached
            && entry.id != app.selector.selectedWorktree?.path
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
