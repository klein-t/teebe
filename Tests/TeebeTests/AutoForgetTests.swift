import Foundation
import Testing
@testable import Teebe
import TeebeCore

/// Folders the tests delete, bring back, or disconnect while the app reads them.
private final class Disk: @unchecked Sendable {
    private let lock = NSLock()
    private var gone: Set<String>
    private var unmounted: Set<String> = []
    init(gone: Set<String> = []) { self.gone = gone }
    func delete(_ path: String) { lock.lock(); gone.insert(path); lock.unlock() }
    func unmount(_ path: String) { lock.lock(); unmounted.insert(path); lock.unlock() }
    func exists(_ path: String) -> Bool { lock.lock(); defer { lock.unlock() }; return !gone.contains(path) }
    func isMounted(_ path: String) -> Bool { lock.lock(); defer { lock.unlock() }; return !unmounted.contains(path) }
}

/// Worktrees whose folder is gone: forgotten automatically when deleted, hidden
/// when only out of reach, with a calm notice for what was cleaned up.
@MainActor
@Suite("Auto-forget deleted worktrees")
struct AutoForgetTests {
    private let repo = Repository(path: "/repo")
    private let primary = Worktree(path: "/repo", branch: "main", isPrimary: true)
    private let kept = Worktree(path: "/kept", branch: "kept")
    private let gone = Worktree(path: "/gone", branch: "gone")
    private let alsoGone = Worktree(path: "/also-gone", branch: "also-gone")

    private func selector(_ git: FakeGitClient, disk: Disk) -> SelectorModel {
        SelectorModel(environment: makeTestEnvironment(git: git, folderExists: { disk.exists($0) },
                                                       isVolumeMounted: { disk.isMounted($0) }))
    }

    @Test("a deleted folder is forgotten on load, its row disappears and the notice counts it")
    func deletedIsForgotten() async {
        let git = FakeGitClient()
        git.worktreesResult = [primary, kept, gone]
        let selector = selector(git, disk: Disk(gone: [gone.path]))
        await selector.selectRepo(repo)

        #expect(selector.worktrees.map(\.path) == [primary.path, kept.path])
        #expect(git.removedWorktrees == [gone.path])
        #expect(selector.cleanupNotice == "Cleaned up 1 worktree whose folder was deleted.")
    }

    @Test("several deleted folders are forgotten one record at a time, and the notice counts them all")
    func noticeCount() async {
        let git = FakeGitClient()
        git.worktreesResult = [primary, kept, gone, alsoGone]
        let selector = selector(git, disk: Disk(gone: [gone.path, alsoGone.path]))
        await selector.selectRepo(repo)

        #expect(Set(git.removedWorktrees) == [gone.path, alsoGone.path])
        #expect(git.removedWorktrees.count == 2)
        #expect(selector.cleanupNotice == "Cleaned up 2 worktrees whose folders were deleted.")
        selector.dismissCleanupNotice()
        #expect(selector.cleanupNotice == nil)
    }

    @Test("a folder on a volume that isn't mounted is hidden, never forgotten, and comes back with the drive")
    func unmountedIsHidden() async {
        let git = FakeGitClient()
        git.worktreesResult = [primary, kept, gone]
        let disk = Disk(gone: [gone.path])
        disk.unmount(gone.path)
        let selector = selector(git, disk: disk)
        await selector.selectRepo(repo)

        #expect(selector.worktrees.map(\.path) == [primary.path, kept.path])
        #expect(git.removedWorktrees.isEmpty)
        #expect(selector.cleanupNotice == nil)
    }

    @Test("a locked worktree whose folder is gone is hidden and never forgotten")
    func lockedIsHidden() async {
        let git = FakeGitClient()
        var locked = gone
        locked.isLocked = true
        git.worktreesResult = [primary, kept, locked]
        let selector = selector(git, disk: Disk(gone: [gone.path]))
        await selector.selectRepo(repo)

        #expect(selector.worktrees.map(\.path) == [primary.path, kept.path])
        #expect(git.removedWorktrees.isEmpty)
        #expect(selector.cleanupNotice == nil)
    }

