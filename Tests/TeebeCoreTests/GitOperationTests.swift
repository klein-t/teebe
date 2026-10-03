import Foundation
import Testing
@testable import TeebeCore

/// A checkout left in the middle of a rebase, merge, cherry-pick, revert or
/// bisect holds the state needed to continue or abort it: it is never removed.
@Suite("Unfinished Git operations")
struct GitOperationTests {
    @Test("each operation is recognised from the checkout's own git directory")
    func detection() {
        func detect(_ present: Set<String>, todo: String? = nil) -> GitOperation? {
            GitOperation.detect(exists: { present.contains($0) }, sequencerTodo: { todo })
        }
        #expect(detect([]) == nil)
        #expect(detect(["rebase-merge"]) == .rebase)
        #expect(detect(["rebase-apply"]) == .rebase)
        #expect(detect(["rebase-apply", "rebase-apply/applying"]) == .applyingPatches)
        #expect(detect(["MERGE_HEAD"]) == .merge)
        #expect(detect(["CHERRY_PICK_HEAD"]) == .cherryPick)
        #expect(detect(["REVERT_HEAD"]) == .revert)
        #expect(detect(["BISECT_LOG"]) == .bisect)
        #expect(detect(["sequencer"], todo: "pick abc one\npick def two\n") == .cherryPick)
        #expect(detect(["sequencer"], todo: "revert abc one\n") == .revert)
        // A rebase outranks the bisect it may have been started from.
        #expect(detect(["rebase-merge", "BISECT_LOG"]) == .rebase)
    }

    /// A merged, clean worktree: nothing but the operation stands in its way.
    private func mergedWorktree(_ fixture: GitFixture) -> URL {
        fixture.commitFile("a.txt", "base")
        let folder = fixture.addWorktree(name: "feature", branch: "feature")
        fixture.commitAndFastForward(branch: "feature", in: folder)
        return folder
    }

    private func entry(_ fixture: GitFixture, _ service: WorktreeCleanupService) async throws -> CleanupEntry {
        try #require(try await service.scan(repoPath: fixture.repoPath, extraTarget: nil)
            .entries.first { $0.worktree.branch == "feature" })
    }

    @Test("a merged worktree with a merge in progress and a clean index is never removable")
    func mergeInProgress() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        let folder = mergedWorktree(fixture)
        fixture.git(["switch", "-q", "-c", "other"])
        fixture.commitFile("o.txt", "other work")
        fixture.git(["switch", "-q", "main"])
        // `-s ours` records MERGE_HEAD without touching the index: nothing to commit shows.
        fixture.git(["merge", "-q", "-s", "ours", "--no-commit", "other"], in: folder)
        let service = WorktreeCleanupService(git: ProcessGitClient())
        let merging = try await entry(fixture, service)
        #expect(merging.operation == .merge)
        #expect(!merging.hasLocalChanges)
        #expect(merging.mergeStatus == .merged)
        #expect(!merging.canRemove(includingIgnored: true))
        #expect(!merging.canRemoveFolder(includingIgnored: true))
        await #expect(throws: CleanupError.unsafe) {
            try await service.remove(repoPath: fixture.repoPath, entry: merging, includingIgnored: true, deleteBranch: false)
        }
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path))
    }

    @Test("an operation started after the check is caught again when removing")
    func recheckedAtRemoval() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        let folder = mergedWorktree(fixture)
        let service = WorktreeCleanupService(git: ProcessGitClient())
        let reviewed = try await entry(fixture, service)
        #expect(reviewed.operation == nil)
        #expect(reviewed.canRemove(includingIgnored: true))
        fixture.git(["bisect", "start"], in: folder)
        await #expect(throws: CleanupError.unsafe) {
            try await service.remove(repoPath: fixture.repoPath, entry: reviewed, includingIgnored: true, deleteBranch: true)
        }
        #expect(FileManager.default.fileExists(atPath: folder.path))
        #expect(try await entry(fixture, service).operation == .bisect)
    }

    @Test("a clean worktree stopped mid-rebase is refused")
    func rebaseInProgress() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        let folder = mergedWorktree(fixture)
        // Replays the last commit, then stops on the failing exec with a clean index.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-c", "core.editor=true", "rebase", "--exec", "false", "HEAD~1"]
        process.currentDirectoryURL = folder
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let service = WorktreeCleanupService(git: ProcessGitClient())
        let rebasing = try #require(try await service.scan(repoPath: fixture.repoPath, extraTarget: nil)
            .entries.first { PathUtil.standardized($0.id) == PathUtil.standardized(folder.path) })
        #expect(rebasing.operation == .rebase)
        #expect(!rebasing.hasLocalChanges)
        #expect(!rebasing.canRemoveFolder(includingIgnored: true))
        await #expect(throws: CleanupError.unsafe) {
            try await service.remove(repoPath: fixture.repoPath, entry: rebasing, includingIgnored: true, deleteBranch: false)
        }
        #expect(FileManager.default.fileExists(atPath: folder.path))
    }
}
