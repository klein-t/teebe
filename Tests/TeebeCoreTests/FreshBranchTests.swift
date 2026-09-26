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

    /// A bare clone with the main branch checked out in its own worktree, the usual
    /// layout for worktree-first workflows. Bare repositories log no ref updates by
    /// default, so `worktree add -b` leaves no record of where a branch started.
    private func bareLayout(_ fixture: GitFixture) -> (bare: URL, main: URL) {
        fixture.commitFile("a.txt", "base")
        let bare = fixture.root.appendingPathComponent("bare.git", isDirectory: true)
        fixture.git(["clone", "-q", "--bare", fixture.repoPath, bare.path])
        let main = fixture.root.appendingPathComponent("main", isDirectory: true)
        fixture.git(["worktree", "add", "-q", main.path, "main"], in: bare)
        return (bare, main)
    }

    private func moveMain(_ fixture: GitFixture, in main: URL, file: String = "later.txt") {
        fixture.writeFile(file, "main moved on", in: main)
        fixture.stage(in: main)
        fixture.git(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-q", "-m", "main moved"], in: main)
    }

    private func scan(bare: URL) async throws -> [CleanupEntry] {
        try await WorktreeCleanupService(git: ProcessGitClient()).scan(repoPath: bare.path, extraTarget: nil).entries
    }

    @Test("in a bare clone, a just-created branch stays fresh after main moves on")
    func bareCloneFreshBranch() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        let (bare, main) = bareLayout(fixture)
        let fresh = fixture.root.appendingPathComponent("fresh", isDirectory: true)
        fixture.git(["worktree", "add", "-q", "-b", "fresh", fresh.path, "main"], in: bare)
        moveMain(fixture, in: main)
        let entry = try #require(try await scan(bare: bare).first { $0.worktree.branch == "fresh" })
        #expect(entry.hasNoCommits)
        #expect(entry.mergeStatus == .notConfirmed)
        #expect(!entry.canRemove(includingIgnored: true))
    }

    @Test("in a bare clone, a branch committed in its worktree and fast-forwarded into main is merged")
    func bareCloneCommittedBranch() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        let (bare, main) = bareLayout(fixture)
        let work = fixture.root.appendingPathComponent("work", isDirectory: true)
        fixture.git(["worktree", "add", "-q", "-b", "work", work.path, "main"], in: bare)
        fixture.writeFile("w.txt", "work", in: work)
        fixture.stage(in: work)
        fixture.git(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-q", "-m", "work"], in: work)
        fixture.git(["merge", "-q", "--ff-only", "work"], in: main)
        let atTip = try #require(try await scan(bare: bare).first { $0.worktree.branch == "work" })
        #expect(!atTip.hasNoCommits)
        #expect(atTip.mergeStatus == .merged)
        moveMain(fixture, in: main)
        let behind = try #require(try await scan(bare: bare).first { $0.worktree.branch == "work" })
        #expect(!behind.hasNoCommits)
        #expect(behind.mergeStatus == .merged)
        #expect(behind.canRemove(includingIgnored: false))
    }

    @Test("with no reflog at all, a fast-forward can't be told from a fresh branch, but a merge commit can")
    func noReflogAtAll() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile("a.txt", "base")
        let fastForward = fixture.addWorktree(name: "ff", branch: "ff")
        fixture.commitAndFastForward(branch: "ff", in: fastForward, file: "ff.txt")
        let merged = fixture.addWorktree(name: "merged", branch: "merged")
        fixture.writeFile("m.txt", "merged work", in: merged)
        fixture.stage(in: merged)
        fixture.commit("merged work", in: merged)
        fixture.git(["merge", "-q", "--no-ff", "merged", "-m", "merge"])
        fixture.commitFile("c.txt", "main moved on")
        let gitDir = fixture.repoURL.appendingPathComponent(".git")
        for log in ["logs/refs/heads/ff", "logs/refs/heads/merged", "worktrees/ff/logs", "worktrees/merged/logs"] {
            try FileManager.default.removeItem(at: gitDir.appendingPathComponent(log))
        }
        let entries = try await scan(fixture).entries
        let ffEntry = try #require(entries.first { $0.worktree.branch == "ff" })
        let mergedEntry = try #require(entries.first { $0.worktree.branch == "merged" })
        // Its tip sits on main's own line: it may have been cut there, so no ✓.
        #expect(ffEntry.hasNoCommits)
        #expect(ffEntry.mergeStatus == .notConfirmed)
        // Its tip only reached main through a merge: that is merged work.
        #expect(!mergedEntry.hasNoCommits)
        #expect(mergedEntry.mergeStatus == .merged)
    }

    @Test("a detached worktree with no commits of its own is not merged after main moves on")
    func detachedFresh() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile("a.txt", "base")
        let detached = fixture.root.appendingPathComponent("detached", isDirectory: true)
        fixture.git(["worktree", "add", "-q", "--detach", detached.path, "HEAD"])
        fixture.commitFile("b.txt", "main moved on")
        let entry = try #require(try await scan(fixture).entries.first { $0.worktree.isDetached })
        #expect(entry.hasNoCommits)
        #expect(entry.mergeStatus == .notConfirmed)
    }
}
