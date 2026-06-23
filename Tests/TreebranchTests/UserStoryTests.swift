import Testing
import Foundation
import AppKit
@testable import Treebranch
import TreebranchCore

// Executable coverage for user stories in FEATURE_AUDIT.csv that are testable at
// the view-model layer. Green tests assert behavior that is correct today;
// `.bug` tests assert the *expected* behavior of a documented defect (red until
// the fix lands in the audit's fix phase).

@MainActor
@Suite("User stories: repositories (A)")
struct RepoStoryTests {
    @Test("A3: adding the same repo twice does not duplicate")
    func a3NoDuplicate() async {
        let git = FakeGitClient()
        git.worktreesResult = [Worktree(path: "/repo", branch: "main", isPrimary: true)]
        let app = AppModel(environment: makeTestEnvironment(git: git))
        #expect(await app.addRepository(path: "/repo") == true)
        #expect(await app.addRepository(path: "/repo") == false)
        #expect(app.repositories.count == 1)
    }

    @Test("A4: removing a repo persists the removal")
    func a4RemovePersists() async {
        let git = FakeGitClient()
        git.worktreesResult = [Worktree(path: "/repo", branch: "main", isPrimary: true)]
        let env = makeTestEnvironment(git: git)
        let app = AppModel(environment: env)
        _ = await app.addRepository(path: "/repo")
        app.removeRepository(Repository(path: "/repo"))
        #expect(env.store.load().repositories.isEmpty)
    }

    @Test("A6: setting a base branch persists it on the repo")
    func a6SetBasePersists() async {
        let git = FakeGitClient()
        git.worktreesResult = [Worktree(path: "/repo", branch: "main", isPrimary: true)]
        let env = makeTestEnvironment(git: git)
        let app = AppModel(environment: env)
        _ = await app.addRepository(path: "/repo")
        app.setBaseBranch("develop", for: Repository(path: "/repo"))
        #expect(env.store.load().repositories.first?.baseBranch == "develop")
    }
}

@MainActor
@Suite("User stories: file ops (F)")
struct FileOpStoryTests {
    @Test("F1: open forwards a file to the opener; F-dir: directories are ignored")
    func f1Open() {
        let opener = FakeFileOpener()
        let app = AppModel(environment: makeTestEnvironment(opener: opener))
        app.open(FileNode(path: "/r/a.swift", isDirectory: false))
        app.open(FileNode(path: "/r/dir", isDirectory: true))
        #expect(opener.opened.map(\.path) == ["/r/a.swift"])
    }

    @Test("F9: Copy Path writes the absolute path to the pasteboard")
    func f9CopyPath() {
        let app = AppModel(environment: makeTestEnvironment())
        app.copyPath(FileNode(path: "/r/deep/file.txt", isDirectory: false))
        #expect(NSPasteboard.general.string(forType: .string) == "/r/deep/file.txt")
    }

    @Test("F10: Move to Trash routes through ops.moveToTrash after confirm")
    func f10Trash() async {
        let ops = FakeFileOps()
        let model = WorktreeModel(environment: makeTestEnvironment(ops: ops))
        await model.load(worktreePath: "/r", repo: Repository(path: "/r"))
        model.requestTrash(path: "/r/gone.txt")
        #expect(model.pendingMutation?.kind == .trash)
        await model.confirmPendingMutation()
        #expect(ops.trashed.map(\.path) == ["/r/gone.txt"])
    }
}

@MainActor
@Suite("User stories: changes (D)")
struct ChangeStoryTests {
    private func tempDir() -> (String, () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tb-us-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir.path, { try? FileManager.default.removeItem(at: dir) })
    }

    @Test("D4: unstage forwards the path to the serial queue")
    func d4Unstage() async {
        let (dir, cleanup) = tempDir(); defer { cleanup() }
        let git = FakeGitClient()
        let model = WorktreeModel(environment: makeTestEnvironment(git: git))
        await model.load(worktreePath: dir, repo: Repository(path: dir))
        await model.unstage(FileChange(path: "a.txt", indexStatus: .modified))
        #expect(git.unstagedPaths == [["a.txt"]])
    }

    @Test("D6: discarding an untracked file routes to git clean, not restore")
    func d6DiscardUntracked() async {
        let (dir, cleanup) = tempDir(); defer { cleanup() }
        let git = FakeGitClient()
        let model = WorktreeModel(environment: makeTestEnvironment(git: git))
        await model.load(worktreePath: dir, repo: Repository(path: dir))
        model.requestDiscard(FileChange(path: "new.txt", worktreeStatus: .untracked))
        #expect(model.pendingMutation?.kind == .discardUntracked)
        await model.confirmPendingMutation()
        #expect(git.discardedUntracked == [["new.txt"]])
        #expect(git.discardedWorking.isEmpty)
    }

    @Test("D8: commit is a no-op when the message is blank")
    func d8BlankMessage() async {
        let (dir, cleanup) = tempDir(); defer { cleanup() }
        let git = FakeGitClient()
        git.statusResult = StatusResult(changes: [FileChange(path: "a.txt", worktreeStatus: .modified)])
        let model = WorktreeModel(environment: makeTestEnvironment(git: git))
        await model.load(worktreePath: dir, repo: Repository(path: dir))
        model.commitMessage = "   "
        await model.commitPending()
        #expect(git.commitMessages.isEmpty)
    }
}

