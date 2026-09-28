import Foundation
import Testing
@testable import Teebe
import TeebeCore

/// A box the tests flip to make a worktree folder disappear mid-session.
private final class FolderSet: @unchecked Sendable {
    private let lock = NSLock()
    private var missing: Set<String>
    init(missing: Set<String> = []) { self.missing = missing }
    func remove(_ path: String) { lock.lock(); missing.insert(path); lock.unlock() }
    func exists(_ path: String) -> Bool { lock.lock(); defer { lock.unlock() }; return !missing.contains(path) }
}

@MainActor
@Suite("Missing worktree folder")
struct MissingWorktreeTests {
    private let primary = Worktree(path: "/repo", branch: "main", isPrimary: true)
    private let dirty = Worktree(path: "/repo-dirty", branch: "dirty")
    private let gone = Worktree(path: "/repo-gone", branch: "gone")
    private let broken = Worktree(path: "/repo-broken", branch: "broken")

    private func eightChanges() -> StatusResult {
        StatusResult(branch: "dirty", changes: (1...8).map { FileChange(path: "f\($0).txt", worktreeStatus: .modified) })
    }

    private func makeSelector(git: FakeGitClient, folders: FolderSet) async -> SelectorModel {
        git.worktreesResult = [primary, dirty, gone, broken]
        let selector = SelectorModel(environment: makeTestEnvironment(git: git, folderExists: { folders.exists($0) }))
        await selector.selectRepo(Repository(path: "/repo"))
        return selector
    }

    @Test("selecting a missing worktree after a dirty one clears the previous changes and runs no git there")
    func missingAfterDirtyClearsState() async {
        let git = FakeGitClient()
        git.statusResult = eightChanges()
        let folders = FolderSet(missing: [gone.path])
        let selector = await makeSelector(git: git, folders: folders)

        await selector.selectWorktree(dirty)
        #expect(selector.worktree.changeCount == 8)

        let touchedBefore = git.touchedDirectories.count
        await selector.selectWorktree(gone)
        let model = selector.worktree
        #expect(model.worktreePath == gone.path)
        #expect(model.isFolderMissing)
        #expect(model.changes.isEmpty)
        #expect(model.status == nil)
        #expect(model.statusPath == nil)
        #expect(model.root == nil)
        #expect(model.visibleRows.isEmpty)
        #expect(model.errorMessage == nil)
        #expect(!git.touchedDirectories.dropFirst(touchedBefore).contains(gone.path))
    }

    @Test("a failed load replaces the previous worktree's changes instead of keeping them")
    func failedLoadClearsState() async {
        let git = FakeGitClient()
        git.statusResult = eightChanges()
        git.statusErrors[broken.path] = .commandFailed(command: ["git", "status"], exitCode: 128, stderr: "fatal: bad object")
        let selector = await makeSelector(git: git, folders: FolderSet())

        await selector.selectWorktree(dirty)
        #expect(selector.worktree.changeCount == 8)

        await selector.selectWorktree(broken)
        let model = selector.worktree
        #expect(model.changes.isEmpty)
        #expect(model.status == nil)
        #expect(model.statusPath == nil)
        #expect(!model.isFolderMissing)
        #expect(model.errorMessage == "fatal: bad object")
    }

    @Test("selecting a present worktree after a missing one leaves the placeholder state")
    func presentAfterMissing() async {
        let git = FakeGitClient()
        git.statusResult = eightChanges()
        let selector = await makeSelector(git: git, folders: FolderSet(missing: [gone.path]))

        await selector.selectWorktree(gone)
        #expect(selector.worktree.isFolderMissing)
        await selector.selectWorktree(dirty)
        #expect(!selector.worktree.isFolderMissing)
        #expect(selector.worktree.changeCount == 8)
        #expect(selector.worktree.statusPath == dirty.path)
    }

    @Test("a folder that vanishes while selected turns into the placeholder on the next refresh")
    func vanishesWhileSelected() async {
        let git = FakeGitClient()
        git.statusResult = eightChanges()
        let folders = FolderSet()
        let selector = await makeSelector(git: git, folders: folders)
        await selector.selectWorktree(dirty)
        #expect(selector.worktree.changeCount == 8)

        folders.remove(dirty.path)
        let callsBefore = git.statusCallCount
        await selector.worktree.refresh()

        let model = selector.worktree
        #expect(model.isFolderMissing)
        #expect(model.changes.isEmpty)
        #expect(model.status == nil)
        #expect(model.root == nil)
        #expect(model.errorMessage == nil)
        #expect(git.statusCallCount == callsBefore)
    }

    @Test("git reporting a missing working directory also lands in the placeholder, not an error banner")
    func gitReportsMissingDirectory() async {
        let git = FakeGitClient()
        git.statusResult = eightChanges()
        let selector = await makeSelector(git: git, folders: FolderSet())
        await selector.selectWorktree(dirty)

        git.statusErrors[dirty.path] = .workingDirectoryMissing(path: dirty.path)
        await selector.worktree.refresh()

        #expect(selector.worktree.isFolderMissing)
        #expect(selector.worktree.changes.isEmpty)
        #expect(selector.worktree.errorMessage == nil)
    }

    @Test("a missing working directory is never described as git being missing")
    func describeMissingDirectory() {
        let missingFolder = WorktreeModel.describe(GitError.workingDirectoryMissing(path: "/repo-gone"))
        #expect(!missingFolder.localizedCaseInsensitiveContains("git executable"))
        #expect(missingFolder.contains("/repo-gone"))
        #expect(WorktreeModel.describe(GitError.executableNotFound) == "git executable not found.")
    }

    @Test("the placeholder's Forget… asks the worktree list for the prune confirmation")
    func forgetRequest() {
        let app = AppModel(environment: makeTestEnvironment())
        #expect(!app.isForgetMissingRequested)
        app.requestForgetMissing()
        #expect(app.isForgetMissingRequested)
    }
}
