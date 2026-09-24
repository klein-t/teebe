import Foundation
import Testing
@testable import TeebeCore

/// Forwards to real git, running `afterRemove` right after a worktree is removed:
/// the moment between folder removal and branch deletion.
private struct RemovalHookGit: GitClient {
    let base = ProcessGitClient()
    let afterRemove: @Sendable () -> Void
    func worktrees(repoPath: String) async throws -> [Worktree] { try await base.worktrees(repoPath: repoPath) }
    func branches(repoPath: String) async throws -> [Branch] { try await base.branches(repoPath: repoPath) }
    func status(worktreePath: String) async throws -> StatusResult { try await base.status(worktreePath: worktreePath) }
    func workingDiff(worktreePath: String, path: String, staged: Bool) async throws -> DiffFile? {
        try await base.workingDiff(worktreePath: worktreePath, path: path, staged: staged)
    }
    func stage(worktreePath: String, paths: [String]) async throws {}
    func unstage(worktreePath: String, paths: [String]) async throws {}
    func discardWorking(worktreePath: String, paths: [String]) async throws {}
    func discardUntracked(worktreePath: String, paths: [String]) async throws {}
    func commit(worktreePath: String, message: String) async throws {}
    func addWorktree(repoPath: String, path: String, branch: String?, createBranch: Bool, startPoint: String?) async throws {}
    func removeWorktree(repoPath: String, worktreePath: String, force: Bool) async throws {
        try await base.removeWorktree(repoPath: repoPath, worktreePath: worktreePath, force: force)
        afterRemove()
    }
    func pruneWorktrees(repoPath: String) async throws {}
    func fetchOrigin(repoPath: String) async throws {}
    func run(_ arguments: [String], in directory: String) async throws -> GitInvocationResult {
        try await base.run(arguments, in: directory)
    }
}

