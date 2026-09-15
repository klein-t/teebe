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

    @Test("partial content and conflicting later edits never count as included")
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
        #expect(try await !check.containsChanges(from: "feature", in: "main", repoPath: fixture.repoPath))
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
        let snapshot = try await service.scan(repoPath: fixture.repoPath, targetOverride: nil)
        let entry = try #require(snapshot.entries.first { !$0.worktree.isPrimary })
        #expect(entry.isBroken)
        #expect(entry.problem?.contains(".git link is missing") == true)
        #expect(!entry.canRemove(includingIgnored: true))
        let target = try #require(snapshot.target)
        await #expect(throws: (any Error).self) {
            try await service.remove(repoPath: fixture.repoPath, entry: entry, target: target, includingIgnored: true)
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
        let snapshot = try await service.scan(repoPath: fixture.repoPath, targetOverride: nil)
        let entry = try #require(snapshot.entries.first { !$0.worktree.isPrimary })
        let target = try #require(snapshot.target)
        #expect(entry.hasEquivalentContent)
        #expect(entry.canRemove(includingIgnored: false))
        fixture.writeFile("untracked.txt", "keep", in: folder)
        await #expect(throws: (any Error).self) {
            try await service.remove(repoPath: fixture.repoPath, entry: entry, target: target, includingIgnored: false)
        }
        fixture.deleteFile("untracked.txt", in: folder)
        try await service.remove(repoPath: fixture.repoPath, entry: entry, target: target, includingIgnored: false)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(!fixture.git(["rev-parse", "--verify", "feature"]).isEmpty)
    }
}