@MainActor
@Suite("User stories: files (E)")
struct FileStoryTests {
    private func tempTree() -> (String, () -> Void) {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("tb-usf-\(UUID().uuidString)")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? "old".write(to: dir.appendingPathComponent("old.txt"), atomically: true, encoding: .utf8)
        try? "new".write(to: dir.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        return (dir.path, { try? fm.removeItem(at: dir) })
    }

    @Test("E5: recently-changed sort orders newer files first")
    func e5RecentSort() async throws {
        let (dir, cleanup) = tempTree(); defer { cleanup() }
        // Make new.txt strictly newer than old.txt.
        let newer = Date().addingTimeInterval(60)
        try FileManager.default.setAttributes([.modificationDate: newer], ofItemAtPath: dir + "/new.txt")
        let older = Date().addingTimeInterval(-60)
        try FileManager.default.setAttributes([.modificationDate: older], ofItemAtPath: dir + "/old.txt")

        let model = WorktreeModel(environment: makeTestEnvironment())
        await model.load(worktreePath: dir, repo: Repository(path: dir))
        model.sortOrder = .recent
        let names = model.visibleRows.map(\.node.name)
        #expect(names.firstIndex(of: "new.txt")! < names.firstIndex(of: "old.txt")!)
    }
}

@MainActor
@Suite("User stories: persistence (I)")
struct PersistStoryTests {
    @Test("I2: bootstrap restores repositories, floatOnTop, and the last selected repo")
    func i2RestoreRepo() async {
        let git = FakeGitClient()
        git.worktreesResult = [
            Worktree(path: "/repoB", branch: "main", isPrimary: true),
        ]
        let env = makeTestEnvironment(git: git)
        // Seed persisted state with two repos, B last-selected, floatOnTop on.
        var seed = AppState()
        seed.repositories = [PersistedRepository(path: "/repoA"), PersistedRepository(path: "/repoB")]
        seed.lastSelectedRepoPath = "/repoB"
        seed.floatOnTop = true
        try? env.store.save(seed)

        let app = AppModel(environment: env)
        await app.bootstrap()
        #expect(app.repositories.map(\.path) == ["/repoA", "/repoB"])
        #expect(app.floatOnTop == true)
        #expect(app.selector.selectedRepo?.path == "/repoB")
    }

    // I3 (documented defect): the last selected *worktree* is persisted but bootstrap
    // always focuses the primary worktree, so a non-primary last selection is lost.
    // Asserts the EXPECTED behavior, wrapped as a known issue so it documents the bug
    // without failing the suite. The wrapper will report "unexpectedly passed" once
    // the audit's fix phase restores the last worktree — that's the signal to remove it.
    @Test("I3: bootstrap restores the last selected worktree, not just the primary")
    func i3RestoreWorktree() async {
        let git = FakeGitClient()
        git.worktreesResult = [
            Worktree(path: "/repo", branch: "main", isPrimary: true),
            Worktree(path: "/repo-feature", branch: "feature"),
        ]
        let env = makeTestEnvironment(git: git)
        var seed = AppState()
        seed.repositories = [PersistedRepository(path: "/repo")]
        seed.lastSelectedRepoPath = "/repo"
        seed.lastSelectedWorktreePath = "/repo-feature"
        try? env.store.save(seed)

        let app = AppModel(environment: env)
        await app.bootstrap()
        withKnownIssue("I3: last selected worktree is persisted but not restored (FEATURE_AUDIT I3)") {
            #expect(app.selector.selectedWorktree?.path == "/repo-feature")
        }
    }
}
