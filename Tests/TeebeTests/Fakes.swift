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
    /// Per-worktree `status` failures (keyed by worktree path).
    var statusErrors: [String: GitError] = [:]
    /// Every directory a `status` or `run` call was made in, in order.
    private var gitDirectories: [String] = []
    var touchedDirectories: [String] { statusLock.lock(); defer { statusLock.unlock() }; return gitDirectories }

    var beforeWorktrees: (@Sendable () async -> Void)?
    func worktrees(repoPath: String) async throws -> [Worktree] {
        if let beforeWorktrees { await beforeWorktrees() }
        if let worktreesError { throw worktreesError }
        return worktreesResult
    }
    func branches(repoPath: String) async throws -> [Branch] { branchesResult }
    func status(worktreePath: String) async throws -> StatusResult {
        statusLock.lock(); statusCalls += 1; gitDirectories.append(worktreePath); statusLock.unlock()
        if let statusGate { await statusGate() }
        if let error = statusErrors[worktreePath] { throw error }
        return statusResult
    }
    var workingDiffHandler: (@Sendable (String) async -> DiffFile?)?
    func workingDiff(worktreePath: String, path: String, staged: Bool) async throws -> DiffFile? {
        if let workingDiffHandler { return await workingDiffHandler(path) }
        return workingDiffResult
    }
    func stage(worktreePath: String, paths: [String]) async throws { stagedPaths.append(paths) }
    func unstage(worktreePath: String, paths: [String]) async throws { unstagedPaths.append(paths) }
    func discardWorking(worktreePath: String, paths: [String]) async throws { discardedWorking.append(paths) }
    func discardUntracked(worktreePath: String, paths: [String]) async throws { discardedUntracked.append(paths) }
    func commit(worktreePath: String, message: String) async throws { commitMessages.append(message) }
    struct AddedWorktree: Equatable {
        let path: String
        let branch: String?
        let createBranch: Bool
        let startPoint: String?
    }
    private(set) var addedWorktrees: [AddedWorktree] = []
    /// When set, each add awaits this first, so a test can act while one is in flight.
    var addWorktreeGate: (@Sendable () async -> Void)?
    func addWorktree(repoPath: String, path: String, branch: String?, createBranch: Bool, startPoint: String?) async throws {
        if let addWorktreeGate { await addWorktreeGate() }
        addedWorktrees.append(AddedWorktree(path: path, branch: branch, createBranch: createBranch, startPoint: startPoint))
    }
    /// Every `removeWorktree` call's worktree path, in order.
    private(set) var removedWorktrees: [String] = []
    /// Per-worktree `removeWorktree` failures (keyed by worktree path).
    var removeWorktreeErrors: [String: GitError] = [:]
    func removeWorktree(repoPath: String, worktreePath: String, force: Bool) async throws {
        removedWorktrees.append(worktreePath)
        if let error = removeWorktreeErrors[worktreePath] { throw error }
    }

    // Fetches are recorded under a lock: they are called from detached work
    // while the test reads the record from the main actor.
    private let remoteLock = NSLock()
    private var fetches: [String] = []
    private var kinds: [FetchKind] = []
    var fetchedRepos: [String] { remoteLock.lock(); defer { remoteLock.unlock() }; return fetches }
    var fetchKinds: [FetchKind] { remoteLock.lock(); defer { remoteLock.unlock() }; return kinds }
    /// When set, `fetchOrigin` throws it — a remote that is unreachable.
    var fetchError: GitError?
    /// A remote reachable only with a key held by the SSH agent: automatic
    /// fetches, which leave the agent out, fail.
    var needsAgent = false
    /// When set, each fetch awaits this before returning, so a test can hold one
    /// in flight long enough to watch it time out.
    var fetchGate: (@Sendable () async -> Void)?

    /// Recorded synchronously: locking inside an async function is not allowed.
    private func record(fetch path: String, kind: FetchKind) {
        remoteLock.lock(); fetches.append(path); kinds.append(kind); remoteLock.unlock()
    }

    func fetchOrigin(repoPath: String, kind: FetchKind) async throws {
        record(fetch: repoPath, kind: kind)
        if let fetchGate { await fetchGate() }
        if let fetchError { throw fetchError }
        if needsAgent, kind == .automatic {
            throw GitError.commandFailed(command: ["git", "fetch"], exitCode: 128, stderr: "Permission denied (publickey)")
        }
    }
    /// Scripted stdout for `git rev-parse --git-common-dir` (the repo's git common
    /// dir). When nil, `run` returns empty stdout and callers fall back to `.git`.
    var gitCommonDirOutput: String?
    var showRefOutput = ""
    var showRefExitCode: Int32 = 0
    var runGate: (@Sendable ([String], String) async -> Void)?
    @discardableResult
    func run(_ arguments: [String], in directory: String) async throws -> GitInvocationResult {
        statusLock.lock(); gitDirectories.append(directory); statusLock.unlock()
        if let runGate { await runGate(arguments, directory) }
        var stdout = Data()
        if arguments == ["rev-parse", "--git-common-dir"], let gitCommonDirOutput {
            stdout = Data(gitCommonDirOutput.utf8)
        }
        if arguments == ["show-ref"] { stdout = Data(showRefOutput.utf8) }
        return GitInvocationResult(arguments: arguments, exitCode: arguments == ["show-ref"] ? showRefExitCode : 0, standardOutput: stdout, standardError: "")
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
    /// Each open's app (nil for the default app), parallel to `opened`.
    private(set) var apps: [URL?] = []
    func open(_ url: URL) throws { opened.append(url); apps.append(nil) }
    func open(_ url: URL, withApplicationAt appURL: URL) throws { opened.append(url); apps.append(appURL) }
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

// MARK: - Fake agent ping (darwin notification channel)

/// Records lifecycle and lets a test fire the ping by hand.
final class FakeAgentPing: AgentPingListening, @unchecked Sendable {
    private let lock = NSLock()
    private var _startCount = 0
    private var _stopCount = 0
    private var handler: (@Sendable () -> Void)?

    var startCount: Int { lock.lock(); defer { lock.unlock() }; return _startCount }
    var stopCount: Int { lock.lock(); defer { lock.unlock() }; return _stopCount }

    func start(_ handler: @escaping @Sendable () -> Void) {
        lock.lock(); _startCount += 1; self.handler = handler; lock.unlock()
    }
    func stop() { lock.lock(); _stopCount += 1; handler = nil; lock.unlock() }
    /// Simulate a `notifyutil -p` ping from a Claude Code hook.
    func fire() {
        lock.lock(); let handler = handler; lock.unlock()
        handler?()
    }
}

// MARK: - Fake agent status

/// Scriptable per-worktree agent states for tests; the closure form feeds
/// `AppEnvironment.agentStatuses`.
final class FakeAgentStates: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [String: AgentActivityState] = [:]

    subscript(path: String) -> AgentActivityState? {
        get { lock.lock(); defer { lock.unlock() }; return states[path] }
        set { lock.lock(); states[path] = newValue; lock.unlock() }
    }

    var provider: @Sendable ([String], Date) -> [String: AgentActivityState] {
        { [self] paths, _ in
            Dictionary(uniqueKeysWithValues: paths.map { ($0, self[$0] ?? .idle) })
        }
    }
}

