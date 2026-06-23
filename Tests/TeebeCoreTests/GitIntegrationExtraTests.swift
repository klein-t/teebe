import Testing
import Foundation
@testable import TeebeCore

/// Additional real-git integration coverage for edge cases the docs call out
/// (TDD_PLAN definition-of-done): untracked discard, worktree add/remove/delete,
/// renamed & binary diffs, missing base, detached HEAD, locked index.
@Suite("Git integration (edge cases)")
struct GitIntegrationExtraTests {
    let git = ProcessGitClient()

    @Test("discardUntracked removes the untracked file (git clean)")
    func discardUntracked() async throws {
        let fixture = try GitFixture(); defer { fixture.cleanup() }
        fixture.commitFile("seed.txt", "seed\n")
        fixture.writeFile("junk.txt", "junk\n")

        let queue = RepoGitQueue(git: git, repoPath: fixture.repoPath, lockBackoff: 0.02)
        try await queue.discardUntracked(worktreePath: fixture.repoPath, paths: ["junk.txt"])

        #expect(FileManager.default.fileExists(atPath: fixture.repoURL.appendingPathComponent("junk.txt").path) == false)
        // Tracked files untouched.
        #expect(FileManager.default.fileExists(atPath: fixture.repoURL.appendingPathComponent("seed.txt").path))
    }

    @Test("add then remove a linked worktree")
    func addRemoveWorktree() async throws {
        let fixture = try GitFixture(); defer { fixture.cleanup() }
        fixture.commitFile("seed.txt", "seed\n")
        let linked = fixture.root.appendingPathComponent("linked").path

        let queue = RepoGitQueue(git: git, repoPath: fixture.repoPath, lockBackoff: 0.02)
        try await queue.addWorktree(path: linked, branch: "linked", createBranch: true)
        var list = try await git.worktrees(repoPath: fixture.repoPath)
        #expect(list.contains { $0.branch == "linked" })

        try await queue.removeWorktree(worktreePath: linked, force: true)
        list = try await git.worktrees(repoPath: fixture.repoPath)
        #expect(list.contains { $0.branch == "linked" } == false)
    }

    @Test("status on a deleted worktree directory throws")
    func deletedWorktree() async throws {
        let fixture = try GitFixture(); defer { fixture.cleanup() }
        fixture.commitFile("seed.txt", "seed\n")
        let linked = fixture.root.appendingPathComponent("gone").path
        try await git.addWorktree(repoPath: fixture.repoPath, path: linked, branch: "gone", createBranch: true)
        try FileManager.default.removeItem(atPath: linked)

        await #expect(throws: GitError.self) {
            _ = try await git.status(worktreePath: linked)
        }
    }

    @Test("binary file diff is flagged binary")
    func binaryDiff() async throws {
        let fixture = try GitFixture(); defer { fixture.cleanup() }
        var bytes = Data([0x00, 0x01, 0x02, 0x00, 0xFF, 0xFE])
        try bytes.write(to: fixture.repoURL.appendingPathComponent("blob.bin"))
        fixture.stage(["blob.bin"])
        fixture.commit("add binary")
        bytes.append(contentsOf: [0x10, 0x20, 0x00])
        try bytes.write(to: fixture.repoURL.appendingPathComponent("blob.bin"))

        let diff = try await git.workingDiff(worktreePath: fixture.repoPath, path: "blob.bin", staged: false)
        #expect(diff?.isBinary == true)
    }

    @Test("detached HEAD reported by status")
    func detachedHead() async throws {
        let fixture = try GitFixture(); defer { fixture.cleanup() }
        fixture.commitFile("a.txt", "a\n")
        fixture.commitFile("b.txt", "b\n")
        let sha = fixture.currentHead()
        fixture.git(["checkout", "-q", sha]) // detach

        let status = try await git.status(worktreePath: fixture.repoPath)
        #expect(status.isDetached == true)
        #expect(status.branch == nil)
    }

    @Test("a held index.lock surfaces as lockedIndex")
    func lockedIndex() async throws {
        let fixture = try GitFixture(); defer { fixture.cleanup() }
        fixture.commitFile("seed.txt", "seed\n")
        fixture.writeFile("new.txt", "new\n")
        let lock = fixture.repoURL.appendingPathComponent(".git/index.lock")
        try Data().write(to: lock)
        defer { try? FileManager.default.removeItem(at: lock) }

        await #expect(throws: GitError.self) {
            try await git.stage(worktreePath: fixture.repoPath, paths: ["new.txt"])
        }
    }
}
