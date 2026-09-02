import Foundation
import TeebeCore

/// Bundles the app's dependencies so view models can be wired for production
/// (`live`) or constructed with fakes in tests.
@MainActor
struct AppEnvironment {
    let git: GitClient
    let opener: FileOpener
    let ops: FileOps
    let store: AppStateStore
    let activityMonitor: WorktreeActivityMonitor
    /// Factory for a file-system watcher (overridable with a fake in tests).
    let makeWatcher: @MainActor () -> FileSystemWatcher
    /// Reads the agent activity states for all of a repo's worktree paths at
    /// once (live: Claude Code session logs via `AgentSessionScanner`; tests
    /// inject a script). Batched so the scanner can attribute a session logged
    /// under one worktree's project dir to the worktree it actually runs in.
    let agentStatuses: @Sendable (_ worktreePaths: [String], _ now: Date) -> [String: AgentActivityState]
    /// Where the session logs live, so a watcher can react to log writes.
    /// nil disables watching (and in tests, the watcher entirely).
    let agentProjectsRootPath: String?
    /// Posts a user-facing notification (title, body).
    let notify: @MainActor (_ title: String, _ body: String) -> Void
    /// Factory for the darwin-notification listener the Claude Code hook pings
    /// (`notifyutil -p dev.teebe.agent`). Overridable with a fake in tests.
    let makeAgentPingListener: @MainActor () -> AgentPingListening

    init(
        git: GitClient,
        opener: FileOpener,
        ops: FileOps,
        store: AppStateStore,
        activityMonitor: WorktreeActivityMonitor,
        makeWatcher: @escaping @MainActor () -> FileSystemWatcher,
        agentStatuses: @escaping @Sendable ([String], Date) -> [String: AgentActivityState] = { _, _ in [:] },
        agentProjectsRootPath: String? = nil,
        notify: @escaping @MainActor (String, String) -> Void = { _, _ in },
        makeAgentPingListener: @escaping @MainActor () -> AgentPingListening = { DarwinAgentPingListener() }
    ) {
        self.git = git
        self.opener = opener
        self.ops = ops
        self.store = store
        self.activityMonitor = activityMonitor
        self.makeWatcher = makeWatcher
        self.agentStatuses = agentStatuses
        self.agentProjectsRootPath = agentProjectsRootPath
        self.notify = notify
        self.makeAgentPingListener = makeAgentPingListener
    }

    var worktreeService: WorktreeService { WorktreeService(git: git) }
    var statusService: StatusService { StatusService(git: git) }
    var diffService: DiffService { DiffService(git: git) }
    var branchService: BranchService { BranchService(git: git) }

    func makeQueue(repoPath: String) -> RepoGitQueue {
        RepoGitQueue(git: git, repoPath: repoPath)
    }

    static func live() -> AppEnvironment {
        // `TEEBE_CLAUDE_PROJECTS_DIR` override exists for live testing against a
        // synthetic projects tree; real runs use `~/.claude/projects`.
        let projectsRoot = ProcessInfo.processInfo.environment["TEEBE_CLAUDE_PROJECTS_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? AgentSessionScanner.defaultProjectsRoot
        let scanner = AgentSessionScanner(projectsRoot: projectsRoot)
        return AppEnvironment(
            git: ProcessGitClient(),
            opener: WorkspaceFileOpener(),
            ops: FileManagerFileOps(),
            store: AppStateStore(),
            activityMonitor: WorktreeActivityMonitor(),
            makeWatcher: { FSEventsWatcher() },
            agentStatuses: { paths, now in scanner.states(forWorktreePaths: paths, now: now) },
            agentProjectsRootPath: projectsRoot.path,
            notify: AgentNotifier.post
        )
    }
}
