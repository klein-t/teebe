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

    func worktrees(repoPath: String) async throws -> [Worktree] {
        if let worktreesError { throw worktreesError }
        return worktreesResult
    }
    func branches(repoPath: String) async throws -> [Branch] { branchesResult }
    func status(worktreePath: String) async throws -> StatusResult { statusResult }
    func workingDiff(worktreePath: String, path: String, staged: Bool) async throws -> DiffFile? { workingDiffResult }
    func stage(worktreePath: String, paths: [String]) async throws { stagedPaths.append(paths) }
    func unstage(worktreePath: String, paths: [String]) async throws { unstagedPaths.append(paths) }
    func discardWorking(worktreePath: String, paths: [String]) async throws { discardedWorking.append(paths) }
    func discardUntracked(worktreePath: String, paths: [String]) async throws { discardedUntracked.append(paths) }
    func commit(worktreePath: String, message: String) async throws { commitMessages.append(message) }
    func addWorktree(repoPath: String, path: String, branch: String?, createBranch: Bool) async throws {}
    func removeWorktree(repoPath: String, worktreePath: String, force: Bool) async throws {}
    @discardableResult
    func run(_ arguments: [String], in directory: String) async throws -> GitInvocationResult {
        GitInvocationResult(arguments: arguments, exitCode: 0, standardOutput: Data(), standardError: "")
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
    func start(paths: [String], debounce: TimeInterval, onChange: @escaping @Sendable ([String]) -> Void) { isWatching = true }
    func stop() { isWatching = false }
}

// MARK: - Test environment

@MainActor
func makeTestEnvironment(
    git: FakeGitClient = FakeGitClient(),
    opener: FakeFileOpener = FakeFileOpener(),
    ops: FakeFileOps = FakeFileOps(),
    store: AppStateStore? = nil,
    monitor: WorktreeActivityMonitor = WorktreeActivityMonitor()
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
        makeWatcher: { FakeWatcher() }
    )
}
