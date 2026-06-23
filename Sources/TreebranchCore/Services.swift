import Foundation

// MARK: - WorktreeService

/// Discovers and manages a repository's worktrees (TECH_SPEC §2).
public struct WorktreeService: Sendable {
    private let git: GitClient
    public init(git: GitClient) { self.git = git }

    /// All worktrees for `repo`, primary checkout first.
    public func worktrees(for repo: Repository) async throws -> [Worktree] {
        let list = try await git.worktrees(repoPath: repo.path)
        return list.sorted { lhs, rhs in
            if lhs.isPrimary != rhs.isPrimary { return lhs.isPrimary }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    public func addWorktree(in repo: Repository, at path: String, branch: String, createBranch: Bool = true) async throws {
        try await git.addWorktree(repoPath: repo.path, path: path, branch: branch, createBranch: createBranch)
    }

    public func removeWorktree(in repo: Repository, worktree: Worktree, force: Bool = false) async throws {
        try await git.removeWorktree(repoPath: repo.path, worktreePath: worktree.path, force: force)
    }
}

// MARK: - StatusService

/// Working changes + ahead/behind for a worktree (TECH_SPEC §2).
public struct StatusService: Sendable {
    private let git: GitClient
    public init(git: GitClient) { self.git = git }

    public func status(for worktree: Worktree) async throws -> StatusResult {
        try await git.status(worktreePath: worktree.path)
    }

    public func status(worktreePath: String) async throws -> StatusResult {
        try await git.status(worktreePath: worktreePath)
    }

    /// Repo-relative paths git ignores (entire ignored directories collapse to a
    /// single `dir/` entry). Feeds the file tree's "show ignored" toggle.
    public func ignoredPaths(worktreePath: String) async throws -> [String] {
        let result = try await git.run(
            ["status", "--porcelain=v2", "-z", "--ignored", "--untracked-files=no"],
            in: worktreePath
        )
        guard result.succeeded else { return [] }
        return StatusParser.parse(result.stdoutString).changes
            .filter { $0.worktreeStatus == .ignored }
            .map(\.path)
    }
}

// MARK: - DiffService

/// Working-tree diffs for the change peek (TECH_SPEC §2).
public struct DiffService: Sendable {
    private let git: GitClient
    public init(git: GitClient) { self.git = git }

    public func workingDiff(worktreePath: String, path: String, staged: Bool = false) async throws -> DiffFile? {
        try await git.workingDiff(worktreePath: worktreePath, path: path, staged: staged)
    }

    /// Resolve the right diff to peek for a working change: the staged diff when the
    /// change is purely staged, otherwise the unstaged working diff.
    public func diff(for change: FileChange, worktreePath: String) async throws -> DiffFile? {
        let useStaged = change.isStaged && change.worktreeStatus == .unmodified
        return try await git.workingDiff(worktreePath: worktreePath, path: change.path, staged: useStaged)
    }
}

// MARK: - BranchService

/// Lists a repository's branches.
public struct BranchService: Sendable {
    private let git: GitClient
    public init(git: GitClient) { self.git = git }

    public func branches(for repo: Repository) async throws -> [Branch] {
        try await git.branches(repoPath: repo.path)
    }
}
