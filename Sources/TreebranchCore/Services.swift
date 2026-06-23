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

/// name-status + per-file hunks vs base, and working diffs (TECH_SPEC §2).
public struct DiffService: Sendable {
    private let git: GitClient
    public init(git: GitClient) { self.git = git }

    /// Files committed ahead of `base` on the worktree's HEAD.
    public func changedFilesVsBase(worktreePath: String, base: String) async throws -> [NameStatusEntry] {
        try await git.changedFilesVsBase(worktreePath: worktreePath, base: base)
    }

    public func committedDiff(worktreePath: String, base: String, path: String) async throws -> DiffFile? {
        try await git.committedDiff(worktreePath: worktreePath, base: base, path: path)
    }

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

/// Lists branches and resolves a repository's base branch.
public struct BranchService: Sendable {
    private let git: GitClient
    public init(git: GitClient) { self.git = git }

    public func branches(for repo: Repository) async throws -> [Branch] {
        try await git.branches(repoPath: repo.path)
    }

    public func localBranchNames(for repo: Repository) async throws -> [String] {
        try await git.branches(repoPath: repo.path).filter { !$0.isRemote }.map(\.name)
    }

    /// Resolve the effective base branch for `repo`: the configured value if it
    /// exists, otherwise `main` then `master`. Throws `.missingBaseBranch` if none.
    public func resolveBaseBranch(for repo: Repository) async throws -> String {
        let names = try await localBranchNames(for: repo)
        guard let base = TreebranchCore.resolveBaseBranch(configured: repo.baseBranch, availableBranches: names) else {
            throw GitError.missingBaseBranch(repo: repo.path)
        }
        return base
    }

    // MARK: Read-only snapshot browse (D2)

    public func snapshotFiles(for repo: Repository, ref: String) async throws -> [String] {
        try await git.listTree(repoPath: repo.path, ref: ref)
    }

    public func snapshotFileContents(for repo: Repository, ref: String, path: String) async throws -> Data {
        try await git.showFile(repoPath: repo.path, ref: ref, path: path)
    }
}