/// Synchronous git for use inside a non-async hook; returns trimmed stdout.
private func shell(_ arguments: [String], in path: String) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git", "-c", "user.name=Test", "-c", "user.email=test@example.com"] + arguments
    process.currentDirectoryURL = URL(fileURLWithPath: path)
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    try? process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (String(bytes: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
}

@Suite("Merge targets")
struct MergeTargetsTests {
    private struct Repo {
        let fixture: GitFixture
        let feature: URL
        let dev: URL
    }

    /// main (primary) and a dev checkout, plus a feature worktree with one commit.
    private func repo() throws -> Repo {
        let fixture = try GitFixture()
        fixture.commitFile("a.txt", "base")
        fixture.createBranch("dev")
        let dev = fixture.root.appendingPathComponent("dev", isDirectory: true)
        fixture.git(["worktree", "add", "-q", dev.path, "dev"])
        let feature = fixture.addWorktree(name: "feature", branch: "feature")
        fixture.writeFile("f.txt", "feature", in: feature)
        fixture.stage(in: feature)
        fixture.commit("feature", in: feature)
        return Repo(fixture: fixture, feature: feature, dev: dev)
    }

    private func entry(_ snapshot: CleanupSnapshot, _ branch: String) throws -> CleanupEntry {
        try #require(snapshot.entries.first { $0.worktree.branch == branch })
    }

    @Test("every integration branch is checked and the ones that contain the work are named")
    func mergedIntoSeveral() async throws {
        let setup = try repo()
        let fixture = setup.fixture
        let dev = setup.dev
        defer { fixture.cleanup() }
        let service = WorktreeCleanupService(git: ProcessGitClient())
        let before = try await service.scan(repoPath: fixture.repoPath, extraTarget: nil)
        #expect(before.targetNames == ["main", "dev"])
        #expect(try entry(before, "feature").mergeStatus == .notConfirmed)
        #expect(try entry(before, "main").isTarget)
        #expect(try entry(before, "dev").isTarget)

        fixture.git(["merge", "-q", "--no-ff", "feature", "-m", "merge feature"], in: dev)
        let intoDev = try await service.scan(repoPath: fixture.repoPath, extraTarget: nil)
        #expect(try entry(intoDev, "feature").mergedInto == ["dev"])
        #expect(try entry(intoDev, "feature").hasEquivalentContent == false)

        fixture.git(["merge", "-q", "--no-ff", "dev", "-m", "release"])
        let intoBoth = try await service.scan(repoPath: fixture.repoPath, extraTarget: nil)
        #expect(try entry(intoBoth, "feature").mergedInto == ["main", "dev"])
        #expect(try entry(intoBoth, "feature").canRemove(includingIgnored: false))
    }

    @Test("a squash into a non-default integration branch is found by content")
    func squashIntoDev() async throws {
        let setup = try repo()
        let fixture = setup.fixture
        let dev = setup.dev
        defer { fixture.cleanup() }
        fixture.git(["merge", "--squash", "feature"], in: dev)
        fixture.commit("squash feature", in: dev)
        let snapshot = try await WorktreeCleanupService(git: ProcessGitClient()).scan(repoPath: fixture.repoPath, extraTarget: nil)
        let feature = try entry(snapshot, "feature")
        #expect(feature.mergeStatus == .merged)
        #expect(feature.mergedInto == ["dev"])
        #expect(feature.hasEquivalentContent)
    }

    @Test("the per-repository extra branch is checked too")
    func extraTarget() async throws {
        let setup = try repo()
        let fixture = setup.fixture
        defer { fixture.cleanup() }
        fixture.git(["branch", "release/1", "feature"])
        let service = WorktreeCleanupService(git: ProcessGitClient())
        let snapshot = try await service.scan(repoPath: fixture.repoPath, extraTarget: "refs/heads/release/1")
        #expect(snapshot.targetNames == ["main", "release/1", "dev"])
        #expect(try entry(snapshot, "feature").mergedInto == ["release/1"])
    }

    @Test("removal needs only one merged target unchanged, and fails once none is")
    func revalidation() async throws {
        let setup = try repo()
        let fixture = setup.fixture
        let feature = setup.feature
        let dev = setup.dev
        defer { fixture.cleanup() }
        fixture.git(["merge", "-q", "--no-ff", "feature", "-m", "merge feature"], in: dev)
        fixture.git(["merge", "-q", "--no-ff", "dev", "-m", "release"])
        let service = WorktreeCleanupService(git: ProcessGitClient())
        let snapshot = try await service.scan(repoPath: fixture.repoPath, extraTarget: nil)
        let reviewed = try entry(snapshot, "feature")
        fixture.commitFile("later.txt", "main moved on")
        fixture.writeFile("dev.txt", "dev moved on", in: dev)
        fixture.stage(in: dev)
        fixture.commit("dev moved on", in: dev)
        await #expect(throws: CleanupError.changed) {
            try await service.remove(repoPath: fixture.repoPath, entry: reviewed, includingIgnored: false, deleteBranch: false)
        }
        #expect(FileManager.default.fileExists(atPath: feature.path))
        let rescanned = try await service.scan(repoPath: fixture.repoPath, extraTarget: nil)
        let fresh = try entry(rescanned, "feature")
        fixture.commitFile("again.txt", "main moved again")
        let outcome = try await service.remove(repoPath: fixture.repoPath, entry: fresh, includingIgnored: false, deleteBranch: false)
        #expect(outcome == .notRequested)
        #expect(!FileManager.default.fileExists(atPath: feature.path))
        #expect(!fixture.git(["rev-parse", "--verify", "feature"]).isEmpty)
    }

    @Test("deleting the branch removes only the local branch, merged or squashed")
    func deletesLocalBranch() async throws {
        let setup = try repo()
        let fixture = setup.fixture
        let feature = setup.feature
        let dev = setup.dev
        defer { fixture.cleanup() }
        let remote = fixture.root.appendingPathComponent("remote.git", isDirectory: true)
        fixture.git(["init", "-q", "--bare", remote.path])
        fixture.git(["remote", "add", "origin", remote.path])
        fixture.git(["push", "-q", "origin", "feature"], in: feature)
        fixture.git(["merge", "--squash", "feature"], in: dev)
        fixture.commit("squash feature", in: dev)
        let service = WorktreeCleanupService(git: ProcessGitClient())
        let snapshot = try await service.scan(repoPath: fixture.repoPath, extraTarget: nil)
        let reviewed = try entry(snapshot, "feature")
        #expect(reviewed.hasEquivalentContent)
        let outcome = try await service.remove(repoPath: fixture.repoPath, entry: reviewed, includingIgnored: false, deleteBranch: true)
        #expect(outcome == .deleted)
        #expect(!FileManager.default.fileExists(atPath: feature.path))
        #expect(fixture.git(["branch", "--list", "feature"]).isEmpty)
        #expect(!fixture.git(["ls-remote", "--heads", "origin", "feature"]).isEmpty)
    }

    @Test("a branch that moved after the folder was removed is kept")
    func movedBranchIsKept() async throws {
        let setup = try repo()
        let fixture = setup.fixture
        let dev = setup.dev
        defer { fixture.cleanup() }
        fixture.git(["merge", "-q", "--no-ff", "feature", "-m", "merge feature"], in: dev)
        let repoPath = fixture.repoPath
        let git = RemovalHookGit {
            // Someone points the branch at unmerged work in the gap.
            let stray = shell(["commit-tree", "-m", "stray", "-p", "feature", "feature^{tree}"], in: repoPath)
            _ = shell(["branch", "-f", "feature", stray], in: repoPath)
        }
        let service = WorktreeCleanupService(git: git)
        let snapshot = try await service.scan(repoPath: fixture.repoPath, extraTarget: nil)
        let outcome = try await service.remove(repoPath: fixture.repoPath, entry: try entry(snapshot, "feature"),
                                               includingIgnored: false, deleteBranch: true)
        #expect(outcome == .kept)
        #expect(!fixture.git(["branch", "--list", "feature"]).isEmpty)
    }
}
