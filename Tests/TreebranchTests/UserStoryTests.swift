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

    @Test("D7b: commit stages the unstaged half of a partially-staged file")
    func d7PartialStaged() async {
        let (dir, cleanup) = tempDir(); defer { cleanup() }
        let git = FakeGitClient()
        git.statusResult = StatusResult(changes: [
            FileChange(path: "partial.txt", indexStatus: .modified, worktreeStatus: .modified),
            FileChange(path: "stagedonly.txt", indexStatus: .added, worktreeStatus: .unmodified),
        ])
        let model = WorktreeModel(environment: makeTestEnvironment(git: git))
        await model.load(worktreePath: dir, repo: Repository(path: dir))
        model.commitMessage = "msg"
        await model.commitPending()
        // Only partial.txt has an unstaged delta to add; stagedonly.txt is already staged.
        #expect(git.stagedPaths == [["partial.txt"]])
        #expect(git.commitMessages == ["msg"])
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
        #expect(app.selector.selectedWorktree?.path == "/repo-feature")
    }

    @Test("I1: switching the selected worktree persists it durably (no quit hook needed)")
    func i1PersistSelection() async {
        let git = FakeGitClient()
        git.worktreesResult = [
            Worktree(path: "/repo", branch: "main", isPrimary: true),
            Worktree(path: "/repo-feature", branch: "feature"),
        ]
        let env = makeTestEnvironment(git: git)
        let app = AppModel(environment: env)
        _ = await app.addRepository(path: "/repo")   // selects primary
        await app.selector.selectWorktree(Worktree(path: "/repo-feature", branch: "feature"))
        // Persisted immediately on selection — survives a relaunch with no terminate hook.
        let saved = env.store.load()
        #expect(saved.lastSelectedRepoPath == "/repo")
        #expect(saved.lastSelectedWorktreePath == "/repo-feature")
    }
}

@MainActor
@Suite("User stories: live & activity (C/J)")
struct LiveActivityStoryTests {
    private func tempDir() -> (String, () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tb-la-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir.path, { try? FileManager.default.removeItem(at: dir) })
    }

    @Test("J2: a file-watch event during teebe's own write is NOT recorded as activity")
    func j2SelfWriteSuppressed() async {
        let (dir, cleanup) = tempDir(); defer { cleanup() }
        let monitor = WorktreeActivityMonitor()
        let model = WorktreeModel(environment: makeTestEnvironment(monitor: monitor))
        await model.load(worktreePath: dir, repo: Repository(path: dir))
        let t = Date(timeIntervalSince1970: 1000)
        model.noteSelfWrite(at: t)
        await model.handleFileSystemEvent(now: t.addingTimeInterval(0.2))   // inside ignore window
        #expect(monitor.isBusy(worktreePath: dir, within: 5, now: t.addingTimeInterval(0.3)) == false)
    }

    @Test("J2: an external file-watch event IS recorded and notifies onActivity")
    func j2ExternalRecorded() async {
        let (dir, cleanup) = tempDir(); defer { cleanup() }
        let monitor = WorktreeActivityMonitor()
        let model = WorktreeModel(environment: makeTestEnvironment(monitor: monitor))
        await model.load(worktreePath: dir, repo: Repository(path: dir))
        var notified: String?
        model.onActivity = { notified = $0 }
        let t = Date(timeIntervalSince1970: 2000)
        await model.handleFileSystemEvent(now: t)   // no prior self-write
        #expect(monitor.isBusy(worktreePath: dir, within: 5, now: t.addingTimeInterval(1)) == true)
        #expect(notified == dir)
    }

    @Test("C4: refreshLiveState lights a worktree the activity monitor reports busy")
    func c4RefreshLive() async {
        let git = FakeGitClient()
        git.worktreesResult = [Worktree(path: "/repo", branch: "main", isPrimary: true)]
        let monitor = WorktreeActivityMonitor()
        let selector = SelectorModel(environment: makeTestEnvironment(git: git, monitor: monitor))
        await selector.selectRepo(Repository(path: "/repo"))
        #expect(selector.info(for: Worktree(path: "/repo")).isLive == false)
        let t = Date(timeIntervalSince1970: 3000)
        monitor.recordActivity(worktreePath: "/repo", at: t)
        selector.refreshLiveState(now: t.addingTimeInterval(1))
        #expect(selector.info(for: Worktree(path: "/repo")).isLive == true)
    }
}
