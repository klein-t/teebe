import Foundation
import TreebranchCore

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

    var worktreeService: WorktreeService { WorktreeService(git: git) }
    var statusService: StatusService { StatusService(git: git) }
    var diffService: DiffService { DiffService(git: git) }
    var branchService: BranchService { BranchService(git: git) }

    func makeQueue(repoPath: String) -> RepoGitQueue {
        RepoGitQueue(git: git, repoPath: repoPath)
    }

    static func live() -> AppEnvironment {
        AppEnvironment(
            git: ProcessGitClient(),
            opener: WorkspaceFileOpener(),
            ops: FileManagerFileOps(),
            store: AppStateStore(),
            activityMonitor: WorktreeActivityMonitor(),
            makeWatcher: { FSEventsWatcher() }
        )
    }
}