    @Test("a deleted worktree whose record still holds work is listed with why, and never forgotten")
    func heldWorkIsKeptAndShown() async {
        let git = FakeGitClient()
        let orphan = Worktree(path: "/orphan", head: "abc", isDetached: true)
        git.worktreesResult = [primary, kept, gone, orphan]
        let disk = Disk(gone: [gone.path, orphan.path])
        let selector = SelectorModel(environment: makeTestEnvironment(
            git: git, folderExists: { disk.exists($0) }, isVolumeMounted: { disk.isMounted($0) },
            holdsUnsavedWork: { worktree, _ in worktree.path == "/orphan" }))
        await selector.selectRepo(repo)

        #expect(selector.worktrees.map(\.path) == [primary.path, kept.path, orphan.path])
        #expect(git.removedWorktrees == [gone.path])
        #expect(selector.keptMissingPaths == [orphan.path])
        #expect(selector.info(for: orphan).isKeptMissing)
        // Its row says why it stays, with the broken mark even inside a group.
        let status = WorktreeStatus(worktree: orphan, merge: nil, info: selector.info(for: orphan),
                                    targetNames: ["main"], isChecking: false)
        #expect(status.mark == .brokenLink)
        #expect(status.rowMark(grouped: true) == .brokenLink)
        #expect(status.card.title == "Folder missing")
        #expect(status.card.subtitle == "It holds work no branch has, so Teebe keeps its record.")
        #expect(!status.removal.canRemoveFolder)
        // Asking to forget it from its placeholder is refused too.
        await selector.forgetMissingWorktree(orphan.path)
        #expect(git.removedWorktrees == [gone.path])
        #expect(selector.worktrees.contains { $0.path == orphan.path })
    }

    @Test("the primary checkout is never forgotten or hidden")
    func primaryIsKept() async {
        let git = FakeGitClient()
        git.worktreesResult = [primary, kept]
        let selector = selector(git, disk: Disk(gone: [primary.path]))
        await selector.selectRepo(repo)

        #expect(selector.worktrees.map(\.path) == [primary.path, kept.path])
        #expect(git.removedWorktrees.isEmpty)
    }

    @Test("nothing is forgotten while a removal is running; the next load catches up")
    func notDuringRemoval() async {
        let git = FakeGitClient()
        git.worktreesResult = [primary, kept, gone]
        let selector = selector(git, disk: Disk(gone: [gone.path]))
        var removing = true
        selector.isRemovalRunning = { removing }
        await selector.selectRepo(repo)
        #expect(selector.worktrees.map(\.path) == [primary.path, kept.path])
        #expect(git.removedWorktrees.isEmpty)
        #expect(selector.cleanupNotice == nil)

        removing = false
        await selector.refreshWorktrees()
        #expect(git.removedWorktrees == [gone.path])
        #expect(selector.cleanupNotice == "Cleaned up 1 worktree whose folder was deleted.")
    }

    @Test("a record Git won't forget stays hidden, quietly, and isn't retried on every refresh")
    func failureIsQuietAndRateLimited() async {
        let git = FakeGitClient()
        git.worktreesResult = [primary, kept, gone]
        git.removeWorktreeErrors[gone.path] = .commandFailed(command: ["git"], exitCode: 128, stderr: "fatal: nope")
        let selector = selector(git, disk: Disk(gone: [gone.path]))
        await selector.selectRepo(repo)
        await selector.refreshWorktrees()
        await selector.refreshWorktrees()

        #expect(git.removedWorktrees == [gone.path])
        #expect(selector.worktrees.map(\.path) == [primary.path, kept.path])
        #expect(selector.cleanupNotice == nil)
        #expect(selector.errorMessage == nil)

        selector.forgetRetryInterval = 0
        await selector.refreshWorktrees()
        #expect(git.removedWorktrees == [gone.path, gone.path])
    }

    @Test("switching repositories drops the previous repository's notice")
    func noticeIsPerRepository() async {
        let git = FakeGitClient()
        git.worktreesResult = [primary, gone]
        let selector = selector(git, disk: Disk(gone: [gone.path]))
        await selector.selectRepo(repo)
        #expect(selector.cleanupNotice != nil)

        git.worktreesResult = [Worktree(path: "/other", branch: "main", isPrimary: true)]
        await selector.selectRepo(Repository(path: "/other"))
        #expect(selector.cleanupNotice == nil)
    }

    @Test("a folder deleted while listed is cleaned up as soon as its files change")
    func deletionEventCleansUp() async {
        let git = FakeGitClient()
        git.worktreesResult = [primary, kept, gone]
        let disk = Disk()
        let selector = selector(git, disk: disk)
        await selector.selectRepo(repo)
        await selector.selectWorktree(gone)
        #expect(selector.worktrees.count == 3)

        disk.delete(gone.path)
        await selector.handleWorktreeFileEvents([gone.path + "/notes.txt"])

        #expect(git.removedWorktrees == [gone.path])
        #expect(selector.worktrees.map(\.path) == [primary.path, kept.path])
        #expect(selector.selectedWorktree?.path == primary.path)
        #expect(selector.cleanupNotice == "Cleaned up 1 worktree whose folder was deleted.")
    }

