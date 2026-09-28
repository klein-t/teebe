import Foundation
import Testing
@testable import TeebeCore

@Suite("New worktree location")
struct WorktreeLocationTests {
    private let repo = "/Users/dev/code/teebe"
    private let primary = Worktree(path: "/Users/dev/code/teebe", branch: "main", isPrimary: true)

    private func linked(_ path: String) -> Worktree { Worktree(path: path, branch: "x") }

    // MARK: - Parent folder

    @Test("the folder last chosen for the repository wins")
    func rememberedWins() {
        let parent = WorktreeLocation.parentFolder(
            repoPath: repo, remembered: "/Volumes/work/trees",
            worktrees: [primary, linked("/Users/dev/trees/teebe-a")])
        #expect(parent == "/Volumes/work/trees")
    }

    @Test("an empty remembered folder is ignored")
    func emptyRememberedIgnored() {
        #expect(WorktreeLocation.parentFolder(repoPath: repo, remembered: "", worktrees: [primary])
            == "/Users/dev/code")
    }

    @Test("linked worktrees sharing a parent folder set it")
    func sharedParent() {
        let parent = WorktreeLocation.parentFolder(
            repoPath: repo, remembered: nil,
            worktrees: [primary, linked("/Users/dev/trees/teebe-a"), linked("/Users/dev/trees/teebe-b")])
        #expect(parent == "/Users/dev/trees")
    }

    @Test("the primary checkout's own parent doesn't count as a linked worktree's")
    func primaryExcluded() {
        let parent = WorktreeLocation.parentFolder(
            repoPath: repo, remembered: nil,
            worktrees: [Worktree(path: "/elsewhere/teebe", isPrimary: true), linked("/Users/dev/trees/teebe-a")])
        #expect(parent == "/Users/dev/trees")
    }

    @Test("linked worktrees in different folders are ambiguous: fall back to a sibling")
    func ambiguousParent() {
        let parent = WorktreeLocation.parentFolder(
            repoPath: repo, remembered: nil,
            worktrees: [primary, linked("/Users/dev/trees/teebe-a"), linked("/tmp/teebe-b")])
        #expect(parent == "/Users/dev/code")
    }

    @Test("no linked worktrees: a sibling of the repository")
    func siblingFallback() {
        #expect(WorktreeLocation.parentFolder(repoPath: repo, remembered: nil, worktrees: [primary])
            == "/Users/dev/code")
        #expect(WorktreeLocation.parentFolder(repoPath: repo, remembered: nil, worktrees: [])
            == "/Users/dev/code")
    }

    @Test("a temporary directory is never suggested: macOS clears it", arguments: [
        "/tmp/trees", "/private/tmp/trees", "/var/folders/ab/xyz/T/trees", "/private/var/folders/ab/xyz/T/trees",
        (NSTemporaryDirectory() as NSString).appendingPathComponent("trees")
    ])
    func temporaryParentIgnored(temporary: String) {
        #expect(WorktreeLocation.parentFolder(repoPath: repo, remembered: temporary, worktrees: [primary])
            == "/Users/dev/code")
        let shared = WorktreeLocation.parentFolder(
            repoPath: repo, remembered: nil,
            worktrees: [primary, linked(temporary + "/teebe-a"), linked(temporary + "/teebe-b")])
        #expect(shared == "/Users/dev/code")
    }

    @Test("a folder merely named like a temporary one is still honoured")
    func lookalikeParentKept() {
        #expect(WorktreeLocation.parentFolder(repoPath: repo, remembered: "/Users/dev/tmp", worktrees: [primary])
            == "/Users/dev/tmp")
        #expect(WorktreeLocation.parentFolder(repoPath: repo, remembered: "/tmpfiles/trees", worktrees: [primary])
            == "/tmpfiles/trees")
    }

    // MARK: - Folder name

    @Test("the folder is named <repo>-<branch>, slashes flattened")
    func folderName() {
        #expect(WorktreeLocation.folderName(repoPath: repo, branch: "row-hover") == "teebe-row-hover")
        #expect(WorktreeLocation.folderName(repoPath: repo, branch: "feat/row/hover") == "teebe-feat-row-hover")
        #expect(WorktreeLocation.folderName(repoPath: repo, branch: "").isEmpty)
    }

    @Test("characters a folder name can't hold become dashes")
    func folderNameIsFilesystemSafe() {
        #expect(WorktreeLocation.folderName(repoPath: repo, branch: "a:b\\c") == "teebe-a-b-c")
    }

    // MARK: - Collisions

    @Test("a free path is used as is")
    func freePath() {
        #expect(WorktreeLocation.unique("/t/teebe-x") { _ in false } == "/t/teebe-x")
    }

    @Test("a taken path gets -2, -3, … until one is free")
    func suffixes() {
        let taken: Set = ["/t/teebe-x", "/t/teebe-x-2"]
        #expect(WorktreeLocation.unique("/t/teebe-x") { taken.contains($0) } == "/t/teebe-x-3")
    }

    // MARK: - Whole path

    @Test("the full path joins parent and name, and avoids collisions")
    func fullPath() {
        #expect(WorktreeLocation.path(parent: "/t", repoPath: repo, branch: "feat/a") { _ in false }
            == "/t/teebe-feat-a")
        #expect(WorktreeLocation.path(parent: "/t", repoPath: repo, branch: "feat/a") { $0 == "/t/teebe-feat-a" }
            == "/t/teebe-feat-a-2")
        #expect(WorktreeLocation.path(parent: "/t", repoPath: repo, branch: "") { _ in false }.isEmpty)
    }
}
