import Testing
import Foundation
@testable import Teebe
import TeebeCore

@MainActor
@Suite("AppModel")
struct AppModelTests {
    @Test("adding a valid git repo records and persists it")
    func addRepo() async {
        let git = FakeGitClient()
        git.worktreesResult = [Worktree(path: "/repo", branch: "main", isPrimary: true)]
        let env = makeTestEnvironment(git: git)
        let app = AppModel(environment: env)

        let added = await app.addRepository(path: "/repo")
        #expect(added == true)
        #expect(app.repositories.map(\.path) == ["/repo"])
        // Persisted.
        #expect(env.store.load().repositories.map(\.path) == ["/repo"])
    }

    @Test("adding a non-git directory is rejected")
    func addNonRepo() async {
        let git = FakeGitClient()
        git.worktreesError = .notAGitRepository(path: "/x")
        let app = AppModel(environment: makeTestEnvironment(git: git))

        let added = await app.addRepository(path: "/x")
        #expect(added == false)
        #expect(app.repositories.isEmpty)
        #expect(app.errorMessage != nil)
    }

    @Test("removing a repo clears it and selection")
    func removeRepo() async {
        let git = FakeGitClient()
        git.worktreesResult = [Worktree(path: "/repo", branch: "main", isPrimary: true)]
        let app = AppModel(environment: makeTestEnvironment(git: git))
        _ = await app.addRepository(path: "/repo")

        app.removeRepository(Repository(path: "/repo"))
        #expect(app.repositories.isEmpty)
        #expect(app.selector.selectedRepo == nil)
    }
}

@MainActor
@Suite("SelectorModel")
struct SelectorModelTests {
    @Test("selecting a repo loads worktrees + branches and focuses primary")
    func selectRepo() async {
        let git = FakeGitClient()
        git.worktreesResult = [
            Worktree(path: "/repo", branch: "main", isPrimary: true),
            Worktree(path: "/repo-wt", branch: "feature"),
        ]
        git.branchesResult = [Branch(name: "main", isCurrent: true), Branch(name: "feature")]
        let selector = SelectorModel(environment: makeTestEnvironment(git: git))

        await selector.selectRepo(Repository(path: "/repo"))
        #expect(selector.worktrees.count == 2)
        #expect(selector.branches.count == 2)
        #expect(selector.selectedWorktree?.isPrimary == true)
        #expect(selector.worktree.worktreePath == "/repo")
    }

    @Test("live dot lights for a worktree written to within the window, off after it")
    func liveDotWindow() async {
        let git = FakeGitClient()
        git.worktreesResult = [
            Worktree(path: "/repo", branch: "main", isPrimary: true),
            Worktree(path: "/repo-wt", branch: "feature")
        ]
        let monitor = WorktreeActivityMonitor()
        let selector = SelectorModel(environment: makeTestEnvironment(git: git, monitor: monitor))
        await selector.selectRepo(Repository(path: "/repo"))

        let t = Date(timeIntervalSince1970: 1000)
        monitor.recordActivity(worktreePath: "/repo-wt", at: t)

        // Just after the write: only the written-to worktree's dot is live.
        selector.refreshLiveState(now: t.addingTimeInterval(2))
        #expect(selector.info(for: git.worktreesResult[1]).isLive == true)
        #expect(selector.info(for: git.worktreesResult[0]).isLive == false)

        // Once the window elapses, the dot goes idle again.
        selector.refreshLiveState(now: t.addingTimeInterval(5))
        #expect(selector.info(for: git.worktreesResult[1]).isLive == false)
    }

    @Test("refreshWorktreeInfo computes live state alongside sync counts")
    func liveDotViaRefreshInfo() async {
        let git = FakeGitClient()
        git.worktreesResult = [Worktree(path: "/repo", branch: "main", isPrimary: true)]
        let monitor = WorktreeActivityMonitor()
        let selector = SelectorModel(environment: makeTestEnvironment(git: git, monitor: monitor))
        await selector.selectRepo(Repository(path: "/repo"))

        let t = Date(timeIntervalSince1970: 1000)
        monitor.recordActivity(worktreePath: "/repo", at: t)
        await selector.refreshWorktreeInfo(now: t.addingTimeInterval(1))
        #expect(selector.info(for: git.worktreesResult[0]).isLive == true)
    }
}

