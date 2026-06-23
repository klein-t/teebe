import Testing
import Foundation
@testable import TreebranchCore

@Suite("Services (fakes)")
struct ServicesTests {
    let repo = Repository(path: "/repo", name: "repo")

    @Test("WorktreeService sorts primary first then by name")
    func worktreeSorting() async throws {
        let fake = FakeGitClient()
        fake.worktreesResult = [
            Worktree(path: "/repo/zeta", branch: "zeta"),
            Worktree(path: "/repo/main", branch: "main", isPrimary: true),
            Worktree(path: "/repo/alpha", branch: "alpha"),
        ]
        let service = WorktreeService(git: fake)
        let result = try await service.worktrees(for: repo)
        #expect(result.map(\.name) == ["main", "alpha", "zeta"])
    }

    @Test("WorktreeService.addWorktree forwards args")
    func addWorktree() async throws {
        let fake = FakeGitClient()
        let service = WorktreeService(git: fake)
        try await service.addWorktree(in: repo, at: "/repo/new", branch: "feat", createBranch: true)
        #expect(fake.addedWorktrees.count == 1)
        #expect(fake.addedWorktrees[0].path == "/repo/new")
        #expect(fake.addedWorktrees[0].branch == "feat")
        #expect(fake.addedWorktrees[0].createBranch == true)
    }

    @Test("DiffService picks staged diff for a purely-staged change")
    func diffPicksStaged() async throws {
        let fake = FakeGitClient()
        fake.workingDiffResult = DiffFile(newPath: "a.txt")
        let service = DiffService(git: fake)
        let staged = FileChange(path: "a.txt", indexStatus: .added, worktreeStatus: .unmodified)
        _ = try await service.diff(for: staged, worktreePath: "/repo")
        #expect(fake.workingDiffStagedFlags == [true])
    }

    @Test("DiffService picks unstaged diff for a worktree-modified change")
    func diffPicksUnstaged() async throws {
        let fake = FakeGitClient()
        fake.workingDiffResult = DiffFile(newPath: "a.txt")
        let service = DiffService(git: fake)
        let modified = FileChange(path: "a.txt", indexStatus: .unmodified, worktreeStatus: .modified)
        _ = try await service.diff(for: modified, worktreePath: "/repo")
        #expect(fake.workingDiffStagedFlags == [false])
    }

    @Test("BranchService lists a repo's branches")
    func branchesList() async throws {
        let fake = FakeGitClient()
        fake.branchesResult = [Branch(name: "main"), Branch(name: "develop")]
        let service = BranchService(git: fake)
        let names = try await service.branches(for: repo).map(\.name)
        #expect(names == ["main", "develop"])
    }
}