/// Records notifications the models post (delivery happens on the main actor).
final class NotificationSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(title: String, body: String)] = []

    var posted: [(title: String, body: String)] {
        lock.lock(); defer { lock.unlock() }; return recorded
    }

    var record: @MainActor (String, String) -> Void {
        { [self] title, body in
            lock.lock(); recorded.append((title, body)); lock.unlock()
        }
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
    makeWatcher: (@MainActor () -> FileSystemWatcher)? = nil,
    agentStatuses: (@Sendable ([String], Date) -> [String: AgentActivityState])? = nil,
    agentTurnEnds: @escaping @Sendable ([String], Date) -> [AgentTurnEnd] = { _, _ in [] },
    agentProjectsRootPath: String? = nil,
    agentExtraWatchPaths: [String] = [],
    processActivity: (@Sendable ([String], Date) -> Set<String>)? = nil,
    worktreesInUse: @escaping @Sendable ([String], Date) -> Set<String> = { _, _ in [] },
    notify: (@MainActor (String, String) -> Void)? = nil,
    agentPing: AgentPingListening? = nil,
    folderExists: @escaping @Sendable (String) -> Bool = { _ in true },
    /// Defaults to "whatever `folderExists` says isn't there": fake paths are
    /// never on disk, so the real check would read every one as deleted.
    folderIsGone: (@Sendable (String) -> Bool)? = nil,
    isVolumeMounted: @escaping @Sendable (String) -> Bool = { _ in true },
    /// Defaults to nothing held: fake paths have no record on disk to read.
    holdsUnsavedWork: @escaping @Sendable (Worktree, String) async -> Bool = { _, _ in false },
    /// Defaults to picking a fake app, as if the user chose one every time.
    chooseApp: @escaping @MainActor (URL?, String, URL?) -> URL? = { _, _, _ in URL(fileURLWithPath: "/Applications/Editor.app") },
    appExists: @escaping @Sendable (URL) -> Bool = { _ in true }
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
        makeWatcher: makeWatcher ?? { FakeWatcher() },
        agentStatuses: agentStatuses ?? { _, _ in [:] },
        agentTurnEnds: agentTurnEnds,
        agentProjectsRootPath: agentProjectsRootPath,
        agentExtraWatchPaths: agentExtraWatchPaths,
        processActivity: processActivity,
        worktreesInUse: worktreesInUse,
        notify: notify ?? { _, _ in },
        makeAgentPingListener: { agentPing ?? FakeAgentPing() },
        folderExists: folderExists,
        folderIsGone: folderIsGone ?? { !folderExists($0) },
        isVolumeMounted: isVolumeMounted,
        holdsUnsavedWork: holdsUnsavedWork,
        chooseApp: chooseApp,
        appExists: appExists
    )
}
