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
        /// Commits to push / pull against the remote copy of this same branch;
        /// zero when the branch tracks another branch or nothing (see `remote`).
        var ahead: Int = 0
        var behind: Int = 0
        var changeCount: Int = 0
        /// The last `git status` read succeeded, so `changeCount` is a fact rather
        /// than a placeholder for "unknown".
        var hasStatus: Bool = false
        var isLive: Bool = false
        /// What the coding agents working in this worktree are doing, from their
        /// own records (session logs, rollouts, session registry).
        var agentState: AgentActivityState = .idle
        /// The branch against its same-named remote branch; unknown until a status
        /// read succeeds.
        var remote: RemoteSync = .unknown
        /// The folder is gone but Git's record of it still holds work no branch
        /// has, so the row stays listed instead of being forgotten.
        var isKeptMissing = false

        /// Whether there is anything to pull or push — rows hide the "↓ ↑"
        /// indicator entirely when both counts are zero.
        var hasSync: Bool { ahead > 0 || behind > 0 }
    }

    private(set) var repositories: [Repository] = []
    private(set) var selectedRepo: Repository?
    /// The worktrees Teebe shows. One whose folder is gone never is: a deleted one
    /// is forgotten (`forgetDeleted`), one out of reach waits for its drive. The
    /// exception is a deleted one whose record still holds work: it stays listed.
    private(set) var worktrees: [Worktree] = []
    /// Listed worktrees whose folder is gone, kept because their record holds
    /// work no branch has (`MissingWorktrees.holdsUnsavedWork`).
    private(set) var keptMissingPaths: Set<String> = []
    private(set) var selectedWorktree: Worktree?
    private(set) var branches: [Branch] = []
    /// Sync/activity info keyed by worktree path.
    private(set) var worktreeInfo: [String: WorktreeInfo] = [:]
    private(set) var mergeRevision = 0
    var errorMessage: String?
    /// How many deleted worktrees were forgotten since the notice was last
    /// dismissed (or the repository changed).
    private(set) var cleanedUpCount = 0
    /// Answers whether a removal is running; nothing is forgotten meanwhile.
    var isRemovalRunning: @MainActor () -> Bool = { false }
    /// A record that was tried is left alone this long, so a refresh storm never
    /// asks Git to forget the same worktree over and over.
    var forgetRetryInterval: TimeInterval = 300
    private var forgetAttempts: [String: Date] = [:]
    private var isForgetting = false

    let worktree: WorktreeModel

    /// Invoked whenever the selected repo/worktree changes, so the owner can persist
    /// the new selection (drives "reopen where I left off").
    var onSelectionChange: (() -> Void)?
    var onRepositoryChange: (() -> Void)?
    private(set) var isLoading = false
    var notificationsEnabled = true {
        didSet {
            guard notificationsEnabled, !oldValue else { return }
            turnDelivery.resumeObservation()
            needsNotificationBaseline = true
        }
    }
    @ObservationIgnored private var needsNotificationBaseline = false
    @ObservationIgnored private var turnDelivery = AgentTurnDelivery()
    @ObservationIgnored private var lastAgentSnapshotAt = Date.distantPast
    @ObservationIgnored private var agentRefreshGeneration = 0

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
    /// Watches the Claude projects root so agent badges react to session-log
    /// writes (which happen outside any repo, so the repo watchers never see them).
    private var agentWatcher: FileSystemWatcher?
    /// Periodic re-derive so purely time-based transitions (stall, idle-out)
    /// happen even when no session log is being written.
    private var agentPollTask: Task<Void, Never>?
    /// Darwin-notification listener for the Claude Code hook ping — the push
    /// signal that keeps badges and notifications instant even in low power.
    private var agentPingListener: AgentPingListening?
    /// Low-power mode (window occluded): every FSEvents watcher is stopped and
    /// the app rides on the hook ping plus a slow poll. See `setLowPower`.
    private(set) var isLowPower = false
    /// Poll cadences for the time-only agent transitions (stall/idle-out).
    /// Vars so tests can shrink them.
    var agentPollInterval: TimeInterval = 30
    var lowPowerAgentPollInterval: TimeInterval = 120
    /// Delay before the catch-up re-derive that follows a hook ping.
    var agentPingSettle: TimeInterval = 2
    /// How long a worktree stays working after its last file change or busy
    /// process (`GenericActivity.window`). A var so tests can shrink it.
    var liveWindow: TimeInterval = GenericActivity.window
    /// One FSEvents stream over every worktree of the repo, so file activity in
    /// a worktree that isn't selected lights its row too (any harness).
    private var worktreesWatcher: FileSystemWatcher?
    /// Worktrees whose uncommitted count is being re-read after a write.
    private var countRefreshPending: Set<String> = []
    private var isRefreshingCounts = false
    /// Gentle poll of the process table for busy processes in the worktrees.
    private var processPollTask: Task<Void, Never>?
    var processPollInterval: TimeInterval = 3
    var isPollingProcesses: Bool { processPollTask != nil }
    /// One-shot follow-up scheduled while any live dot is lit, so `isLive` expires
    /// shortly after the busy window lapses instead of latching until the next
    /// event (a latched dot keeps a repeat-forever pulse animation burning CPU).
    private var liveExpiryTask: Task<Void, Never>?

    init(environment: AppEnvironment) {
        self.environment = environment
        self.worktree = WorktreeModel(environment: environment)
        // An external write to the active worktree should re-light its live dot
        // immediately, without waiting for a manual refresh. It must NOT bump
        // `mergeRevision`: editing file content cannot change merge ancestry, and a
        // busy agent fires a batch every 250 ms — each one would restart the whole
        // merge scan. Ref writes go through `handleRepoWatchEvent`, worktree
        // add/remove through `applyDiscovered`.
        self.worktree.onActivity = { [weak self] _ in
            self?.refreshLiveState()
        }
    }

    /// Recompute only the cheap `isLive` flags from the activity monitor (no git),
    /// e.g. after a file-watch event reports external activity.
    func refreshLiveState(now: Date = Date()) {
        var anyLive = false
        var info = worktreeInfo
        for wt in worktrees {
            var entry = info[wt.path] ?? WorktreeInfo()
            entry.isLive = environment.activityMonitor.isBusy(worktreePath: wt.path, within: liveWindow, now: now)
            anyLive = anyLive || entry.isLive
            info[wt.path] = entry
        }
        publish(info)
        scheduleLiveExpiry(anyLive: anyLive)
    }

    /// Every write to `worktreeInfo` re-renders the whole worktree list, and most
    /// refreshes (polls, file bursts, log writes) find nothing new: only write
    /// when a row's facts changed. Writing through the dictionary's subscript
    /// would notify observers even when the value is unchanged.
    private func publish(_ info: [String: WorktreeInfo]) {
        guard info != worktreeInfo else { return }
        worktreeInfo = info
    }

    /// While any dot is lit, keep a single pending re-check just past the busy
    /// window; each activity event pushes it back, so the last write is followed
    /// by exactly one expiry pass that turns the dot (and its animation) off.
    private func scheduleLiveExpiry(anyLive: Bool) {
        liveExpiryTask?.cancel()
        liveExpiryTask = nil
        guard anyLive else { return }
        liveExpiryTask = Task { [weak self] in
            guard let window = self?.liveWindow else { return }
            try? await Task.sleep(for: .seconds(window + 0.5))
            guard !Task.isCancelled else { return }
            self?.refreshLiveState()
        }
    }

    func setRepositories(_ repos: [Repository]) {
        repositories = repos
    }

    /// The calm one-line notice after deleted worktrees were forgotten.
    var cleanupNotice: String? {
        guard cleanedUpCount > 0 else { return nil }
        return cleanedUpCount == 1 ? "Cleaned up 1 worktree whose folder was deleted."
            : "Cleaned up \(cleanedUpCount) worktrees whose folders were deleted."
    }

    func dismissCleanupNotice() { cleanedUpCount = 0 }

    func clearSelection() {
        cleanedUpCount = 0
        keptMissingPaths = []
        forgetAttempts.removeAll()
        repoWatcher?.stop()
        repoWatcher = nil
        worktreesAdminDir = nil
        stopAgentWatching()
        stopWorktreeActivity()
        turnDelivery.watch([])
        lastAgentSnapshotAt = .distantPast
        selectedRepo = nil
        onRepositoryChange?()
        worktrees = []
        selectedWorktree = nil
        branches = []
        worktree.clear()
        onSelectionChange?()
    }

    /// Select a repo: discover its worktrees + branches, then focus
    /// `preferredWorktreePath` when it still exists, else the primary worktree.
    /// Restoring a saved selection goes through the preference rather than a
    /// primary-then-saved double load: two full tree loads inside the window's
    /// first layout pass escalate into an AppKit constraint-loop crash at launch.
    func selectRepo(_ repo: Repository, preferredWorktreePath: String? = nil) async {
        isLoading = true
        defer { isLoading = false }
        if selectedRepo?.path != repo.path {
            turnDelivery.watch([])
            lastAgentSnapshotAt = .distantPast
            cleanedUpCount = 0
            forgetAttempts.removeAll()
        }
        selectedRepo = repo
        onRepositoryChange?()
        await startRepoWatching(repo)
        startAgentWatching()
        var deleted: [Worktree] = []
        do {
            let found = await sortMissing(try await environment.worktreeService.worktrees(for: repo), in: repo)
            deleted = found.deleted
            applyDiscovered(found.listed)
            branches = try await environment.branchService.branches(for: repo)
            errorMessage = nil
        } catch {
            applyDiscovered([])
            branches = []
            errorMessage = WorktreeModel.describe(error)
        }
        await refreshWorktreeInfo()
        let target = preferredWorktreePath.flatMap { preferred in
            worktrees.first { $0.path == preferred }
        } ?? worktrees.first(where: { $0.isPrimary }) ?? worktrees.first
        if let target {
            await selectWorktree(target)
        }
        onSelectionChange?()
        await forgetDeleted(deleted, in: repo)
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

    /// FSEvents on the repo's git common dir: re-scan when the change touched the
    /// worktree admin area (`worktrees/…`); re-read the rows' sync facts when only
    /// refs moved (a fetch, a commit, a deleted remote branch). Internal + async so
    /// it is unit-testable without real FSEvents.
    func handleRepoWatchEvent(_ changedPaths: [String]) async {
        guard selectedRepo != nil, let adminDir = worktreesAdminDir else { return }
        let commonDir = (adminDir as NSString).deletingLastPathComponent
        let refsChanged = changedPaths.contains { $0.hasPrefix(commonDir + "/refs/") || $0 == commonDir + "/packed-refs" }
        if refsChanged { mergeRevision += 1 }
        if changedPaths.contains(where: { $0.hasPrefix(adminDir) }) {
            await refreshWorktrees()
        } else if refsChanged {
            // A push or fetch can add or drop the remote branch a row is compared with.
            if let repo = selectedRepo, let found = try? await environment.branchService.branches(for: repo) {
                branches = found
            }
            await refreshWorktreeInfo()
        }
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
        let deleted: [Worktree]
        let discoveredBranches: [Branch]
        do {
            (discovered, deleted) = await sortMissing(try await environment.worktreeService.worktrees(for: repo), in: repo)
            discoveredBranches = try await environment.branchService.branches(for: repo)
            errorMessage = nil
        } catch {
            // A transient failure shouldn't blank the list — keep what we have.
            errorMessage = WorktreeModel.describe(error)
            return
        }
        applyDiscovered(discovered)
        branches = discoveredBranches
        await refreshWorktreeInfo()
        // Keep the current selection if it still exists; only re-focus when it's gone.
        let isSelectionListed = selectedWorktree.map { current in discovered.contains { $0.path == current.path } } ?? false
        if !isSelectionListed, let fallback = discovered.first(where: { $0.isPrimary }) ?? discovered.first {
            await selectWorktree(fallback)
        } else if !isSelectionListed {
            selectedWorktree = nil
            worktree.clear()
            onSelectionChange?()
        }
        await forgetDeleted(deleted, in: repo)
    }

    // MARK: - Worktrees whose folder is gone

    /// Split what Git lists into the rows to show and the deleted ones to forget.
    /// A worktree out of reach (drive not mounted, or locked) is in neither: it is
    /// hidden and left alone until its folder is back. A deleted one whose record
    /// still holds work is shown, so the user can see why it stays.
    private func sortMissing(_ all: [Worktree], in repo: Repository) async -> (listed: [Worktree], deleted: [Worktree]) {
        let missing = environment.missingWorktrees
        var listed: [Worktree] = []
        var deleted: [Worktree] = []
        var kept: Set<String> = []
        for worktree in all {
            switch missing.disposition(of: worktree) {
            case .present: listed.append(worktree)
            case .deleted:
                if await missing.holdsUnsavedWork(worktree, repoPath: repo.path) {
                    listed.append(worktree)
                    kept.insert(worktree.path)
                } else {
                    deleted.append(worktree)
                }
            case .unreachable: break
            }
        }
        keptMissingPaths = kept
        return (listed, deleted)
    }

    /// Forget deleted worktrees' records, one at a time, never while a removal
    /// runs. Each is re-checked right before (`MissingWorktrees.forget`), and one
    /// tried recently is skipped. A failure stays quiet: the row is hidden anyway,
    /// and it is tried again after `forgetRetryInterval`.
    private func forgetDeleted(_ candidates: [Worktree], in repo: Repository, now: Date = Date()) async {
        let due = candidates.filter { candidate in
            forgetAttempts[candidate.path].map { now.timeIntervalSince($0) >= forgetRetryInterval } ?? true
        }
        guard !due.isEmpty, !isForgetting else { return }
        isForgetting = true
        defer { isForgetting = false }
        let missing = environment.missingWorktrees
        for candidate in due {
            guard !isRemovalRunning(), selectedRepo?.path == repo.path else { return }
            forgetAttempts[candidate.path] = now
            if await missing.forget(candidate, repoPath: repo.path) { cleanedUpCount += 1 }
        }
    }

    /// The folder-gone placeholder's Forget: forget just this worktree's record,
    /// with the same checks as the automatic clean-up, then re-read the list.
    func forgetMissingWorktree(_ path: String) async {
        guard let repo = selectedRepo,
              let listed = try? await environment.worktreeService.worktrees(for: repo),
              let target = listed.first(where: { $0.path == path }) else { return }
        forgetAttempts[path] = nil
        await forgetDeleted([target], in: repo)
        await refreshWorktrees()
    }

    /// Adopt a freshly discovered worktree list. Merge ancestry can only have moved
    /// when the set of checkouts changed or one of their HEADs did, so only that
    /// bumps `mergeRevision`. Re-discovering the same trees — which is what a manual
    /// Refresh, a selection change, or leaving low power (alt-tab) does — reuses the
    /// last scan instead of restarting a full N-worktree check.
    private func applyDiscovered(_ discovered: [Worktree]) {
        func identity(_ trees: [Worktree]) -> [String] { trees.map { $0.path + "\u{0}" + $0.head } }
        if identity(discovered) != identity(worktrees) { mergeRevision += 1 }
        let pathsChanged = discovered.map(\.path) != worktrees.map(\.path)
        worktrees = discovered
        turnDelivery.watch(discovered.map(\.path))
        if pathsChanged || worktreesWatcher == nil { startWorktreeActivity() }
    }

    /// Load per-worktree ahead/behind + change count + live state for the
    /// WORKTREES list (drives the sync arrows and pulse dot).
    func refreshWorktreeInfo(now: Date = Date()) async {
        let statusService = environment.statusService
        let agentStatuses = environment.agentStatuses
        let agentTurnEnds = environment.agentTurnEnds
        let repository = selectedRepo?.path
        agentRefreshGeneration += 1
        let generation = agentRefreshGeneration
        let worktrees = self.worktrees
        let paths = worktrees.map(\.path)
        // One batched agent-log scan for the whole repo — the scanner needs every
        // worktree path to attribute a session to the worktree it runs in, not
        // the one it was launched from. Runs off-main alongside the git reads.
        let agentTask = Task.detached { (agentStatuses(paths, now), agentTurnEnds(paths, now)) }
        // Fetch each worktree's status concurrently — these are independent git
        // reads, so a repo with many worktrees shouldn't serialize N `git status`
        // calls on every repo switch.
        let statuses = await withTaskGroup(of: (String, StatusResult?).self) { group in
            for worktree in worktrees {
                let path = worktree.path
                group.addTask {
                    (path, try? await statusService.status(worktreePath: path))
                }
            }
            var byPath: [String: StatusResult?] = [:]
            for await (path, status) in group {
                byPath[path] = status
            }
            return byPath
        }
        let (agentStates, turnEnds) = await agentTask.value
        guard selectedRepo?.path == repository, self.worktrees.map(\.path) == paths,
              generation == agentRefreshGeneration else { return }
        let remoteBranches = Set(branches.filter(\.isRemote).map(\.name))
        var info: [String: WorktreeInfo] = [:]
        for worktree in worktrees {
            let status = statuses[worktree.path] ?? nil
            let agent = agentStates[worktree.path] ?? .idle
            let remote = status.map { RemoteSync(status: $0, remoteBranches: remoteBranches) } ?? .unknown
            info[worktree.path] = WorktreeInfo(
                ahead: remote.ahead,
                behind: remote.behind,
                changeCount: status?.changes.count ?? 0,
                hasStatus: status != nil,
                isLive: environment.activityMonitor.isBusy(worktreePath: worktree.path, within: liveWindow, now: now),
                agentState: agent,
                remote: remote,
                isKeptMissing: keptMissingPaths.contains(worktree.path)
            )
        }
        notifyAgentTransitions(from: worktreeInfo, to: info, turnEnds: turnEnds, now: now)
        publish(info)
    }

    func info(for worktree: Worktree) -> WorktreeInfo {
        worktreeInfo[worktree.path] ?? WorktreeInfo()
    }

    // MARK: - Agent status (Claude Code session logs)

    /// Re-derive only the agent badges — no git. Used by the projects-root
    /// watcher and the periodic poll; cheap enough to run often.
    func refreshAgentStates(now: Date = Date()) async {
        let agentStatuses = environment.agentStatuses
        let agentTurnEnds = environment.agentTurnEnds
        let repository = selectedRepo?.path
        agentRefreshGeneration += 1
        let generation = agentRefreshGeneration
        let worktrees = self.worktrees
        let paths = worktrees.map(\.path)
        let (states, turnEnds) = await Task.detached { (agentStatuses(paths, now), agentTurnEnds(paths, now)) }.value
        guard selectedRepo?.path == repository, self.worktrees.map(\.path) == paths,
              generation == agentRefreshGeneration else { return }
        var info = worktreeInfo
        for worktree in worktrees {
            var entry = info[worktree.path] ?? WorktreeInfo()
            entry.agentState = states[worktree.path] ?? .idle
            entry.isLive = environment.activityMonitor.isBusy(worktreePath: worktree.path, within: liveWindow, now: now)
            info[worktree.path] = entry
        }
        notifyAgentTransitions(from: worktreeInfo, to: info, turnEnds: turnEnds, now: now)
        publish(info)
    }

    /// Recorded turn ends also cover work completed entirely between polls.
    /// Badge edges remain the fallback for questions, stalls and other adapters.
    private func notifyAgentTransitions(from old: [String: WorktreeInfo], to new: [String: WorktreeInfo],
                                        turnEnds: [AgentTurnEnd], now: Date) {
        // A scan can read a completion after reading the working badge. Keep
        // that ending through the following badge edge, even if already delivered.
        let endedPaths = Set(turnEnds.filter { $0.endedAt >= lastAgentSnapshotAt }.map(\.worktreePath))
        lastAgentSnapshotAt = now
        let fresh = turnDelivery.consume(turnEnds, now: max(now, Date()))
        guard notificationsEnabled else { return }
        for event in fresh where event.completed {
            let name = worktrees.first { $0.path == event.worktreePath }?.branch ?? URL(fileURLWithPath: event.worktreePath).lastPathComponent
            environment.notify("Agent finished", "\(name): Codex finished a turn")
        }
        // A badge may still describe work that ended while notifications were
        // off. The first enabled snapshot establishes a new transition baseline;
        // journal completions newer than the toggle are still delivered above.
        if needsNotificationBaseline {
            needsNotificationBaseline = false
            return
        }
        for worktree in worktrees {
            guard !endedPaths.contains(worktree.path), old[worktree.path]?.agentState == .working,
                  new[worktree.path]?.agentState == .needsAttention else { continue }
            let name = worktree.branch ?? worktree.name
            environment.notify("Agent needs you", "\(name) — the agent finished or is waiting")
        }
    }

    /// Watch the Claude projects root (session logs live outside the repo, so the
    /// repo watchers never see them), listen for the hook ping, and poll slowly
    /// for time-only transitions.
    private func startAgentWatching() {
        stopAgentWatching()
        guard environment.agentProjectsRootPath != nil else { return }
        startAgentWatcher()
        let listener = environment.makeAgentPingListener()
        listener.start { [weak self] in
            Task { @MainActor in await self?.handleAgentPing() }
        }
        agentPingListener = listener
        agentPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.currentAgentPollInterval else { return }
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                await self?.refreshAgentStates()
            }
        }
    }

    /// Just the FSEvents stream over the projects root — the part of agent
    /// watching that low power turns off (the ping and slow poll stay on).
    private func startAgentWatcher() {
        agentWatcher?.stop()
        agentWatcher = nil
        guard !isLowPower, let root = environment.agentProjectsRootPath else { return }
        // Claude Code's live session registry sits beside the projects root; a
        // permission prompt flips it to waiting without writing any session log.
        let registry = URL(fileURLWithPath: root).deletingLastPathComponent()
            .appendingPathComponent("sessions", isDirectory: true).path
        // Other harnesses' rollouts (Codex) change on the same cadence. FSEvents
        // is recursive, so a resumed thread writing to an older date folder is
        // seen too; only the paths Teebe reads cost anything.
        let watcher = environment.makeWatcher()
        watcher.start(paths: [root, registry] + environment.agentExtraWatchPaths, debounce: 1.0) { [weak self] paths in
            Task { @MainActor in await self?.handleAgentWatchEvent(paths) }
        }
        agentWatcher = watcher
    }

    private var currentAgentPollInterval: TimeInterval {
        isLowPower ? lowPowerAgentPollInterval : agentPollInterval
    }

    private func stopAgentWatching() {
        agentWatcher?.stop()
        agentWatcher = nil
        agentPingListener?.stop()
        agentPingListener = nil
        agentPollTask?.cancel()
        agentPollTask = nil
    }

    // MARK: - Low-power mode (window occluded)

    /// With the window occluded nobody is looking at the tree, so live FSEvents
    /// streams (worktree, repo git dir, projects root) only burn CPU: with N busy
    /// agents they wake the app about once a second. Low power stops them all and
    /// relies on the hook ping (instant, push) plus the slow poll (stall/idle),
    /// so "Agent needs you" notifications still fire while backgrounded. Exiting
    /// restarts the watchers and re-derives everything missed.
    func setLowPower(_ on: Bool) async {
        guard on != isLowPower else { return }
        isLowPower = on
        if on {
            repoWatcher?.stop()
            agentWatcher?.stop()
            agentWatcher = nil
            stopWorktreeActivity()
            worktree.pauseWatching()
        } else {
            if let repo = selectedRepo { await startRepoWatching(repo) }
            startAgentWatcher()
            startWorktreeActivity()
            await worktree.resumeWatching()
            await refreshWorktrees()
        }
    }

    /// A Claude Code hook pinged. Hooks run a beat before Claude Code records
    /// what they announce (UserPromptSubmit fires before the prompt is logged
    /// or the session registry turns busy), so look again once it has — in low
    /// power nothing else would until the slow poll.
    func handleAgentPing() async {
        await refreshAgentStates()
        try? await Task.sleep(for: .seconds(agentPingSettle))
        await refreshAgentStates()
    }

    /// A coalesced batch of session-log writes — re-derive the badges, unless
    /// every write belongs to another project's sessions (which the scan never
    /// reads): Claude Code sessions elsewhere log continuously.
    func handleAgentWatchEvent(_ paths: [String]) async {
        let otherAgentChanged = paths.contains { path in
            environment.agentExtraWatchPaths.contains { root in path == root || path.hasPrefix(root + "/") }
        }
        if !otherAgentChanged, let root = environment.agentProjectsRootPath,
           !AgentSessionScanner.eventsMatter(paths, projectsRoot: root, worktreePaths: worktrees.map(\.path)) {
            return
        }
        await refreshAgentStates()
    }

    // MARK: - Generic activity (any harness): files and processes

    /// Watch every worktree's files and poll for busy processes. Off in low power
    /// and without a repo; restarted when the set of worktrees changes.
    private func startWorktreeActivity() {
        stopWorktreeActivity()
        guard !isLowPower, selectedRepo != nil, !worktrees.isEmpty else { return }
        let watcher = environment.makeWatcher()
        watcher.start(paths: worktrees.map(\.path), debounce: 1.0) { [weak self] paths in
            Task { @MainActor in await self?.handleWorktreeFileEvents(paths) }
        }
        worktreesWatcher = watcher
        guard environment.processActivity != nil else { return }
        processPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.processPollInterval else { return }
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                await self?.pollProcessActivity()
            }
        }
    }

    private func stopWorktreeActivity() {
        worktreesWatcher?.stop()
        worktreesWatcher = nil
        processPollTask?.cancel()
        processPollTask = nil
    }

    /// A coalesced batch of file events from any worktree: the worktrees whose
    /// own files changed (not Git's bookkeeping, build output or caches) are
    /// working, and their uncommitted counts are re-read. Teebe's own writes to
    /// the selected worktree are not activity.
    func handleWorktreeFileEvents(_ paths: [String], now: Date = Date()) async {
        var changed = WorktreeActivityRouter.changedWorktrees(eventPaths: paths, among: worktrees.map(\.path))
        if let selected = selectedWorktree?.path, worktree.recentSelfWrite(now: now) { changed.remove(selected) }
        // A folder deleted outside Teebe: re-read the list, which cleans it up.
        let deleted = changed.filter { path in
            worktrees.contains { $0.path == path && !$0.isPrimary } && environment.folderIsGone(path)
        }
        if !deleted.isEmpty {
            changed.subtract(deleted)
            await refreshWorktrees()
        }
        guard !changed.isEmpty else { return }
        for path in changed { environment.activityMonitor.recordActivity(worktreePath: path, at: now) }
        refreshLiveState(now: now)
        await refreshChangeCounts(changed)
    }

    /// Re-read `git status` for just these worktrees, so a new untracked file in a
    /// worktree that isn't selected turns its row uncommitted without waiting for
    /// the next full refresh. Concurrent requests coalesce.
    private func refreshChangeCounts(_ paths: Set<String>) async {
        countRefreshPending.formUnion(paths)
        guard !isRefreshingCounts else { return }
        isRefreshingCounts = true
        defer { isRefreshingCounts = false }
        let statusService = environment.statusService
        while !countRefreshPending.isEmpty {
            let batch = countRefreshPending
            countRefreshPending.removeAll()
            for path in batch {
                guard let status = try? await statusService.status(worktreePath: path),
                      var info = worktreeInfo[path] else { continue }
                info.changeCount = status.changes.count
                info.hasStatus = true
                guard info != worktreeInfo[path] else { continue }
                worktreeInfo[path] = info
            }
        }
    }

    /// One look at the process table: worktrees with a busy process are working.
    func pollProcessActivity(now: Date = Date()) async {
        guard let probe = environment.processActivity else { return }
        let paths = worktrees.map(\.path)
        let active = await Task.detached { probe(paths, now) }.value
        guard !active.isEmpty else { return }
        for path in active { environment.activityMonitor.recordActivity(worktreePath: path, at: now) }
        refreshLiveState(now: now)
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
    func moveWorktreeHighlight(by delta: Int, in visibleRows: [Worktree]? = nil) {
        let rows = visibleRows ?? worktrees
        guard !rows.isEmpty else { return }
        let edge = delta > 0 ? rows.count - 1 : 0
        guard let base = highlightedWorktree ?? selectedWorktree else {
            highlightedWorktree = rows[delta > 0 ? 0 : rows.count - 1]
            return
        }
        if let index = rows.firstIndex(where: { $0.path == base.path }) {
            highlightedWorktree = rows[max(0, min(rows.count - 1, index + delta))]
            return
        }
        // The cursor sits on a row hidden inside a collapsed group, so it has no
        // position in the visible list. Place it by the full worktree order and step
        // to the nearest visible neighbour in the direction of travel — falling back
        // to the first row would silently jump the cursor to the top of the list.
        guard let origin = worktrees.firstIndex(where: { $0.path == base.path }) else {
            highlightedWorktree = rows[delta > 0 ? 0 : rows.count - 1]
            return
        }
        let visiblePaths = Set(rows.map(\.path))
        let neighbour = delta > 0
            ? worktrees[(origin + 1)...].first { visiblePaths.contains($0.path) }
            : worktrees[..<origin].last { visiblePaths.contains($0.path) }
        highlightedWorktree = neighbour ?? rows[edge]
    }

    /// Commit the highlighted worktree (Enter): switch to it unless it's already current.
    func commitHighlightedWorktree() async {
        guard let wt = highlightedWorktree, wt.path != selectedWorktree?.path else { return }
        await selectWorktree(wt)
    }
}
