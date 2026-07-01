import Testing
import Foundation
@testable import Teebe
@testable import TeebeCore

/// End-to-end delete coverage using the *real* `FileManagerFileOps` (not the
/// fake), so a regression in the actual trash + tree-refresh path is caught.
@MainActor
@Suite("Delete integration (real FileManagerFileOps)")
struct DeleteIntegrationTests {
    private func tempDir() -> (String, () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tb-del-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Resolve /var → /private/var so paths match the tree builder's realpath form.
        let resolved = PathUtil.standardized(dir.path)
        return (resolved, { try? FileManager.default.removeItem(at: dir) })
    }

    private func realOpsEnvironment(git: FakeGitClient = FakeGitClient()) -> AppEnvironment {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tb-del-store-\(UUID().uuidString)")
            .appendingPathComponent("state.json")
        return AppEnvironment(
            git: git,
            opener: FakeFileOpener(),
            ops: FileManagerFileOps(),
            store: AppStateStore(url: storeURL),
            activityMonitor: WorktreeActivityMonitor(),
            makeWatcher: { FakeWatcher() }
        )
    }

    @Test("trashing a selected file removes it from disk and the tree")
    func trashRemovesFromTreeAndDisk() async throws {
        let (dir, cleanup) = tempDir(); defer { cleanup() }
        let fileURL = URL(fileURLWithPath: dir).appendingPathComponent("a.txt")
        try "hello".write(to: fileURL, atomically: true, encoding: .utf8)

        let model = WorktreeModel(environment: realOpsEnvironment())
        await model.load(worktreePath: dir, repo: Repository(path: dir))

        // Sanity: the file shows in the tree before delete.
        #expect(model.visibleRows.contains { $0.node.path == fileURL.path })

        model.select(fileURL.path)
        model.requestTrashSelected()
        #expect(model.pendingMutation?.kind == .trash)

        await model.confirmPendingMutation()

        #expect(model.errorMessage == nil)
        #expect(FileManager.default.fileExists(atPath: fileURL.path) == false)
        #expect(model.visibleRows.contains { $0.node.path == fileURL.path } == false)
    }

    /// Reproduces the SwiftUI confirmation-dialog ordering: tapping "Confirm" defers
    /// the delete into a `Task`, but the dialog's own dismissal synchronously drives
    /// `isPresented` to false, which cancels the pending mutation *before* the task
    /// runs. The file must still be trashed.
    @Test("confirm survives the dialog's synchronous dismissal (does not no-op)")
    func confirmRaceWithDismissal() async throws {
        let (dir, cleanup) = tempDir(); defer { cleanup() }
        let fileURL = URL(fileURLWithPath: dir).appendingPathComponent("race.txt")
        try "x".write(to: fileURL, atomically: true, encoding: .utf8)

        let model = WorktreeModel(environment: realOpsEnvironment())
        await model.load(worktreePath: dir, repo: Repository(path: dir))

        model.requestTrash(path: fileURL.path)
        // Mimic the confirmationDialog "Confirm" button: capture the mutation
        // synchronously, schedule the async work in a Task (which does not run
        // synchronously), then let the dialog's dismissal write isPresented=false →
        // cancelPendingMutation() runs first, on this same turn.
        guard let mutation = model.pendingMutation else { Issue.record("no pending mutation"); return }
        let confirm = Task { await model.confirm(mutation) }
        model.cancelPendingMutation()   // dialog dismissal (synchronous)
        await confirm.value

        #expect(model.errorMessage == nil)
        #expect(FileManager.default.fileExists(atPath: fileURL.path) == false)
    }

    /// The model-level invariant behind the fix: a captured mutation still executes
    /// even after `pendingMutation` has been cleared (as the dialog does on dismiss).
    @Test("confirm(_:) executes a captured mutation after pendingMutation is cleared")
    func confirmCapturedAfterClear() async throws {
        let (dir, cleanup) = tempDir(); defer { cleanup() }
        let fileURL = URL(fileURLWithPath: dir).appendingPathComponent("captured.txt")
        try "x".write(to: fileURL, atomically: true, encoding: .utf8)

        let model = WorktreeModel(environment: realOpsEnvironment())
        await model.load(worktreePath: dir, repo: Repository(path: dir))

        model.requestTrash(path: fileURL.path)
        guard let mutation = model.pendingMutation else { Issue.record("no pending mutation"); return }
        model.cancelPendingMutation()   // dialog clears the presentation flag
        await model.confirm(mutation)   // captured mutation still runs

        #expect(FileManager.default.fileExists(atPath: fileURL.path) == false)
    }

    @Test("context-menu trash of a single file removes it from disk and the tree")
    func contextMenuTrash() async throws {
        let (dir, cleanup) = tempDir(); defer { cleanup() }
        let fileURL = URL(fileURLWithPath: dir).appendingPathComponent("b.txt")
        try "bye".write(to: fileURL, atomically: true, encoding: .utf8)

        let model = WorktreeModel(environment: realOpsEnvironment())
        await model.load(worktreePath: dir, repo: Repository(path: dir))
        #expect(model.visibleRows.contains { $0.node.path == fileURL.path })

        model.requestTrash(path: fileURL.path)
        await model.confirmPendingMutation()

        #expect(model.errorMessage == nil)
        #expect(FileManager.default.fileExists(atPath: fileURL.path) == false)
        #expect(model.visibleRows.contains { $0.node.path == fileURL.path } == false)
    }
}
