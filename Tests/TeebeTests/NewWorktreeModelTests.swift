import Testing
import Foundation
@testable import Teebe
import TeebeCore

@MainActor
@Suite("NewWorktreeModel")
struct NewWorktreeModelTests {
    private let repo = Repository(path: "/Users/dev/code/teebe", name: "teebe")

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
        parent: String = "/Users/dev/code",
        registered: Set<String> = [],
        folderExists: @escaping @Sendable (String) -> Bool = { _ in false }
    ) -> NewWorktreeModel {
        NewWorktreeModel(repo: repo, branches: branches, comparisonBranch: comparison,
                         primaryBranch: primary, parentFolder: parent, registeredPaths: registered,
                         folderExists: folderExists)
    }

    // MARK: - Default location

    @Test("location is a sibling of the repo named after the branch")
    func defaultLocation() {
        let form = model()
        form.branch = "row-hover"
        #expect(form.location == "/Users/dev/code/teebe-row-hover")
    }

    @Test("slashes in the branch flatten into dashes, live as it's typed")
    func locationFollowsBranch() {
        let form = model()
        form.branch = "feat"
        #expect(form.location == "/Users/dev/code/teebe-feat")
        form.branch = "feat/row/hover"
        #expect(form.location == "/Users/dev/code/teebe-feat-row-hover")
        form.branch = ""
        #expect(form.location.isEmpty)
    }

    @Test("the pre-filled parent folder is used")
    func usesParentFolder() {
        let form = model(parent: "/Users/dev/trees")
        form.branch = "x"
        #expect(form.location == "/Users/dev/trees/teebe-x")
    }

    @Test("choosing a folder moves the worktree there; the name keeps following the branch")
    func chosenParentFolder() {
        let form = model()
        form.branch = "one"
        form.setParentFolder("/tmp/elsewhere")
        #expect(form.location == "/tmp/elsewhere/teebe-one")
        form.branch = "two"
        #expect(form.location == "/tmp/elsewhere/teebe-two")
    }

    @Test("a folder that exists, or a path git already registered, gets a -2 suffix")
    func collisionsGetSuffixed() {
        let onDisk = model(folderExists: { $0 == "/Users/dev/code/teebe-taken" })
        onDisk.branch = "taken"
        #expect(onDisk.location == "/Users/dev/code/teebe-taken-2")
        #expect(onDisk.locationProblem == nil)
        let registered = model(registered: ["/Users/dev/code/teebe-gone"])
        registered.branch = "gone"
        #expect(registered.location == "/Users/dev/code/teebe-gone-2")
    }

    @Test("a repository with no remote still gets a location")
    func noRemote() {
        let form = NewWorktreeModel(repo: repo, branches: [Branch(name: "main", isCurrent: true)],
                                    comparisonBranch: nil, primaryBranch: "main",
                                    parentFolder: "/Users/dev/code", folderExists: { _ in false })
        form.branch = "feat/local"
        #expect(form.location == "/Users/dev/code/teebe-feat-local")
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

    @Test("the sheet pre-fills the folder the other linked worktrees share")
    func prefillsSharedParent() async throws {
        let git = FakeGitClient()
        git.worktreesResult = [Worktree(path: "/code/repo", branch: "main", isPrimary: true),
                               Worktree(path: "/trees/repo-a", branch: "a")]
        git.branchesResult = [Branch(name: "main", isCurrent: true)]
        let app = AppModel(environment: makeTestEnvironment(git: git))
        await app.selector.selectRepo(Repository(path: "/code/repo"))
        app.presentNewWorktree()
        let form = try #require(app.newWorktree)
        form.branch = "feat/b"
        #expect(form.location == "/trees/repo-feat-b")
    }

    @Test("a chosen folder is remembered for the repository and pre-filled next time")
    func remembersChosenParent() async throws {
        let git = FakeGitClient()
        git.worktreesResult = [Worktree(path: "/code/repo", branch: "main", isPrimary: true)]
        git.branchesResult = [Branch(name: "main", isCurrent: true)]
        let env = makeTestEnvironment(git: git)
        let app = AppModel(environment: env)
        await app.selector.selectRepo(Repository(path: "/code/repo"))
        app.presentNewWorktree()
        let first = try #require(app.newWorktree)
        #expect(first.parentFolder == "/code")
        app.setWorktreeParent("/chosen", for: first)
        #expect(first.parentFolder == "/chosen")
        app.newWorktree = nil

        // A fresh app over the same saved state.
        let relaunched = AppModel(environment: env)
        await relaunched.selector.selectRepo(Repository(path: "/code/repo"))
        relaunched.presentNewWorktree()
        let second = try #require(relaunched.newWorktree)
        second.branch = "x"
        #expect(second.location == "/chosen/repo-x")
    }
}
