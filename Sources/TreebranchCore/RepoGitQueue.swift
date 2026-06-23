import Foundation

/// Serializes git *writes* for a single repository (TECH_SPEC §6, D3) so treebranch
/// never races an agent's git. Operations are chained through a serial task tail —
/// actor isolation alone is insufficient because the actor yields its executor at
/// every `await`, which would let the underlying `git` invocations interleave and
/// contend on `index.lock`. Lock contention is retried with bounded backoff.
public actor RepoGitQueue {
    private let git: GitClient
    public let repoPath: String
    private let maxLockRetries: Int
    private let lockBackoff: TimeInterval
    /// Tail of the serial execution chain; each new op awaits its predecessor.
    private var tail: Task<Void, Error>?

    public init(git: GitClient, repoPath: String, maxLockRetries: Int = 5, lockBackoff: TimeInterval = 0.1) {
        self.git = git
        self.repoPath = repoPath
        self.maxLockRetries = maxLockRetries
        self.lockBackoff = lockBackoff
    }

    public func stage(worktreePath: String, paths: [String]) async throws {
        try await run { try await self.git.stage(worktreePath: worktreePath, paths: paths) }
    }

    public func unstage(worktreePath: String, paths: [String]) async throws {
        try await run { try await self.git.unstage(worktreePath: worktreePath, paths: paths) }
    }

    public func discardWorking(worktreePath: String, paths: [String]) async throws {
        try await run { try await self.git.discardWorking(worktreePath: worktreePath, paths: paths) }
    }

    public func discardUntracked(worktreePath: String, paths: [String]) async throws {
        try await run { try await self.git.discardUntracked(worktreePath: worktreePath, paths: paths) }
    }

    public func commit(worktreePath: String, message: String) async throws {
        try await run { try await self.git.commit(worktreePath: worktreePath, message: message) }
    }

    public func checkout(worktreePath: String, branch: String) async throws {
        try await run { try await self.git.checkout(worktreePath: worktreePath, branch: branch) }
    }

    public func addWorktree(path: String, branch: String?, createBranch: Bool) async throws {
        try await run {
            try await self.git.addWorktree(repoPath: self.repoPath, path: path, branch: branch, createBranch: createBranch)
        }
    }

    public func removeWorktree(worktreePath: String, force: Bool) async throws {
        try await run {
            try await self.git.removeWorktree(repoPath: self.repoPath, worktreePath: worktreePath, force: force)
        }
    }

    /// Append `operation` to the serial chain: it runs only after the previous
    /// operation completes, guaranteeing one git write at a time.
    private func run(_ operation: @escaping @Sendable () async throws -> Void) async throws {
        let predecessor = tail
        let retries = maxLockRetries
        let backoff = lockBackoff
        let task = Task<Void, Error> {
            if let predecessor { _ = try? await predecessor.value }
            try await Self.withLockRetry(maxRetries: retries, backoff: backoff, operation)
        }
        tail = task
        try await task.value
    }

    /// Run `operation`, retrying with backoff while git reports a locked index.
    private static func withLockRetry(
        maxRetries: Int,
        backoff: TimeInterval,
        _ operation: @Sendable () async throws -> Void
    ) async throws {
        var attempt = 0
        while true {
            do {
                try await operation()
                return
            } catch let error as GitError {
                guard case .lockedIndex = error, attempt < maxRetries else { throw error }
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            }
        }
    }
}

/// Tracks recent write activity per worktree so guarded operations (checkout,
/// discard) can warn when a worktree is "busy" — i.e. an agent wrote to it within
/// the last N seconds (PRD §9). Dates are injected for deterministic testing.
public final class WorktreeActivityMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var lastActivity: [String: Date] = [:]

    public init() {}

    /// Record that `worktreePath` was written to at `date`.
    public func recordActivity(worktreePath: String, at date: Date) {
        let key = PathUtil.standardized(worktreePath)
        lock.lock(); lastActivity[key] = date; lock.unlock()
    }

    public func lastActivity(forWorktreePath path: String) -> Date? {
        let key = PathUtil.standardized(path)
        lock.lock(); defer { lock.unlock() }
        return lastActivity[key]
    }

    /// Whether `worktreePath` saw a write within `window` seconds before `now`.
    public func isBusy(worktreePath: String, within window: TimeInterval, now: Date) -> Bool {
        guard let last = lastActivity(forWorktreePath: worktreePath) else { return false }
        return now.timeIntervalSince(last) < window
    }
}
