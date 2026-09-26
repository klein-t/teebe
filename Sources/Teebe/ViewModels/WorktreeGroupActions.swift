import Foundation
import Observation
import TeebeCore

/// The work behind the group-header actions, the row trash and "Remove
/// Worktree…": removing worktree folders (optionally deleting the local branches
/// of merged ones), and pruning registrations whose folders are gone. Every
/// removal runs through `perform` / `remove`, which re-check it in full as it
/// runs. Both end in a rescan, so the list tells the truth again straight away.
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

    /// The rows that may actually be removed in bulk: exactly those whose own
    /// trash is showing, so protection, agent activity and a stale result all keep
    /// a row out, and the one being browsed stays too.
    func eligibleEntries(for worktrees: [Worktree]) -> [CleanupEntry] {
        worktrees.compactMap { worktree in
            guard case .remove(let entry)? = app.worktreeStatus(for: worktree).trashAction,
                  !isBrowsed(worktree.path) else { return nil }
            return entry
        }
    }

    /// For the clean-up sheet: each of these rows it leaves alone, and why.
    func skippedFacts(for worktrees: [Worktree]) -> [WorktreeCardFact] {
        worktrees.compactMap { worktree in
            let status = app.worktreeStatus(for: worktree)
            let reason: String
            if status.showsTrash {
                guard isBrowsed(worktree.path) else { return nil }
                reason = "it’s the worktree you’re viewing"
            } else if let activity = status.activityWarning {
                reason = activity.prefix(1).lowercased() + activity.dropFirst()
            } else if status.isRechecking {
                reason = "it is still being checked"
            } else {
                reason = "it isn’t safe to delete right now"
            }
            return WorktreeCardFact(icon: .warning, text: "“\(worktree.branch ?? worktree.name)” is skipped: " + reason,
                                    tone: .muted)
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
        guard !entries.isEmpty, let repo = app.selector.selectedRepo else { return nil }
        guard !isWorking else {
            app.setError("Couldn't remove \(entries.count == 1 ? name(entries[0]) : "worktrees"): another removal is still running.")
            return nil
        }
        isWorking = true
        return Task { await performRemoval(entries, repo: repo, deleteBranch: deleteBranch, includingBrowsed: includingBrowsed) }
    }

    /// The row trash and "Remove Worktree…": remove the folder the sheet opened
    /// on, or prune when the row is missing.
    @discardableResult
    func perform(_ action: WorktreeStatus.TrashAction, deleteBranch: Bool) -> Task<Void, Never>? {
        switch action {
        case .remove(let entry): return remove([entry], deleteBranch: deleteBranch, includingBrowsed: true)
        case .prune: return prune()
        }
    }

    @discardableResult
    func prune() -> Task<Void, Never>? {
        guard let repo = app.selector.selectedRepo else { return nil }
        guard !isWorking else {
            app.setError("Couldn't forget missing worktrees: a removal is still running.")
            return nil
        }
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
            if let reason = await refusal(entry, includingBrowsed: includingBrowsed) {
                app.setError("Couldn't remove \(name(entry)): \(reason)")
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

    private func isBrowsed(_ path: String) -> Bool { path == app.selector.selectedWorktree?.path }

    /// Why `entry` can't be removed right now; nil when nothing stands in the way.
    /// Read fresh, immediately before the removal, never from the scan or the
    /// sheet that produced it: an agent working or waiting there (every harness),
    /// anything open in the folder, or files changed or a command run within the
    /// window the working orb uses. What Git knows (the commit, targets, local and
    /// hidden work, protection) the cleanup service re-checks itself.
    private func refusal(_ entry: CleanupEntry, includingBrowsed: Bool) async -> String? {
        if !includingBrowsed, isBrowsed(entry.id) { return "it’s the worktree you’re viewing." }
        var paths = app.selector.worktrees.map(\.path)
        if !paths.contains(entry.id) { paths.append(entry.id) }
        let now = Date()
        let agentStatuses = app.environment.agentStatuses
        let worktreesInUse = app.environment.worktreesInUse
        let (states, inUse) = await Task.detached { [paths] in (agentStatuses(paths, now), worktreesInUse(paths, now)) }.value
        switch states[entry.id] {
        case .working?: return "an agent is working in it."
        case .needsAttention?: return "an agent is waiting for you in it."
        case .idle?, nil: break
        }
        if inUse.contains(entry.id) { return "it is open in a terminal, editor or agent." }
        if app.environment.activityMonitor.isBusy(worktreePath: entry.id, within: GenericActivity.window, now: now) {
            return "files are changing or a command is running in it."
        }
        return nil
    }

    private func name(_ entry: CleanupEntry) -> String {
        entry.worktree.branch ?? entry.worktree.name
    }
}
