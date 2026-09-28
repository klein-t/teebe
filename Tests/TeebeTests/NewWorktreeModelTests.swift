import Testing
import Foundation
@testable import Teebe
import TeebeCore

@MainActor
@Suite("NewWorktreeModel")
struct NewWorktreeModelTests {
    private let repo = Repository(path: "/Users/k/code/teebe", name: "teebe")

    private let branches = [
        Branch(name: "main", isCurrent: true),
        Branch(name: "dev"),
        Branch(name: "feat/existing"),
        Branch(name: "origin/main", isRemote: true),
        Branch(name: "origin/dev", isRemote: true),
        Branch(name: "origin/HEAD", isRemote: true),
        Branch(name: "upstream/main", isRemote: true)
    ]

    private func model(
        comparison: String? = nil,
        primary: String? = "main",
        folderExists: @escaping @Sendable (String) -> Bool = { _ in false }
    ) -> NewWorktreeModel {
        NewWorktreeModel(repo: repo, branches: branches, comparisonBranch: comparison,
                         primaryBranch: primary, folderExists: folderExists)
    }

    // MARK: - Default location

    @Test("location is a sibling of the repo named after the branch")
    func defaultLocation() {
        let form = model()
        form.branch = "row-hover"
        #expect(form.location == "/Users/k/code/teebe-row-hover")
    }

    @Test("slashes in the branch flatten into dashes")
    func defaultLocationFlattensSlashes() {
        #expect(NewWorktreeModel.defaultLocation(repoPath: "/Users/k/code/teebe", branch: "feat/row/hover")
            == "/Users/k/code/teebe-feat-row-hover")
        #expect(NewWorktreeModel.defaultLocation(repoPath: "/Users/k/code/teebe", branch: "").isEmpty)
    }

    @Test("location tracks the branch until it's chosen by hand")
    func customLocationSticks() {
        let form = model()
        form.branch = "one"
        #expect(form.location == "/Users/k/code/teebe-one")
        form.setLocation("/tmp/elsewhere")
        form.branch = "two"
        #expect(form.location == "/tmp/elsewhere")
    }

    @Test("an existing folder blocks Create")
    func existingFolderBlocks() {
        let form = model(folderExists: { $0 == "/Users/k/code/teebe-taken" })
        form.branch = "taken"
        #expect(form.locationProblem == "Folder already exists.")
        #expect(form.canCreate == false)
        form.branch = "free"
        #expect(form.locationProblem == nil)
        #expect(form.canCreate)
    }

    // MARK: - Branch validation

    @Test("valid branch names pass")
    func validNames() {
        for name in ["main", "feat/row-hover", "v1.2", "a_b", "release/2026.09"] {
            #expect(NewWorktreeModel.isValidRefName(name), "\(name) should be valid")
        }
    }

    @Test("invalid branch names are rejected")
    func invalidNames() {
        for name in ["", " ", "has space", "a..b", "-lead", "trail/", "a@{b", "a\u{7}b",
                     "feat.lock", "feat/.hidden", "a//b", "@", "ends."] {
            #expect(NewWorktreeModel.isValidRefName(name) == false, "\(name) should be invalid")
        }
    }

    @Test("a name with a space reports the space, not a generic error")
    func spaceMessage() {
        let form = model()
        form.branch = "my branch"
        #expect(form.branchProblem == "Branch names can't contain spaces.")
        #expect(form.canCreate == false)
    }

    @Test("an empty branch simply can't be created")
    func emptyBranch() {
        let form = model()
        #expect(form.branchProblem == nil)
        #expect(form.canCreate == false)
    }

    // MARK: - Existing branches

    @Test("a local or origin branch of the same name is detected")
    func detectsExistingBranch() {
        #expect(NewWorktreeModel.existingBranch(named: "dev", in: branches) == "dev")
        #expect(NewWorktreeModel.existingBranch(named: "feat/existing", in: branches) == "feat/existing")
        #expect(NewWorktreeModel.existingBranch(named: "nope", in: branches) == nil)
        let remoteOnly = [Branch(name: "origin/release", isRemote: true)]
        #expect(NewWorktreeModel.existingBranch(named: "release", in: remoteOnly) == "origin/release")
    }

    @Test("an existing branch blocks Create until it's checked out instead")
    func existingBranchOffersCheckout() {
        let form = model()
        form.branch = "dev"
        #expect(form.branchProblem == "A branch named dev already exists.")
        #expect(form.canCreate == false)
        form.useExistingBranch = true
        #expect(form.branchProblem == nil)
        #expect(form.canCreate)
        #expect(form.isCreatingBranch == false)
        #expect(form.resolvedStartPoint == nil)
    }

    @Test("the existing-branch choice resets when the name changes")
    func existingChoiceResets() {
        let form = model()
        form.branch = "dev"
        form.useExistingBranch = true
        form.branch = "brand-new"
        #expect(form.useExistingBranch == false)
        #expect(form.isCreatingBranch)
    }

    // MARK: - Start point

    @Test("start points are local branches plus origin's, without HEAD")
    func startPointOptions() {
        #expect(NewWorktreeModel.startPointOptions(branches)
            == ["main", "dev", "feat/existing", "origin/main", "origin/dev"])
    }

    @Test("start from defaults to the comparison branch, then the primary branch")
    func startPointDefault() {
        #expect(model(comparison: "origin/dev").startPoint == "origin/dev")
        // A comparison branch that isn't offered falls through to the primary.
        #expect(model(comparison: "origin/gone").startPoint == "main")
        #expect(model(comparison: nil, primary: "feat/existing").startPoint == "feat/existing")
        #expect(NewWorktreeModel.defaultStartPoint(comparison: nil, primaryBranch: nil, options: []).isEmpty)
    }

    @Test("the chosen start point is passed on when creating a branch")
    func resolvedStartPoint() {
        let form = model(comparison: "origin/dev")
        form.branch = "feat/new"
        #expect(form.resolvedStartPoint == "origin/dev")
    }
}

