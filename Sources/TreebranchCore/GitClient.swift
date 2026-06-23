import Foundation

// MARK: - Low-level invocation result

/// The raw result of one `git` invocation.
public struct GitInvocationResult: Equatable, Sendable {
    public var arguments: [String]
    public var exitCode: Int32
    public var standardOutput: Data
    public var standardError: String

    public init(arguments: [String], exitCode: Int32, standardOutput: Data, standardError: String) {
        self.arguments = arguments
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    /// stdout decoded as UTF-8 (lossy-safe via `decoding:`).
    public var stdoutString: String { String(decoding: standardOutput, as: UTF8.self) }
    public var succeeded: Bool { exitCode == 0 }
}

// MARK: - Errors

public enum GitError: Error, Sendable, Equatable {
    /// A `git` command exited non-zero.
    case commandFailed(command: [String], exitCode: Int32, stderr: String)
    /// The directory is not inside a git repository.
    case notAGitRepository(path: String)
    /// `index.lock` is held and did not clear within the retry budget.
    case lockedIndex(path: String)
    /// No base branch could be resolved for the repo.
    case missingBaseBranch(repo: String)
    /// The worktree was recently written by an agent; a guarded op refused.
    case worktreeBusy(path: String)
    /// `git` executable could not be located.
    case executableNotFound
    /// Output could not be decoded/parsed into the expected shape.
    case decodingFailed(String)
}

// MARK: - Status result

/// The outcome of `git status --porcelain=v2 --branch`: the current branch /
/// upstream, ahead/behind counts, and the per-file change list.
public struct StatusResult: Equatable, Sendable {
    public var branch: String?
    public var upstream: String?
    public var ahead: Int
    public var behind: Int
    public var isDetached: Bool
    public var oid: String?
    public var changes: [FileChange]

    public init(
        branch: String? = nil,
        upstream: String? = nil,
        ahead: Int = 0,
        behind: Int = 0,
        isDetached: Bool = false,
        oid: String? = nil,
        changes: [FileChange] = []
    ) {
        self.branch = branch
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.isDetached = isDetached
        self.oid = oid
        self.changes = changes
    }
}

/// A `git diff --name-status` entry (status letter + path, plus source for R/C).
public struct NameStatusEntry: Equatable, Hashable, Sendable {
    public var status: ChangeStatus
    public var path: String
    public var originalPath: String?

    public init(status: ChangeStatus, path: String, originalPath: String? = nil) {
        self.status = status
        self.path = path
        self.originalPath = originalPath
    }
}

// MARK: - GitClient protocol

/// Typed, async access to git. `ProcessGitClient` implements it by shelling out to
/// the system `git`; `FakeGitClient` provides scripted results for tests.
///
/// Write methods (`stage`/`unstage`/`discard*`/`commit`/`checkout`/worktree
/// management) MUST be serialized per repo by the caller (see `RepoGitQueue`).
public protocol GitClient: Sendable {
    // Discovery
    func worktrees(repoPath: String) async throws -> [Worktree]
    func branches(repoPath: String) async throws -> [Branch]

    // Status & changes
    func status(worktreePath: String) async throws -> StatusResult
    func changedFilesVsBase(worktreePath: String, base: String) async throws -> [NameStatusEntry]

    // Diffs
    func committedDiff(worktreePath: String, base: String, path: String) async throws -> DiffFile?
    func workingDiff(worktreePath: String, path: String, staged: Bool) async throws -> DiffFile?

    // Branch snapshot browse (read-only, no checkout)
    func listTree(repoPath: String, ref: String) async throws -> [String]
    func showFile(repoPath: String, ref: String, path: String) async throws -> Data

    // Writes (serialize per repo)
    func stage(worktreePath: String, paths: [String]) async throws
    func unstage(worktreePath: String, paths: [String]) async throws
    func discardWorking(worktreePath: String, paths: [String]) async throws
    func discardUntracked(worktreePath: String, paths: [String]) async throws
    func commit(worktreePath: String, message: String) async throws
    func checkout(worktreePath: String, branch: String) async throws

    // Worktree management
    func addWorktree(repoPath: String, path: String, branch: String?, createBranch: Bool) async throws
    func removeWorktree(repoPath: String, worktreePath: String, force: Bool) async throws

    // Low-level escape hatch
    @discardableResult
    func run(_ arguments: [String], in directory: String) async throws -> GitInvocationResult
}
