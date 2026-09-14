import Foundation
import Testing
@testable import TeebeCore

@Suite("Worktree cleanup")
struct WorktreeCleanupTests {
    @Test("auto uses the remote default and overrides use exact refs")
    func targets() {
        let refs = "refs/heads/main\u{0}aaa\u{0}\u{0}\nrefs/remotes/origin/dev\u{0}bbb\u{0}\u{0}\nrefs/remotes/origin/HEAD\u{0}bbb\u{0}\u{0}refs/remotes/origin/dev\n"
        let catalog = CleanupTargets.parse(refs)
        #expect(catalog.automatic?.ref == "refs/remotes/origin/dev")
        #expect(catalog.resolve("refs/heads/main")?.sha == "aaa")
        #expect(catalog.resolve("refs/heads/missing") == nil)
        #expect(catalog.branches.count == 2)
    }

    @Test("ambiguous fallback needs a choice; a unique main falls back locally")
    func fallback() {
        let main = "refs/heads/main\u{0}aaa\u{0}\u{0}\n"
        #expect(CleanupTargets.parse(main).automatic?.ref == "refs/heads/main")
        #expect(CleanupTargets.parse(main + "refs/heads/master\u{0}bbb\u{0}\u{0}\n").automatic == nil)
    }

    @Test("regular merge is confirmed, squash merge is not falsely confirmed")
    func mergeKinds() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile("a.txt", "base")
        fixture.addWorktree(name: "feature", branch: "feature")
        let git = ProcessGitClient()
        let trees = try await git.worktrees(repoPath: fixture.repoPath)
        let feature = try #require(trees.first { $0.branch == "feature" })
        try Data("new".utf8).write(to: URL(fileURLWithPath: feature.path + "/new.txt"))
        _ = try await git.run(["add", "."], in: feature.path)
        _ = try await git.run(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "feature"], in: feature.path)
        let service = WorktreeCleanupService(git: git)
        let before = try await service.scan(repoPath: fixture.repoPath, targetOverride: nil)
        #expect(before.entries.first { $0.worktree.branch == "feature" }?.mergeStatus == .notConfirmed)
        _ = try await git.run(["merge", "--squash", "feature"], in: fixture.repoPath)
        _ = try await git.run(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "squashed"], in: fixture.repoPath)
        let squash = try await service.scan(repoPath: fixture.repoPath, targetOverride: nil)
        #expect(squash.entries.first { $0.worktree.branch == "feature" }?.mergeStatus == .notConfirmed)
        _ = try await git.run(["-c", "user.name=Test", "-c", "user.email=test@example.com", "merge", "--no-ff", "feature", "-m", "merged"], in: fixture.repoPath)
        let merged = try await service.scan(repoPath: fixture.repoPath, targetOverride: nil)
        #expect(merged.entries.first { $0.worktree.branch == "feature" }?.mergeStatus == .merged)
    }

    @Test("ignored files need explicit consent and late local changes prevent removal")
    func fileSafety() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile(".gitignore", "cache/\n")
        fixture.addWorktree(name: "feature", branch: "feature")
        let service = WorktreeCleanupService(git: ProcessGitClient())
        let first = try await service.scan(repoPath: fixture.repoPath, targetOverride: nil)
        let entry = try #require(first.entries.first { !$0.worktree.isPrimary })
        let target = try #require(first.target)
        let cache = URL(fileURLWithPath: entry.worktree.path + "/cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("local".utf8).write(to: cache.appendingPathComponent("data.txt"))
        let second = try await service.scan(repoPath: fixture.repoPath, targetOverride: nil)
        let ignored = try #require(second.entries.first { !$0.worktree.isPrimary })
        #expect(ignored.hasIgnoredFiles)
        #expect(!ignored.canRemove(includingIgnored: false))
        #expect(ignored.canRemove(includingIgnored: true))
        await #expect(throws: (any Error).self) {
            try await service.remove(repoPath: fixture.repoPath, entry: entry, target: target, includingIgnored: false)
        }
        try Data("do not delete".utf8).write(to: URL(fileURLWithPath: entry.worktree.path + "/untracked.txt"))
        await #expect(throws: (any Error).self) {
            try await service.remove(repoPath: fixture.repoPath, entry: ignored, target: target, includingIgnored: true)
        }
        #expect(FileManager.default.fileExists(atPath: entry.worktree.path + "/untracked.txt"))
        try FileManager.default.removeItem(atPath: entry.worktree.path + "/untracked.txt")
        try await service.remove(repoPath: fixture.repoPath, entry: ignored, target: target, includingIgnored: true)
        #expect(!FileManager.default.fileExists(atPath: entry.worktree.path))
        #expect(try await ProcessGitClient().branches(repoPath: fixture.repoPath).contains { $0.name == "feature" })
    }

    @Test("changed target and primary worktree cannot be removed")
    func staleReview() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile("a.txt", "base")
        fixture.addWorktree(name: "feature", branch: "feature")
        let service = WorktreeCleanupService(git: ProcessGitClient())
        let snapshot = try await service.scan(repoPath: fixture.repoPath, targetOverride: nil)
        let target = try #require(snapshot.target)
        let primary = try #require(snapshot.entries.first { $0.worktree.isPrimary })
        #expect(!primary.canRemove(includingIgnored: true))
        await #expect(throws: (any Error).self) {
            try await service.remove(repoPath: fixture.repoPath, entry: primary, target: target, includingIgnored: true)
        }
        fixture.commitFile("a.txt", "changed target")
        let entry = try #require(snapshot.entries.first { !$0.worktree.isPrimary })
        await #expect(throws: (any Error).self) {
            try await service.remove(repoPath: fixture.repoPath, entry: entry, target: target, includingIgnored: false)
        }
        #expect(FileManager.default.fileExists(atPath: entry.worktree.path))
    }
    @Test("new commits, locks, and the target checkout block removal")
    func protections() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile("a.txt", "base")
        let folder = fixture.addWorktree(name: "feature", branch: "feature")
        let service = WorktreeCleanupService(git: ProcessGitClient())
        let scan = try await service.scan(repoPath: fixture.repoPath, targetOverride: nil)
        let entry = try #require(scan.entries.first { !$0.worktree.isPrimary })
        let target = try #require(scan.target)
        let ownTarget = try await service.scan(repoPath: fixture.repoPath, targetOverride: "refs/heads/feature")
        #expect(ownTarget.entries.first { !$0.worktree.isPrimary }?.isTarget == true)
        fixture.git(["worktree", "lock", folder.path])
        await #expect(throws: (any Error).self) {
            try await service.remove(repoPath: fixture.repoPath, entry: entry, target: target, includingIgnored: false)
        }
        fixture.git(["worktree", "unlock", folder.path])
        fixture.writeFile("a.txt", "new commit", in: folder)
        fixture.stage(in: folder)
        fixture.commit("new work", in: folder)
        await #expect(throws: (any Error).self) {
            try await service.remove(repoPath: fixture.repoPath, entry: entry, target: target, includingIgnored: false)
        }
        #expect(FileManager.default.fileExists(atPath: folder.path))
    }

    @Test("missing saved targets and missing worktree folders never become eligible")
    func unavailable() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile("a.txt", "base")
        let folder = fixture.addWorktree(name: "feature", branch: "feature")
        let service = WorktreeCleanupService(git: ProcessGitClient())
        let missingTarget = try await service.scan(repoPath: fixture.repoPath, targetOverride: "refs/heads/gone")
        #expect(missingTarget.target == nil)
        #expect(missingTarget.entries.allSatisfy { !$0.canRemove(includingIgnored: true) })
        try FileManager.default.removeItem(at: folder)
        let missingFolder = try await service.scan(repoPath: fixture.repoPath, targetOverride: nil)
        let missing = try #require(missingFolder.entries.first { !$0.worktree.isPrimary })
        #expect(missing.mergeStatus == .unknown)
        #expect(!missing.canRemove(includingIgnored: true))
    }

    @Test("assume-unchanged flags cannot hide local work from cleanup")
    func uncheckedFiles() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile("a.txt", "base")
        let folder = fixture.addWorktree(name: "feature", branch: "feature")
        fixture.git(["update-index", "--assume-unchanged", "a.txt"], in: folder)
        fixture.writeFile("a.txt", "hidden edits", in: folder)
        let service = WorktreeCleanupService(git: ProcessGitClient())
        let snapshot = try await service.scan(repoPath: fixture.repoPath, targetOverride: nil)
        let entry = try #require(snapshot.entries.first { !$0.worktree.isPrimary })
        #expect(entry.hasUncheckedFiles)
        #expect(!entry.canRemove(includingIgnored: true))
    }

    @Test("feature branches tracking the merge target are not the target checkout")
    func sharedUpstream() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile("a.txt", "base")
        fixture.git(["remote", "add", "origin", fixture.repoPath])
        fixture.git(["update-ref", "refs/remotes/origin/dev", "HEAD"])
        fixture.git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/dev"])
        let feature = fixture.addWorktree(name: "feature", branch: "feature")
        fixture.git(["branch", "--set-upstream-to=origin/dev", "feature"])
        let dev = fixture.addWorktree(name: "dev", branch: "dev")
        let service = WorktreeCleanupService(git: ProcessGitClient())
        let snapshot = try await service.scan(repoPath: fixture.repoPath, targetOverride: nil)
        let entry = try #require(snapshot.entries.first { $0.worktree.branch == "feature" })
        let targetEntry = try #require(snapshot.entries.first { $0.worktree.branch == "dev" })
        #expect(entry.mergeStatus == .merged)
        #expect(!entry.isTarget)
        #expect(entry.canRemove(includingIgnored: false))
        #expect(targetEntry.isTarget)
        #expect(!targetEntry.canRemove(includingIgnored: true))
        let target = try #require(snapshot.target)
        try await service.remove(repoPath: fixture.repoPath, entry: entry, target: target, includingIgnored: false)
        #expect(!FileManager.default.fileExists(atPath: feature.path))
        #expect(FileManager.default.fileExists(atPath: dev.path))
        #expect(!fixture.git(["rev-parse", "--verify", "feature"]).isEmpty)
    }

}