    @Test("the placeholder's Forget forgets just the one record it stands for")
    func placeholderForgetsOne() async {
        let git = FakeGitClient()
        git.worktreesResult = [primary, kept, gone, alsoGone]
        let disk = Disk()
        let selector = selector(git, disk: disk)
        await selector.selectRepo(repo)
        await selector.selectWorktree(gone)
        disk.delete(gone.path)
        disk.delete(alsoGone.path)
        await selector.worktree.refresh()
        #expect(selector.worktree.isFolderMissing)

        await selector.forgetMissingWorktree(gone.path)

        #expect(git.removedWorktrees.first == gone.path)
        #expect(selector.selectedWorktree?.path == primary.path)
        #expect(!selector.worktrees.contains { $0.path == gone.path })
    }

    @Test("the placeholder's Forget leaves a folder that came back alone")
    func placeholderRechecks() async {
        let git = FakeGitClient()
        git.worktreesResult = [primary, kept]
        let disk = Disk()
        let selector = selector(git, disk: disk)
        await selector.selectRepo(repo)
        await selector.selectWorktree(kept)

        await selector.forgetMissingWorktree(kept.path)
        #expect(git.removedWorktrees.isEmpty)
        #expect(selector.worktrees.map(\.path) == [primary.path, kept.path])
    }
}

/// The same flow against a real repository: what Teebe forgets on load is the
/// deleted worktree's record alone.
@MainActor
@Suite("Auto-forget deleted worktrees (real git)")
struct AutoForgetIntegrationTests {
    @Test("on load, a deleted worktree is forgotten, its branch kept; an unlinked folder, and a deleted one holding a commit, stay listed")
    func realRepository() async throws {
        let root = URL(fileURLWithPath: PathUtil.standardized(FileManager.default.temporaryDirectory.path))
            .appendingPathComponent("teebe-autoforget-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        for arguments in [["init", "-q", "-b", "main"], ["config", "user.email", "test@teebe.local"],
                          ["config", "user.name", "Teebe Test"], ["config", "commit.gpgsign", "false"],
                          ["commit", "-q", "--allow-empty", "-m", "init"]] {
            git(arguments, in: repo)
        }
        for name in ["gone", "also-gone", "unlinked", "kept"] {
            git(["worktree", "add", "-q", "-b", name, root.appendingPathComponent(name).path], in: repo)
        }
        // A detached checkout with a commit of its own: its record is the only thing holding that commit.
        let orphan = root.appendingPathComponent("orphan")
        git(["worktree", "add", "-q", "--detach", orphan.path], in: repo)
        git(["commit", "-q", "--allow-empty", "-m", "only here"], in: orphan)
        try FileManager.default.removeItem(at: orphan)
        try FileManager.default.removeItem(at: root.appendingPathComponent("gone"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("also-gone"))
        try Data("draft".utf8).write(to: root.appendingPathComponent("unlinked/draft.txt"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("unlinked/.git"))

        let storeURL = root.appendingPathComponent("state/state.json")
        let environment = AppEnvironment(git: ProcessGitClient(), opener: FakeFileOpener(), ops: FakeFileOps(),
                                         store: AppStateStore(url: storeURL), activityMonitor: WorktreeActivityMonitor(),
                                         makeWatcher: { FakeWatcher() })
        let selector = SelectorModel(environment: environment)
        await selector.selectRepo(Repository(path: repo.path))

        #expect(selector.worktrees.map(\.name) == ["repo", "kept", "orphan", "unlinked"])
        #expect(selector.keptMissingPaths.map { ($0 as NSString).lastPathComponent } == ["orphan"])
        #expect(selector.cleanupNotice == "Cleaned up 2 worktrees whose folders were deleted.")
        let listed = git(["worktree", "list", "--porcelain"], in: repo)
        #expect(!listed.contains("/gone\n"))
        #expect(!listed.contains("/also-gone\n"))
        #expect(listed.contains("/unlinked\n"))
        #expect(listed.contains("/orphan\n"))
        #expect(git(["branch", "--list", "gone"], in: repo).contains("gone"))
        #expect(git(["branch", "--list", "also-gone"], in: repo).contains("also-gone"))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("unlinked/draft.txt").path))
    }

    @discardableResult
    private func git(_ arguments: [String], in directory: URL) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = (environment["PATH"].map { "\($0):/usr/bin:/bin" }) ?? "/usr/bin:/bin"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try? process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(bytes: data, encoding: .utf8) ?? ""
    }
}
