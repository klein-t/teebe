import Testing
import Foundation
@testable import TeebeCore

/// Integration tests: `ProcessGitClient` against real throwaway repos.
@Suite("ProcessGitClient (integration)")
struct ProcessGitClientTests {
    let git = ProcessGitClient()

    // MARK: M1 — Worktree discovery

    @Test("discovers primary + linked worktrees")
    func worktreeDiscovery() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile("README.md", "# repo\n")
        fixture.addWorktree(name: "wt-feature", branch: "feature")

        let worktrees = try await git.worktrees(repoPath: fixture.repoPath)
        #expect(worktrees.count == 2)
        #expect(worktrees[0].isPrimary == true)
        #expect(worktrees[0].branch == "main")
        #expect(worktrees.contains { $0.branch == "feature" })
    }

    // MARK: M2 — Status & change model

    @Test("status reports working changes across kinds")
    func statusChanges() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile("tracked.txt", "line1\nline2\nline3\n")
        fixture.commitFile("todelete.txt", "bye\n")

        fixture.writeFile("tracked.txt", "line1\nCHANGED\nline3\n") // modified, unstaged
        fixture.writeFile("newstaged.txt", "new\n")
        fixture.stage(["newstaged.txt"])                            // added, staged
        fixture.writeFile("untracked.txt", "u\n")                   // untracked
        fixture.deleteFile("todelete.txt")                          // deleted, unstaged

        let status = try await git.status(worktreePath: fixture.repoPath)
        #expect(status.branch == "main")
        let byPath = Dictionary(uniqueKeysWithValues: status.changes.map { ($0.path, $0) })
        #expect(byPath["tracked.txt"]?.worktreeStatus == .modified)
        #expect(byPath["newstaged.txt"]?.indexStatus == .added)
        #expect(byPath["untracked.txt"]?.isUntracked == true)
        #expect(byPath["todelete.txt"]?.worktreeStatus == .deleted)
    }

    // MARK: M4 — Diffs

    @Test("working diff produces hunks with line numbers")
    func workingDiff() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile("tracked.txt", "line1\nline2\nline3\n")
        fixture.writeFile("tracked.txt", "line1\nline2 CHANGED\nline3\n")

        let diff = try await git.workingDiff(worktreePath: fixture.repoPath, path: "tracked.txt", staged: false)
        let file = try #require(diff)
        #expect(file.displayPath == "tracked.txt")
        #expect(file.addedCount == 1)
        #expect(file.removedCount == 1)
        #expect(file.hunks.first?.lines.contains { $0.content == "line2 CHANGED" && $0.kind == .addition } == true)
    }

    @Test("status on a non-git directory throws notAGitRepository")
    func notARepo() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("teebe-notrepo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        await #expect(throws: GitError.self) {
            _ = try await git.status(worktreePath: tmp.path)
        }
    }
}