@MainActor
@Suite("WorktreeModel")
struct WorktreeModelTests {
    private func tempDir() -> (String, () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tb-wt-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir.path, { try? FileManager.default.removeItem(at: dir) })
    }

    @Test("load populates status, changes and overlaid tree")
    func load() async {
        let (dir, cleanup) = tempDir(); defer { cleanup() }
        try? "x".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)

        let git = FakeGitClient()
        git.statusResult = StatusResult(branch: "main", changes: [
            FileChange(path: "a.txt", worktreeStatus: .modified),
        ])
        let model = WorktreeModel(environment: makeTestEnvironment(git: git))
        await model.load(worktreePath: dir, repo: Repository(path: dir))

        #expect(model.changes.count == 1)
        #expect(model.changeCount == 1)
        let aNode = model.root?.children?.first { $0.name == "a.txt" }
        #expect(aNode?.change?.worktreeStatus == .modified)
    }

    @Test("changed filter derives a tree from the change list")
    func changedFilter() async {
        let (dir, cleanup) = tempDir(); defer { cleanup() }
        let git = FakeGitClient()
        git.statusResult = StatusResult(changes: [
            FileChange(path: "src/changed.swift", worktreeStatus: .modified),
        ])
        let model = WorktreeModel(environment: makeTestEnvironment(git: git))
        await model.load(worktreePath: dir, repo: Repository(path: dir))
        model.filter = .changed

        let display = model.displayRoot
        let src = display?.children?.first { $0.name == "src" }
        #expect(src?.children?.first?.name == "changed.swift")
    }

    @Test("stage forwards to the serial queue")
    func stage() async {
        let (dir, cleanup) = tempDir(); defer { cleanup() }
        let git = FakeGitClient()
        let model = WorktreeModel(environment: makeTestEnvironment(git: git))
        await model.load(worktreePath: dir, repo: Repository(path: dir))

        await model.stage(FileChange(path: "a.txt", worktreeStatus: .modified))
        #expect(git.stagedPaths == [["a.txt"]])
    }

    @Test("discard requires confirmation and flags a busy worktree")
    func guardedDiscard() async {
        let (dir, cleanup) = tempDir(); defer { cleanup() }
        let git = FakeGitClient()
        let monitor = WorktreeActivityMonitor()
        let now = Date(timeIntervalSince1970: 1000)
        monitor.recordActivity(worktreePath: dir, at: now)
        let model = WorktreeModel(environment: makeTestEnvironment(git: git, monitor: monitor))
        await model.load(worktreePath: dir, repo: Repository(path: dir))

        model.requestDiscard(FileChange(path: "a.txt", worktreeStatus: .modified), now: now.addingTimeInterval(1))
        #expect(model.pendingMutation?.kind == .discard)
        #expect(model.pendingMutation?.worktreeBusy == true)
        #expect(git.discardedWorking.isEmpty) // not executed until confirmed

        await model.confirmPendingMutation()
        #expect(model.pendingMutation == nil)
        #expect(git.discardedWorking == [["a.txt"]])
    }
}

@MainActor
@Suite("WorktreeModel tree navigation")
struct WorktreeNavigationTests {
    private func tempTree() -> (String, () -> Void) {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("tb-nav-\(UUID().uuidString)")
        try? fm.createDirectory(at: dir.appendingPathComponent("src"), withIntermediateDirectories: true)
        try? "a".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try? "b".write(to: dir.appendingPathComponent("src/b.txt"), atomically: true, encoding: .utf8)
        return (dir.path, { try? fm.removeItem(at: dir) })
    }

