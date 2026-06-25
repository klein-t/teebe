import Foundation
@testable import Teebe
import TeebeCore

// MARK: - Fake GitClient

final class FakeGitClient: GitClient, @unchecked Sendable {
    var worktreesResult: [Worktree] = []
    var branchesResult: [Branch] = []
    var statusResult = StatusResult()
    var workingDiffResult: DiffFile?
    var worktreesError: GitError?

    private(set) var stagedPaths: [[String]] = []
    private(set) var unstagedPaths: [[String]] = []
    private(set) var discardedWorking: [[String]] = []
    private(set) var discardedUntracked: [[String]] = []
    private(set) var commitMessages: [String] = []

    // Instrumentation for refresh tests. The counter is lock-guarded because
    // `refreshWorktreeInfo` now fetches statuses concurrently.
    private let statusLock = NSLock()
    private var statusCalls = 0
    var statusCallCount: Int { statusLock.lock(); defer { statusLock.unlock() }; return statusCalls }
    /// When set, each `status` call awaits this before returning — lets a test hold a
    /// refresh "in flight" to exercise coalescing of watcher events.
    var statusGate: (@Sendable () async -> Void)?

    func worktrees(repoPath: String) async throws -> [Worktree] {
        if let worktreesError { throw worktreesError }
        return worktreesResult
    }
    func branches(repoPath: String) async throws -> [Branch] { branchesResult }
    func status(worktreePath: String) async throws -> StatusResult {
        statusLock.lock(); statusCalls += 1; statusLock.unlock()
        if let statusGate { await statusGate() }
        return statusResult
    }
    func workingDiff(worktreePath: String, path: String, staged: Bool) async throws -> DiffFile? { workingDiffResult }
    func stage(worktreePath: String, paths: [String]) async throws { stagedPaths.append(paths) }
    func unstage(worktreePath: String, paths: [String]) async throws { unstagedPaths.append(paths) }
    func discardWorking(worktreePath: String, paths: [String]) async throws { discardedWorking.append(paths) }
    func discardUntracked(worktreePath: String, paths: [String]) async throws { discardedUntracked.append(paths) }
    func commit(worktreePath: String, message: String) async throws { commitMessages.append(message) }
    func addWorktree(repoPath: String, path: String, branch: String?, createBranch: Bool) async throws {}
    func removeWorktree(repoPath: String, worktreePath: String, force: Bool) async throws {}
    /// Scripted stdout for `git rev-parse --git-common-dir` (the repo's git common
    /// dir). When nil, `run` returns empty stdout and callers fall back to `.git`.
    var gitCommonDirOutput: String?
    @discardableResult
    func run(_ arguments: [String], in directory: String) async throws -> GitInvocationResult {
        var stdout = Data()
        if arguments == ["rev-parse", "--git-common-dir"], let gitCommonDirOutput {
            stdout = Data(gitCommonDirOutput.utf8)
        }
        return GitInvocationResult(arguments: arguments, exitCode: 0, standardOutput: stdout, standardError: "")
    }
}

/// A one-shot async gate: `wait()` suspends until `open()` is called, after which it
/// returns immediately. Lets a test hold a faked `git status` in flight while it
/// fires further events.
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let resume = waiters
        waiters.removeAll()
        for continuation in resume { continuation.resume() }
    }
}

// MARK: - Fake FileOpener / FileOps / Watcher

final class FakeFileOpener: FileOpener, @unchecked Sendable {
    private(set) var opened: [URL] = []
    private(set) var revealed: [URL] = []
    func open(_ url: URL) throws { opened.append(url) }
    func open(_ url: URL, withApplicationAt appURL: URL) throws {}
    func reveal(_ url: URL) { revealed.append(url) }
}

final class FakeFileOps: FileOps, @unchecked Sendable {
    private(set) var trashed: [URL] = []
    func rename(at url: URL, to newName: String) throws -> URL { url }
    func duplicate(at url: URL) throws -> URL { url }
    func createFile(in directory: URL, named name: String) throws -> URL { directory.appendingPathComponent(name) }
    func createDirectory(in directory: URL, named name: String) throws -> URL { directory.appendingPathComponent(name) }
    func moveToTrash(_ url: URL) throws -> URL? { trashed.append(url); return nil }
}

final class FakeWatcher: FileSystemWatcher, @unchecked Sendable {
    private(set) var isWatching = false
    private(set) var watchedPaths: [String] = []
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var handler: (@Sendable ([String]) -> Void)?

    func start(paths: [String], debounce: TimeInterval, onChange: @escaping @Sendable ([String]) -> Void) {
        isWatching = true
        watchedPaths = paths
        startCount += 1
        handler = onChange
    }

    func stop() {
        isWatching = false
        stopCount += 1
        handler = nil
    }

    /// Simulate a coalesced FSEvents change batch.
    func fire(_ paths: [String]) { handler?(paths) }
}

/// Hands out and records every `FakeWatcher` the test environment creates, so a test
/// can grab a specific one (e.g. the repo `.git` watcher) and fire events at it.
@MainActor
final class WatcherBox {
    private(set) var watchers: [FakeWatcher] = []
    func make() -> FakeWatcher { let watcher = FakeWatcher(); watchers.append(watcher); return watcher }
    /// The most recently started watcher whose watched paths contain `needle`.
    func watching(_ needle: String) -> FakeWatcher? {
        watchers.last { $0.watchedPaths.contains { $0.contains(needle) } }
    }
}

// MARK: - Test environment

@MainActor
func makeTestEnvironment(
    git: FakeGitClient = FakeGitClient(),
    opener: FakeFileOpener = FakeFileOpener(),
    ops: FakeFileOps = FakeFileOps(),
    store: AppStateStore? = nil,
    monitor: WorktreeActivityMonitor = WorktreeActivityMonitor(),
    makeWatcher: (@MainActor () -> FileSystemWatcher)? = nil
) -> AppEnvironment {
    let storeURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("tb-test-\(UUID().uuidString)")
        .appendingPathComponent("state.json")
    return AppEnvironment(
        git: git,
        opener: opener,
        ops: ops,
        store: store ?? AppStateStore(url: storeURL),
        activityMonitor: monitor,
        makeWatcher: makeWatcher ?? { FakeWatcher() }
    )
}
