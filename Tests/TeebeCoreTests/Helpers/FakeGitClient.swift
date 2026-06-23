import Foundation
@testable import TeebeCore

/// Hand-written `GitClient` fake: returns scripted results and records mutating
/// calls. Single-threaded test use only.
final class FakeGitClient: GitClient, @unchecked Sendable {
    // Scripted results
    var worktreesResult: [Worktree] = []
    var branchesResult: [Branch] = []
    var statusResult = StatusResult()
    var workingDiffResult: DiffFile?
    /// If set, the next call throws this error.
    var errorToThrow: GitError?
    /// Number of times the next write should throw `.lockedIndex` before succeeding
    /// (used to exercise RepoGitQueue's retry/backoff).
    var lockFailuresBeforeSuccess = 0

    // Recorded calls
    private(set) var stagedPaths: [[String]] = []
    private(set) var unstagedPaths: [[String]] = []
    private(set) var discardedWorking: [[String]] = []
    private(set) var discardedUntracked: [[String]] = []
    private(set) var commitMessages: [String] = []
    private(set) var addedWorktrees: [(path: String, branch: String?, createBranch: Bool)] = []
    private(set) var removedWorktrees: [(path: String, force: Bool)] = []
    private(set) var runInvocations: [[String]] = []
    private(set) var workingDiffStagedFlags: [Bool] = []

    private func throwIfNeeded() throws {
        if let error = errorToThrow { errorToThrow = nil; throw error }
    }

    private func throwLockIfNeeded() throws {
        if lockFailuresBeforeSuccess > 0 {
            lockFailuresBeforeSuccess -= 1
            throw GitError.lockedIndex(path: "fake")
        }
    }

    func worktrees(repoPath: String) async throws -> [Worktree] { try throwIfNeeded(); return worktreesResult }
    func branches(repoPath: String) async throws -> [Branch] { try throwIfNeeded(); return branchesResult }
    func status(worktreePath: String) async throws -> StatusResult { try throwIfNeeded(); return statusResult }

    func workingDiff(worktreePath: String, path: String, staged: Bool) async throws -> DiffFile? {
        try throwIfNeeded(); workingDiffStagedFlags.append(staged); return workingDiffResult
    }

    func stage(worktreePath: String, paths: [String]) async throws { try throwLockIfNeeded(); try throwIfNeeded(); stagedPaths.append(paths) }
    func unstage(worktreePath: String, paths: [String]) async throws { try throwLockIfNeeded(); try throwIfNeeded(); unstagedPaths.append(paths) }
    func discardWorking(worktreePath: String, paths: [String]) async throws { try throwLockIfNeeded(); try throwIfNeeded(); discardedWorking.append(paths) }
    func discardUntracked(worktreePath: String, paths: [String]) async throws { try throwLockIfNeeded(); try throwIfNeeded(); discardedUntracked.append(paths) }
    func commit(worktreePath: String, message: String) async throws { try throwLockIfNeeded(); try throwIfNeeded(); commitMessages.append(message) }

    func addWorktree(repoPath: String, path: String, branch: String?, createBranch: Bool) async throws {
        try throwIfNeeded(); addedWorktrees.append((path, branch, createBranch))
    }
    func removeWorktree(repoPath: String, worktreePath: String, force: Bool) async throws {
        try throwIfNeeded(); removedWorktrees.append((worktreePath, force))
    }

    @discardableResult
    func run(_ arguments: [String], in directory: String) async throws -> GitInvocationResult {
        try throwIfNeeded()
        runInvocations.append(arguments)
        return GitInvocationResult(arguments: arguments, exitCode: 0, standardOutput: Data(), standardError: "")
    }
}