    @Test("expanding a directory reveals its children in visibleRows")
    func expandReveals() async throws {
        let (dir, cleanup) = tempTree(); defer { cleanup() }
        let model = WorktreeModel(environment: makeTestEnvironment())
        await model.load(worktreePath: dir, repo: Repository(path: dir))

        #expect(model.visibleRows.contains { $0.node.name == "b.txt" } == false)
        let src = try #require(model.visibleRows.first { $0.node.name == "src" }).node
        model.toggleExpand(src)
        let bRow = model.visibleRows.first { $0.node.name == "b.txt" }
        #expect(bRow != nil)
        #expect(bRow?.depth == 1)
    }

    @Test("arrow selection moves through visible rows")
    func arrowSelection() async {
        let (dir, cleanup) = tempTree(); defer { cleanup() }
        let model = WorktreeModel(environment: makeTestEnvironment())
        await model.load(worktreePath: dir, repo: Repository(path: dir))

        model.selectNext()
        let first = model.selectedPath
        #expect(first != nil)
        model.selectNext()
        #expect(model.selectedPath != first)
        model.selectPrevious()
        #expect(model.selectedPath == first)
    }

    @Test("search filters to matching files")
    func search() async {
        let (dir, cleanup) = tempTree(); defer { cleanup() }
        let model = WorktreeModel(environment: makeTestEnvironment())
        await model.load(worktreePath: dir, repo: Repository(path: dir))
        // Expand so src/b.txt is loaded into the search space.
        if let src = model.visibleRows.first(where: { $0.node.name == "src" })?.node { model.toggleExpand(src) }

        model.searchQuery = "b.txt"
        #expect(model.visibleRows.map(\.node.name) == ["b.txt"])
    }

    @Test("changeGroups groups changes by folder")
    func changeGroups() async {
        let (dir, cleanup) = tempTree(); defer { cleanup() }
        let git = FakeGitClient()
        git.statusResult = StatusResult(changes: [
            FileChange(path: "src/b.txt", worktreeStatus: .modified),
            FileChange(path: "a.txt", worktreeStatus: .added),
        ])
        let model = WorktreeModel(environment: makeTestEnvironment(git: git))
        await model.load(worktreePath: dir, repo: Repository(path: dir))

        let folders = model.changeGroups.map(\.folder)
        #expect(folders.contains("src"))
        #expect(folders.contains(""))
    }

    @Test("commitPending stages and commits, then clears the message")
    func commitPending() async {
        let (dir, cleanup) = tempTree(); defer { cleanup() }
        let git = FakeGitClient()
        git.statusResult = StatusResult(changes: [FileChange(path: "a.txt", worktreeStatus: .modified)])
        let model = WorktreeModel(environment: makeTestEnvironment(git: git))
        await model.load(worktreePath: dir, repo: Repository(path: dir))

        model.commitMessage = "my commit"
        await model.commitPending()
        #expect(git.commitMessages == ["my commit"])
        #expect(git.stagedPaths.contains(["a.txt"]))
        #expect(model.commitMessage.isEmpty)
    }
}

@MainActor
@Suite("PreviewModel")
struct PreviewModelTests {
    @Test("changed file resolves to a diff; toggling again hides it")
    func diffToggle() async {
        let git = FakeGitClient()
        git.workingDiffResult = DiffFile(newPath: "a.swift", status: .modified)
        let model = PreviewModel(environment: makeTestEnvironment(git: git))
        let node = FileNode(path: "/repo/a.swift", isDirectory: false,
                            change: FileChange(path: "a.swift", worktreeStatus: .modified))

        await model.toggle(for: node, worktreePath: "/repo")
        #expect(model.isVisible == true)
        if case .diff = model.content {} else { Issue.record("expected diff content") }

        await model.toggle(for: node, worktreePath: "/repo")
        #expect(model.isVisible == false)
        #expect(model.content == .empty)
    }

    @Test("unchanged text file previews its content")
    func textPreview() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tb-prev-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("notes.md")
        try? "hello preview".write(to: file, atomically: true, encoding: .utf8)

        let model = PreviewModel(environment: makeTestEnvironment())
        let node = FileNode(path: file.path, isDirectory: false)
        await model.toggle(for: node, worktreePath: dir.path)
        #expect(model.content == .text("hello preview"))
    }
}
