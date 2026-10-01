import Foundation
import Testing
@testable import Teebe
@testable import TeebeCore

@MainActor
@Suite("Mutation ownership")
struct MutationOwnershipTests {
    @Test("captured destructive confirmations do not survive a new load", arguments: [false, true], [false, true])
    func capturedMutationAfterLoad(samePath: Bool, untracked: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let git = FakeGitClient()
        let model = WorktreeModel(environment: makeTestEnvironment(git: git))
        await model.load(worktreePath: first.path, repo: Repository(path: root.path))
        model.requestDiscard(FileChange(path: "same.txt", worktreeStatus: untracked ? .untracked : .modified))
        let mutation = try #require(model.pendingMutation)
        await model.load(worktreePath: samePath ? first.path : second.path, repo: Repository(path: root.path))
        #expect(model.pendingMutation == nil)
        await model.confirm(mutation)
        #expect(git.discardedWorking.isEmpty)
        #expect(git.discardedUntracked.isEmpty)
    }

    @Test("clearing and reloading does not revive a captured trash confirmation", arguments: [false, true])
    func capturedTrashAfterClear(reload: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ops = FakeFileOps()
        let model = WorktreeModel(environment: makeTestEnvironment(ops: ops))
        await model.load(worktreePath: root.path, repo: Repository(path: root.path))
        model.requestTrash(path: root.appendingPathComponent("same.txt").path)
        let mutation = try #require(model.pendingMutation)
        // Queue exactly as the Confirm button does, then clear synchronously.
        let confirmation = Task { await model.confirm(mutation) }
        model.clear()
        if reload { await model.load(worktreePath: root.path, repo: Repository(path: root.path)) }
        await confirmation.value
        #expect(ops.trashed.isEmpty)
        #expect(model.pendingMutation == nil)
    }

    @Test("cancelling an uncaptured confirmation keeps files unchanged")
    func cancellationKeepsFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let git = FakeGitClient()
        let model = WorktreeModel(environment: makeTestEnvironment(git: git))
        await model.load(worktreePath: root.path, repo: Repository(path: root.path))
        model.requestDiscard(FileChange(path: "same.txt", worktreeStatus: .modified))
        model.cancelPendingMutation()
        await model.confirmPendingMutation()
        #expect(git.discardedWorking.isEmpty)
    }

    @Test("stale displayed rows cannot mutate files or the index during a load", arguments: ["modified", "untracked", "trash", "stage", "unstage"])
    func staleRowsDuringLoad(kind: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let git = FakeGitClient()
        let ops = FakeFileOps()
        let change = FileChange(path: "same.txt", worktreeStatus: kind == "untracked" ? .untracked : .modified)
        git.statusResult = StatusResult(changes: [change])
        let model = WorktreeModel(environment: makeTestEnvironment(git: git, ops: ops))
        await model.load(worktreePath: first.path, repo: Repository(path: root.path))
        let entered = Gate()
        let release = Gate()
        git.statusGate = {
            if git.statusCallCount == 2 { await entered.open(); await release.wait() }
        }
        let loading = Task { await model.load(worktreePath: second.path, repo: Repository(path: root.path)) }
        await entered.wait()
        #expect(model.isLoading)
        #expect(model.statusPath == first.path)
        switch kind {
        case "trash": model.requestTrash(path: first.appendingPathComponent("same.txt").path)
        case "stage": await model.stage(change)
        case "unstage": await model.unstage(change)
        default: model.requestDiscard(change)
        }
        let mutation = model.pendingMutation
        #expect(mutation == nil)
        await release.open()
        await loading.value
        if let mutation { await model.confirm(mutation) }
        #expect(git.discardedWorking.isEmpty)
        #expect(git.discardedUntracked.isEmpty)
        #expect(ops.trashed.isEmpty)
        #expect(git.stagedPaths.isEmpty)
        #expect(git.unstagedPaths.isEmpty)
    }

    @Test("a failed or cancelled new status read rejects old file and index mutations", arguments: [false, true])
    func failedLoadRejectsOldDiscard(cancelled: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let git = FakeGitClient()
        let change = FileChange(path: "same.txt", worktreeStatus: .modified)
        git.statusResult = StatusResult(changes: [change])
        let model = WorktreeModel(environment: makeTestEnvironment(git: git))
        await model.load(worktreePath: first.path, repo: Repository(path: root.path))
        if cancelled { git.statusGate = { throw CancellationError() } } else {
            git.statusErrors[second.path] = .notAGitRepository(path: second.path)
        }
        await model.load(worktreePath: second.path, repo: Repository(path: root.path))
        #expect(!model.isLoading)
        #expect(model.changes.isEmpty)
        #expect(model.statusPath == nil)
        model.requestDiscard(change)
        #expect(model.pendingMutation == nil)
        model.requestTrash(path: first.appendingPathComponent("same.txt").path)
        #expect(model.pendingMutation == nil)
        await model.confirmPendingMutation()
        await model.stage(change)
        await model.unstage(change)
        #expect(git.discardedWorking.isEmpty)
        #expect(git.stagedPaths.isEmpty)
        #expect(git.unstagedPaths.isEmpty)
    }
}
