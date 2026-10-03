import Foundation
import Testing
@testable import TeebeCore

@Suite("Squash content inclusion")
struct GitContentInclusionTests {
    @Test("multi-commit squash survives unrelated target changes but not new branch work")
    func squashAndAdvance() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile("base.txt", "base")
        let folder = fixture.addWorktree(name: "feature", branch: "feature")
        fixture.writeFile("one.txt", "one", in: folder)
        fixture.stage(in: folder)
        fixture.commit("first", in: folder)
        fixture.writeFile("two.txt", "two", in: folder)
        fixture.stage(in: folder)
        fixture.commit("second", in: folder)
        let check = GitContentInclusion(git: ProcessGitClient())
        #expect(try await !check.containsChanges(from: "feature", in: "main", repoPath: fixture.repoPath))
        fixture.git(["merge", "--squash", "feature"])
        fixture.commit("squash")
        fixture.commitFile("unrelated.txt", "later work")
        #expect(try await check.containsChanges(from: "feature", in: "main", repoPath: fixture.repoPath))
        fixture.writeFile("three.txt", "not merged", in: folder)
        fixture.stage(in: folder)
        fixture.commit("after squash", in: folder)
        #expect(try await !check.containsChanges(from: "feature", in: "main", repoPath: fixture.repoPath))
    }

    @Test("partial content is unconfirmed but later target edits preserve inclusion")
    func partialAndRewritten() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile("base.txt", "base")
        let folder = fixture.addWorktree(name: "feature", branch: "feature")
        fixture.writeFile("one.txt", "one", in: folder)
        fixture.writeFile("two.txt", "two", in: folder)
        fixture.stage(in: folder)
        fixture.commit("feature", in: folder)
        fixture.commitFile("one.txt", "one")
        let check = GitContentInclusion(git: ProcessGitClient())
        #expect(try await !check.containsChanges(from: "feature", in: "main", repoPath: fixture.repoPath))
        fixture.commitFile("two.txt", "two")
        #expect(try await check.containsChanges(from: "feature", in: "main", repoPath: fixture.repoPath))
        fixture.commitFile("two.txt", "rewritten")
        #expect(try await check.containsChanges(from: "feature", in: "main", repoPath: fixture.repoPath))
    }

    @Test("renames, deletions, binary files, unusual names and modes are checked exactly")
    func fileKinds() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile("old.txt", "rename me")
        fixture.commitFile("delete.txt", "remove me")
        fixture.commitFile("script.sh", "echo ok")
        let folder = fixture.addWorktree(name: "feature", branch: "feature")
        fixture.git(["mv", "old.txt", "new\nname.txt"], in: folder)
        fixture.deleteFile("delete.txt", in: folder)
        try Data([0, 255, 1, 42]).write(to: folder.appendingPathComponent("binary.dat"))
        fixture.git(["update-index", "--chmod=+x", "script.sh"], in: folder)
        fixture.stage(["new\nname.txt", "delete.txt", "binary.dat"], in: folder)
        fixture.commit("file changes", in: folder)
        fixture.git(["merge", "--squash", "feature"])
        fixture.commit("squash")
        let check = GitContentInclusion(git: ProcessGitClient())
        #expect(try await check.containsChanges(from: "feature", in: "main", repoPath: fixture.repoPath))
        fixture.git(["update-index", "--chmod=-x", "script.sh"])
        fixture.commit("different mode")
        #expect(try await check.containsChanges(from: "feature", in: "main", repoPath: fixture.repoPath))
    }

    @Test("target footer edits preserve a squash merge; new worktree edits and commits block cleanup")
    func laterFooterChanges() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile("page.txt", "header\nfooter\n")
        let folder = fixture.addWorktree(name: "feature", branch: "feature")
        fixture.writeFile("page.txt", "header\nsearch button\nfooter\n", in: folder)
        fixture.stage(in: folder)
        fixture.commit("search button", in: folder)
        fixture.git(["merge", "--squash", "feature"])
        fixture.commit("squash")
        fixture.commitFile("page.txt", "header\nsearch button\nnew footer\n")
        let service = WorktreeCleanupService(git: ProcessGitClient())
        let included = try await service.scan(repoPath: fixture.repoPath, extraTarget: nil)
        let entry = try #require(included.entries.first { !$0.worktree.isPrimary })
        #expect(entry.mergeStatus == .merged)
        #expect(entry.hasEquivalentContent)
        #expect(entry.canRemove(includingIgnored: false))
        fixture.writeFile("page.txt", "header\nsearch button\nworktree footer\n", in: folder)
        let edited = try await service.scan(repoPath: fixture.repoPath, extraTarget: nil)
        #expect(edited.entries.first { !$0.worktree.isPrimary }?.canRemove(includingIgnored: false) == false)
        fixture.stage(in: folder)
        fixture.commit("new worktree footer", in: folder)
        let advanced = try await service.scan(repoPath: fixture.repoPath, extraTarget: nil)
        #expect(advanced.entries.first { !$0.worktree.isPrimary }?.mergeStatus == .notConfirmed)
        await #expect(throws: (any Error).self) {
            try await service.remove(repoPath: fixture.repoPath, entry: entry, includingIgnored: false, deleteBranch: false)
        }
    }

    @Test("a branch whose net change is empty is never confirmed as included")
    func netZeroBranches() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile("base.txt", "base")
        let added = fixture.addWorktree(name: "added", branch: "added")
        fixture.writeFile("scratch.txt", "temp", in: added)
        fixture.stage(in: added)
        fixture.commit("add scratch", in: added)
        fixture.deleteFile("scratch.txt", in: added)
        fixture.stage(in: added)
        fixture.commit("drop scratch", in: added)
        let reverted = fixture.addWorktree(name: "reverted", branch: "reverted")
        fixture.writeFile("base.txt", "edited", in: reverted)
        fixture.stage(in: reverted)
        fixture.commit("edit base", in: reverted)
        fixture.writeFile("base.txt", "base", in: reverted)
        fixture.stage(in: reverted)
        fixture.commit("revert base", in: reverted)
        let check = GitContentInclusion(git: ProcessGitClient())
        #expect(try await !check.containsChanges(from: "added", in: "main", repoPath: fixture.repoPath))
        #expect(try await !check.containsChanges(from: "reverted", in: "main", repoPath: fixture.repoPath))
        let snapshot = try await WorktreeCleanupService(git: ProcessGitClient())
            .scan(repoPath: fixture.repoPath, extraTarget: nil)
        for branch in ["added", "reverted"] {
            let entry = try #require(snapshot.entries.first { $0.worktree.branch == branch })
            #expect(entry.mergeStatus == .notConfirmed)
            #expect(!entry.canRemove(includingIgnored: true))
        }
    }

    @Test("a squash on an integration branch survives a merge commit into the release branch")
    func squashReachedThroughMergeCommit() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile("page.txt", "v1")
        fixture.createBranch("dev")
        let feature = fixture.addWorktree(name: "feature", branch: "feature")
        fixture.writeFile("page.txt", "v2", in: feature)
        fixture.stage(in: feature)
        fixture.commit("feature work", in: feature)
        let dev = fixture.root.appendingPathComponent("dev", isDirectory: true)
        fixture.git(["worktree", "add", "-q", dev.path, "dev"])
        fixture.git(["merge", "--squash", "feature"], in: dev)
        fixture.commit("squash feature", in: dev)
        fixture.writeFile("page.txt", "v3", in: dev)
        fixture.stage(in: dev)
        fixture.commit("follow-up edit", in: dev)
        fixture.git(["merge", "--no-ff", "dev", "-m", "release"])
        let check = GitContentInclusion(git: ProcessGitClient())
        #expect(try await check.containsChanges(from: "feature", in: "main", repoPath: fixture.repoPath))
    }

    @Test("historical file matches must coexist in one target revision")
    func noMixedHistoricalSnapshots() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile("one.txt", "base one")
        fixture.commitFile("two.txt", "base two")
        let folder = fixture.addWorktree(name: "feature", branch: "feature")
        fixture.writeFile("one.txt", "new one", in: folder)
        fixture.writeFile("two.txt", "new two", in: folder)
        fixture.stage(in: folder)
        fixture.commit("both changes", in: folder)
        fixture.commitFile("one.txt", "new one")
        fixture.writeFile("one.txt", "base one")
        fixture.writeFile("two.txt", "new two")
        fixture.stage()
        fixture.commit("replace one change with the other")
        let check = GitContentInclusion(git: ProcessGitClient())
        #expect(try await !check.containsChanges(from: "feature", in: "main", repoPath: fixture.repoPath))
    }

    private struct Feature {
        let folder: URL
        let first: String
        let second: String
    }

    /// A feature with one commit per file, and a main that has moved on since. The
    /// tests rewrite `one.txt` on main between landing the two, so no main revision
    /// holds both changes at once.
    private func landedOneByOne(_ fixture: GitFixture) -> Feature {
        fixture.commitFile("base.txt", "base")
        let folder = fixture.addWorktree(name: "feature", branch: "feature")
        fixture.writeFile("one.txt", "one", in: folder)
        fixture.stage(in: folder)
        fixture.commit("first", in: folder)
        let first = fixture.git(["rev-parse", "HEAD"], in: folder).trimmingCharacters(in: .whitespacesAndNewlines)
        fixture.writeFile("two.txt", "two", in: folder)
        fixture.stage(in: folder)
        fixture.commit("second", in: folder)
        let second = fixture.git(["rev-parse", "HEAD"], in: folder).trimmingCharacters(in: .whitespacesAndNewlines)
        // Main moves first, so a pick is a new commit rather than the same one.
        fixture.commitFile("main.txt", "main work")
        return Feature(folder: folder, first: first, second: second)
    }

    @Test("a branch whose every commit landed separately among other work is included")
    func everyCommitUpstream() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        let feature = landedOneByOne(fixture)
        let check = GitContentInclusion(git: ProcessGitClient())
        fixture.git(["cherry-pick", feature.first])
        fixture.commitFile("one.txt", "rewritten")
        #expect(try await !check.containsChanges(from: "feature", in: "main", repoPath: fixture.repoPath))
        fixture.commitFile("other.txt", "other work")
        fixture.git(["cherry-pick", feature.second])
        #expect(try await check.containsChanges(from: "feature", in: "main", repoPath: fixture.repoPath))
    }

    @Test("one commit that never landed keeps the branch unconfirmed")
    func oneCommitNotUpstream() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        let feature = landedOneByOne(fixture)
        fixture.writeFile("three.txt", "not landed", in: feature.folder)
        fixture.stage(in: feature.folder)
        fixture.commit("third", in: feature.folder)
        fixture.git(["cherry-pick", feature.first])
        fixture.commitFile("one.txt", "rewritten")
        fixture.git(["cherry-pick", feature.second])
        let check = GitContentInclusion(git: ProcessGitClient())
        #expect(try await !check.containsChanges(from: "feature", in: "main", repoPath: fixture.repoPath))
    }

    @Test("a merge commit on the branch is not confirmed commit by commit")
    func mergeCommitOnBranch() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        let feature = landedOneByOne(fixture)
        let side = fixture.root.appendingPathComponent("side")
        fixture.git(["worktree", "add", "-q", "-b", "side", side.path, "main"])
        fixture.writeFile("three.txt", "three", in: side)
        fixture.stage(in: side)
        fixture.commit("side work", in: side)
        let sideCommit = fixture.git(["rev-parse", "HEAD"], in: side).trimmingCharacters(in: .whitespacesAndNewlines)
        fixture.git(["merge", "-q", "--no-ff", "side", "-m", "merge side"], in: feature.folder)
        fixture.git(["cherry-pick", feature.first])
        fixture.commitFile("one.txt", "rewritten")
        fixture.git(["cherry-pick", feature.second])
        fixture.git(["cherry-pick", sideCommit])
        // Every commit other than the merge itself is upstream.
        let cherry = fixture.git(["cherry", "main", "feature"])
        #expect(!cherry.contains("+"))
        let check = GitContentInclusion(git: ProcessGitClient())
        #expect(try await !check.containsChanges(from: "feature", in: "main", repoPath: fixture.repoPath))
    }

    @Test("missing Git link is explained and surviving files are preserved")
    func brokenLink() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile("base.txt", "base")
        let folder = fixture.addWorktree(name: "feature", branch: "feature")
        fixture.writeFile("untracked.txt", "keep this", in: folder)
        try FileManager.default.removeItem(at: folder.appendingPathComponent(".git"))
        let service = WorktreeCleanupService(git: ProcessGitClient())
        let snapshot = try await service.scan(repoPath: fixture.repoPath, extraTarget: nil)
        let entry = try #require(snapshot.entries.first { !$0.worktree.isPrimary })
        #expect(entry.isBroken)
        #expect(entry.problem?.contains(".git link is missing") == true)
        #expect(!entry.canRemove(includingIgnored: true))
        await #expect(throws: (any Error).self) {
            try await service.remove(repoPath: fixture.repoPath, entry: entry, includingIgnored: true, deleteBranch: false)
        }
        #expect(try String(contentsOf: folder.appendingPathComponent("untracked.txt"), encoding: .utf8) == "keep this")
    }

    @Test("squash cleanup rechecks new uncommitted files and retains the branch")
    func squashRemoval() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile("base.txt", "base")
        let folder = fixture.addWorktree(name: "feature", branch: "feature")
        fixture.writeFile("feature.txt", "feature", in: folder)
        fixture.stage(in: folder)
        fixture.commit("feature", in: folder)
        fixture.git(["merge", "--squash", "feature"])
        fixture.commit("squash")
        let service = WorktreeCleanupService(git: ProcessGitClient())
        let snapshot = try await service.scan(repoPath: fixture.repoPath, extraTarget: nil)
        let entry = try #require(snapshot.entries.first { !$0.worktree.isPrimary })
        #expect(entry.hasEquivalentContent)
        #expect(entry.canRemove(includingIgnored: false))
        fixture.writeFile("untracked.txt", "keep", in: folder)
        await #expect(throws: (any Error).self) {
            try await service.remove(repoPath: fixture.repoPath, entry: entry, includingIgnored: false, deleteBranch: false)
        }
        fixture.deleteFile("untracked.txt", in: folder)
        try await service.remove(repoPath: fixture.repoPath, entry: entry, includingIgnored: false, deleteBranch: false)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(!fixture.git(["rev-parse", "--verify", "feature"]).isEmpty)
    }
}
