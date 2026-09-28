import Testing
import Foundation
@testable import TeebeCore

/// Worktrees whose folder is gone, against real throwaway repositories: which are
/// forgotten, which are only hidden, and that a forget drops Git's record alone.
@Suite("Missing worktrees (integration)")
struct MissingWorktreesTests {
    let git = ProcessGitClient()

    private func listed(_ fixture: GitFixture) async throws -> [Worktree] {
        try await git.worktrees(repoPath: fixture.repoPath)
    }

    private func worktree(_ name: String, in fixture: GitFixture) async throws -> Worktree {
        try #require(try await listed(fixture).first { $0.path.hasSuffix("/" + name) })
    }

    private func branchExists(_ branch: String, in fixture: GitFixture) -> Bool {
        !fixture.git(["branch", "--list", branch]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @Test("a deleted folder is forgotten on its own, and its branch survives")
    func deletedFolderIsForgotten() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile("a.txt", "base")
        let gone = fixture.addWorktree(name: "gone", branch: "gone")
        let alsoGone = fixture.addWorktree(name: "also-gone", branch: "also-gone")
        let kept = fixture.addWorktree(name: "kept", branch: "kept")
        try FileManager.default.removeItem(at: gone)
        try FileManager.default.removeItem(at: alsoGone)

        let missing = MissingWorktrees(git: git)
        let target = try await worktree("gone", in: fixture)
        #expect(missing.disposition(of: target) == .deleted)
        #expect(await missing.forget(target, repoPath: fixture.repoPath))

        let paths = try await listed(fixture).map(\.path)
        #expect(!paths.contains { $0.hasSuffix("/gone") })
        // One record at a time: the other deleted one is still registered.
        #expect(paths.contains { $0.hasSuffix("/also-gone") })
        #expect(paths.contains { $0.hasSuffix("/kept") })
        #expect(FileManager.default.fileExists(atPath: kept.path))
        #expect(branchExists("gone", in: fixture))
    }

    @Test("a folder on a volume that isn't mounted is unreachable and never forgotten")
    func unmountedVolumeIsKept() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile("a.txt", "base")
        let away = fixture.addWorktree(name: "away", branch: "away")
        try FileManager.default.removeItem(at: away)
        let target = try await worktree("away", in: fixture)

        let missing = MissingWorktrees(git: git, isVolumeMounted: { $0 != target.path })
        #expect(missing.disposition(of: target) == .unreachable)
        #expect(!(await missing.forget(target, repoPath: fixture.repoPath)))
        #expect(try await listed(fixture).contains { $0.path == target.path })
    }

    @Test("a locked worktree whose folder is gone is unreachable and never forgotten")
    func lockedIsKept() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile("a.txt", "base")
        let locked = fixture.addWorktree(name: "locked", branch: "locked")
        fixture.git(["worktree", "lock", locked.path])
        try FileManager.default.removeItem(at: locked)
        let target = try await worktree("locked", in: fixture)
        #expect(target.isLocked)

        let missing = MissingWorktrees(git: git)
        #expect(missing.disposition(of: target) == .unreachable)
        #expect(!(await missing.forget(target, repoPath: fixture.repoPath)))
        #expect(try await listed(fixture).contains { $0.path == target.path })
    }

    @Test("the primary checkout is never forgotten, even if its folder reads as gone")
    func primaryIsNeverForgotten() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile("a.txt", "base")
        let primary = try #require(try await listed(fixture).first { $0.isPrimary })

        let missing = MissingWorktrees(git: git, folderIsGone: { _ in true })
        #expect(missing.disposition(of: primary) == .present)
        #expect(!(await missing.forget(primary, repoPath: fixture.repoPath)))
        // Not even a linked row that names the primary's folder.
        var impostor = primary
        impostor.isPrimary = false
        #expect(!(await missing.forget(impostor, repoPath: fixture.repoPath)))
        #expect(FileManager.default.fileExists(atPath: fixture.repoPath + "/a.txt"))
        #expect(try await listed(fixture).count == 1)
    }

    @Test("a folder that comes back before the forget is left alone")
    func reappearingFolderIsKept() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile("a.txt", "base")
        let back = fixture.addWorktree(name: "back", branch: "back")
        let aside = fixture.root.appendingPathComponent("back-aside")
        try FileManager.default.moveItem(at: back, to: aside)
        let target = try await worktree("back", in: fixture)
        let missing = MissingWorktrees(git: git)
        #expect(missing.disposition(of: target) == .deleted)

        // Returns between the scan that found it gone and the forget.
        try FileManager.default.moveItem(at: aside, to: back)
        #expect(!(await missing.forget(target, repoPath: fixture.repoPath)))
        #expect(FileManager.default.fileExists(atPath: back.appendingPathComponent("a.txt").path))
        #expect(try await listed(fixture).contains { $0.path == target.path })
    }

    @Test("a folder that exists but lost its .git link is present and never forgotten")
    func missingGitLinkIsKept() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile("a.txt", "base")
        let unlinked = fixture.addWorktree(name: "unlinked", branch: "unlinked")
        fixture.writeFile("draft.txt", "not committed", in: unlinked)
        try FileManager.default.removeItem(at: unlinked.appendingPathComponent(".git"))
        let target = try await worktree("unlinked", in: fixture)

        let missing = MissingWorktrees(git: git)
        #expect(missing.disposition(of: target) == .present)
        #expect(!(await missing.forget(target, repoPath: fixture.repoPath)))
        #expect(FileManager.default.fileExists(atPath: unlinked.appendingPathComponent("draft.txt").path))
        #expect(try await listed(fixture).contains { $0.path == target.path })
    }

    @Test("only a real ENOENT counts as gone")
    func goneMeansNoSuchFile() throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        #expect(!MissingWorktrees.isGone(fixture.repoPath))
        #expect(MissingWorktrees.isGone(fixture.root.appendingPathComponent("nope").path))
        #expect(MissingWorktrees.isGone(fixture.root.appendingPathComponent("nope/deeper").path))
    }

    @Test("a path under /Volumes belongs to that volume, which must be mounted")
    func volumeRule() {
        #expect(MissingWorktrees.volumeRoot(of: "/Volumes/Drive/code/wt") == "/Volumes/Drive")
        #expect(MissingWorktrees.volumeRoot(of: "/Volumes/My Drive/wt") == "/Volumes/My Drive")
        #expect(MissingWorktrees.volumeRoot(of: "/Users/someone/code/wt") == nil)
        #expect(MissingWorktrees.volumeRoot(of: "/Volumes") == nil)
        #expect(MissingWorktrees.isOnMountedVolume("/Users/someone/code/wt"))
        #expect(!MissingWorktrees.isOnMountedVolume("/Volumes/teebe-no-such-drive-\(UUID().uuidString)/wt"))
    }
}
