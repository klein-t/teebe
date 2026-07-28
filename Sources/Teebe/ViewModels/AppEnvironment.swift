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
    /// Reads the agent activity state for a worktree path (live: Claude Code
    /// session logs via `AgentSessionScanner`; tests inject a script).
    let agentStatus: @Sendable (_ worktreePath: String, _ now: Date) -> AgentActivityState
    /// Where the session logs live, so a watcher can react to log writes.
    /// nil disables watching (and in tests, the watcher entirely).
    let agentProjectsRootPath: String?
    /// Posts a user-facing notification (title, body).
    let notify: @MainActor (_ title: String, _ body: String) -> Void

    init(
        git: GitClient,
        opener: FileOpener,
        ops: FileOps,
        store: AppStateStore,
        activityMonitor: WorktreeActivityMonitor,
        makeWatcher: @escaping @MainActor () -> FileSystemWatcher,
        agentStatus: @escaping @Sendable (String, Date) -> AgentActivityState = { _, _ in .idle },
        agentProjectsRootPath: String? = nil,
        notify: @escaping @MainActor (String, String) -> Void = { _, _ in }
    ) {
        self.git = git
        self.opener = opener
        self.ops = ops
        self.store = store
        self.activityMonitor = activityMonitor
        self.makeWatcher = makeWatcher
        self.agentStatus = agentStatus
        self.agentProjectsRootPath = agentProjectsRootPath
        self.notify = notify
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
            agentStatus: { path, now in scanner.state(forWorktreePath: path, now: now) },
            agentProjectsRootPath: projectsRoot.path,
            notify: AgentNotifier.post
        )
    }
}