@MainActor
@Suite("New worktree flow")
struct NewWorktreeFlowTests {
    @Test("creating forwards the branch, start point and location, then closes the sheet")
    func createsWorktree() async throws {
        let git = FakeGitClient()
        git.worktreesResult = [Worktree(path: "/repo", branch: "main", isPrimary: true)]
        git.branchesResult = [Branch(name: "main", isCurrent: true), Branch(name: "origin/dev", isRemote: true)]
        let app = AppModel(environment: makeTestEnvironment(git: git))
        await app.selector.selectRepo(Repository(path: "/repo"))
        app.presentNewWorktree()
        let form = try #require(app.newWorktree)
        form.branch = "feat/new"
        form.startPoint = "origin/dev"
        await app.createWorktree(form)

        #expect(git.addedWorktrees == [FakeGitClient.AddedWorktree(
            path: "/repo-feat-new", branch: "feat/new", createBranch: true, startPoint: "origin/dev")])
        #expect(app.newWorktree == nil)
    }

    @Test("checking out an existing branch creates no branch and no start point")
    func checksOutExistingBranch() async throws {
        let git = FakeGitClient()
        git.worktreesResult = [Worktree(path: "/repo", branch: "main", isPrimary: true)]
        git.branchesResult = [Branch(name: "main", isCurrent: true), Branch(name: "dev")]
        let app = AppModel(environment: makeTestEnvironment(git: git))
        await app.selector.selectRepo(Repository(path: "/repo"))
        app.presentNewWorktree()
        let form = try #require(app.newWorktree)
        form.branch = "dev"
        form.useExistingBranch = true
        await app.createWorktree(form)

        #expect(git.addedWorktrees == [FakeGitClient.AddedWorktree(
            path: "/repo-dev", branch: "dev", createBranch: false, startPoint: nil)])
    }
}
