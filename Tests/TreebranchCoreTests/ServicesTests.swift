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

    @Test("BranchService resolves configured base when present")
    func resolveConfiguredBase() async throws {
        let fake = FakeGitClient()
        fake.branchesResult = [Branch(name: "main"), Branch(name: "develop")]
        let service = BranchService(git: fake)
        let configured = Repository(path: "/repo", baseBranch: "develop")
        let base = try await service.resolveBaseBranch(for: configured)
        #expect(base == "develop")
    }

    @Test("BranchService falls back to main")
    func resolveDefaultBase() async throws {
        let fake = FakeGitClient()
        fake.branchesResult = [Branch(name: "master"), Branch(name: "main"), Branch(name: "topic")]
        let service = BranchService(git: fake)
        let base = try await service.resolveBaseBranch(for: repo)
        #expect(base == "main")
    }

    @Test("BranchService throws missingBaseBranch when none match")
    func resolveMissingBase() async throws {
        let fake = FakeGitClient()
        fake.branchesResult = [Branch(name: "topic")]
        let service = BranchService(git: fake)
        await #expect(throws: GitError.self) {
            _ = try await service.resolveBaseBranch(for: repo)
        }
    }

    @Test("BranchService filters remotes from local names")
    func localNamesOnly() async throws {
        let fake = FakeGitClient()
        fake.branchesResult = [
            Branch(name: "main"),
            Branch(name: "origin/main", isRemote: true),
        ]
        let service = BranchService(git: fake)
        let names = try await service.localBranchNames(for: repo)
        #expect(names == ["main"])
    }
}
