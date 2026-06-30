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
    /// Watches the selected repo's git dir so an external `git worktree add`/`remove`
    /// shows up without a manual refresh.
    private var repoWatcher: FileSystemWatcher?
    /// Coalescing flags for watcher-driven re-scans (mirrors `WorktreeModel`): a burst
    /// of `.git/worktrees` events collapses into at most one queued follow-up.
    private var isRescanning = false
    private var rescanQueued = false
    /// Absolute path to the repo's `worktrees` admin dir (inside the git *common*
    /// dir), used to filter watcher events. Resolved via `git rev-parse` so it's
    /// correct even when `<repo>/.git` is a gitlink file rather than a directory.
    private var worktreesAdminDir: String?

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
        repoWatcher?.stop()
        repoWatcher = nil
        worktreesAdminDir = nil
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
        await startRepoWatching(repo)
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

    // MARK: - Auto-detecting worktree add/remove

    /// Watch the selected repo's git common dir. A `git worktree add`/`remove` (or
    /// `prune`) rewrites `worktrees/…` there, which `handleRepoWatchEvent` filters
    /// for; routine index/ref writes in the primary checkout are ignored.
    private func startRepoWatching(_ repo: Repository) async {
        repoWatcher?.stop()
        let commonDir = await resolveGitCommonDir(for: repo)
        worktreesAdminDir = (commonDir as NSString).appendingPathComponent("worktrees")
        let watcher = environment.makeWatcher()
        watcher.start(paths: [commonDir], debounce: 0.5) { [weak self] paths in
            Task { @MainActor in await self?.handleRepoWatchEvent(paths) }
        }
        repoWatcher = watcher
    }

    /// The repo's git *common* dir — where worktree admin data lives regardless of
    /// whether `<repo>/.git` is a real directory or a gitlink. Falls back to
    /// `<repo>/.git` if `git rev-parse` can't answer.
    private func resolveGitCommonDir(for repo: Repository) async -> String {
        let fallback = (repo.path as NSString).appendingPathComponent(".git")
        guard let result = try? await environment.git.run(["rev-parse", "--git-common-dir"], in: repo.path),
              result.succeeded else { return fallback }
        let raw = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return fallback }
        return (raw as NSString).isAbsolutePath ? raw : (repo.path as NSString).appendingPathComponent(raw)
    }

    /// FSEvents on the repo's git common dir: re-scan only when the change touched the
    /// worktree admin area (`worktrees/…`). Internal + async so it is unit-testable
    /// without real FSEvents.
    func handleRepoWatchEvent(_ changedPaths: [String]) async {
        guard selectedRepo != nil, let adminDir = worktreesAdminDir else { return }
        guard changedPaths.contains(where: { $0.hasPrefix(adminDir) }) else { return }
        await refreshWorktrees()
    }

    /// Re-discover the repo's worktrees + branches in place — the manual Refresh
    /// button and the auto-detect watcher both land here. Unlike `selectRepo` it
    /// preserves the current selection (only falling back to the primary if the
    /// selected worktree has vanished), so a refresh never yanks the user off their
    /// worktree. Concurrent calls coalesce into a single queued follow-up.
    func refreshWorktrees() async {
        if isRescanning { rescanQueued = true; return }
        isRescanning = true
        defer { isRescanning = false }
        repeat {
            rescanQueued = false
            await rescanWorktrees()
        } while rescanQueued
    }

    private func rescanWorktrees() async {
        guard let repo = selectedRepo else { return }
        let discovered: [Worktree]
        let discoveredBranches: [Branch]
        do {
            discovered = try await environment.worktreeService.worktrees(for: repo)
            discoveredBranches = try await environment.branchService.branches(for: repo)
            errorMessage = nil
        } catch {
            // A transient failure shouldn't blank the list — keep what we have.
            errorMessage = "\(error)"
            return
        }
        worktrees = discovered
        branches = discoveredBranches
        await refreshWorktreeInfo()
        // Keep the current selection if it still exists; only re-focus when it's gone.
        if let current = selectedWorktree, discovered.contains(where: { $0.path == current.path }) {
            return
        }
        if let fallback = discovered.first(where: { $0.isPrimary }) ?? discovered.first {
            await selectWorktree(fallback)
        } else {
            selectedWorktree = nil
            worktree.clear()
            onSelectionChange?()
        }
    }

    /// Load per-worktree ahead/behind + change count + live state for the
    /// WORKTREES list (drives the sync arrows and pulse dot).
    func refreshWorktreeInfo(now: Date = Date()) async {
        let statusService = environment.statusService
        let worktrees = self.worktrees
        // Fetch each worktree's status concurrently — these are independent git
        // reads, so a repo with many worktrees shouldn't serialize N `git status`
        // calls on every repo switch.
        let statuses = await withTaskGroup(of: (String, StatusResult?).self) { group in
            for worktree in worktrees {
                let path = worktree.path
                group.addTask { (path, try? await statusService.status(worktreePath: path)) }
            }
            var byPath: [String: StatusResult] = [:]
            for await (path, status) in group {
                if let status { byPath[path] = status }
            }
            return byPath
        }
        var info: [String: WorktreeInfo] = [:]
        for worktree in worktrees {
            let status = statuses[worktree.path]
            info[worktree.path] = WorktreeInfo(
                ahead: status?.ahead ?? 0,
                behind: status?.behind ?? 0,
                changeCount: status?.changes.count ?? 0,
                isLive: environment.activityMonitor.isBusy(worktreePath: worktree.path, within: 5, now: now)
            )
        }
        worktreeInfo = info
    }

    func info(for worktree: Worktree) -> WorktreeInfo {
        worktreeInfo[worktree.path] ?? WorktreeInfo()
    }

    func selectWorktree(_ wt: Worktree) async {
        selectedWorktree = wt
        highlightedWorktree = wt
        await worktree.load(worktreePath: wt.path, repo: selectedRepo)
        onSelectionChange?()
    }

    // MARK: - Keyboard navigation (WORKTREES)

    /// The keyboard cursor in the WORKTREES list, distinct from the committed
    /// `selectedWorktree`: ↑/↓ move it, Enter commits it (switching the worktree).
    var highlightedWorktree: Worktree?

    /// Seed the cursor on the currently-open worktree (when WORKTREES becomes active).
    func highlightSelectedWorktree() { highlightedWorktree = selectedWorktree }

    /// Move the keyboard cursor one row (no switch — that happens on commit).
    func moveWorktreeHighlight(by delta: Int) {
        guard !worktrees.isEmpty else { return }
        let base = highlightedWorktree ?? selectedWorktree
        let index = base.flatMap { b in worktrees.firstIndex { $0.path == b.path } } ?? 0
        let next = max(0, min(worktrees.count - 1, index + delta))
        highlightedWorktree = worktrees[next]
    }

    /// Commit the highlighted worktree (Enter): switch to it unless it's already current.
    func commitHighlightedWorktree() async {
        guard let wt = highlightedWorktree, wt.path != selectedWorktree?.path else { return }
        await selectWorktree(wt)
    }
}
