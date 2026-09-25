import Foundation
import Testing
@testable import TeebeCore

/// A branch that was just created has no commits of its own. Its tip is an
/// ancestor of the target it was cut from, so ancestry alone calls it merged and
/// the row offered "Safe to delete" for a worktree an agent had only started on.
@Suite("Fresh branches are not merged")
struct FreshBranchTests {
    private func scan(_ fixture: GitFixture) async throws -> CleanupSnapshot {
        try await WorktreeCleanupService(git: ProcessGitClient()).scan(repoPath: fixture.repoPath, extraTarget: nil)
    }

    @Test("a branch with no commits since it was created is not merged and cannot be removed")
    func createdFromHead() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile("a.txt", "base")
        fixture.addWorktree(name: "fresh", branch: "fresh")
        let entry = try #require(try await scan(fixture).entries.first { $0.worktree.branch == "fresh" })
        #expect(entry.hasNoCommits)
        #expect(entry.mergeStatus == .notConfirmed)
        #expect(entry.mergedTargets.isEmpty)
        #expect(!entry.canRemove(includingIgnored: true))
    }

    @Test("a branch cut from origin/dev that the target has since moved past is still fresh")
    func createdFromRemoteTarget() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile("a.txt", "base")
        fixture.git(["update-ref", "refs/remotes/origin/dev", "HEAD"])
        let folder = fixture.root.appendingPathComponent("lens", isDirectory: true)
        fixture.git(["worktree", "add", "-q", "-b", "feat/lens", folder.path, "origin/dev"])
        fixture.commitFile("b.txt", "dev moved on")
        fixture.git(["update-ref", "refs/remotes/origin/dev", "HEAD"])
        let entry = try #require(try await scan(fixture).entries.first { $0.worktree.branch == "feat/lens" })
        #expect(entry.hasNoCommits)
        #expect(entry.mergeStatus == .notConfirmed)
    }

    @Test("a branch that had commits and was fast-forward merged stays merged")
    func fastForwardMerged() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile("a.txt", "base")
        let folder = fixture.addWorktree(name: "feature", branch: "feature")
        fixture.commitAndFastForward(branch: "feature", in: folder)
        let entry = try #require(try await scan(fixture).entries.first { $0.worktree.branch == "feature" })
        #expect(!entry.hasNoCommits)
        #expect(entry.mergeStatus == .merged)
        #expect(entry.canRemove(includingIgnored: false))
    }

    @Test("a branch checked out from another merged branch carries that branch's commits")
    func createdFromMergedBranch() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile("a.txt", "base")
        let work = fixture.addWorktree(name: "work", branch: "work")
        fixture.commitAndFastForward(branch: "work", in: work)
        let copy = fixture.root.appendingPathComponent("copy", isDirectory: true)
        fixture.git(["worktree", "add", "-q", "-b", "copy", copy.path, "work"])
        let entry = try #require(try await scan(fixture).entries.first { $0.worktree.branch == "copy" })
        #expect(!entry.hasNoCommits)
        #expect(entry.mergeStatus == .merged)
    }

    @Test("without a reflog, a branch sitting exactly on a target's tip counts as fresh; one behind it stays merged")
    func noReflogFallback() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile("a.txt", "base")
        fixture.addWorktree(name: "atTip", branch: "atTip")
        let behind = fixture.addWorktree(name: "behind", branch: "behind")
        fixture.commitAndFastForward(branch: "behind", in: behind)
        fixture.commitFile("c.txt", "main moved on")
        fixture.git(["update-ref", "refs/heads/atTip", "HEAD"])
        for branch in ["atTip", "behind"] {
            try FileManager.default.removeItem(at: fixture.repoURL.appendingPathComponent(".git/logs/refs/heads/\(branch)"))
        }
        let entries = try await scan(fixture).entries
        let atTip = try #require(entries.first { $0.worktree.branch == "atTip" })
        let merged = try #require(entries.first { $0.worktree.branch == "behind" })
        #expect(atTip.hasNoCommits)
        #expect(atTip.mergeStatus == .notConfirmed)
        #expect(!merged.hasNoCommits)
        #expect(merged.mergeStatus == .merged)
    }
}
