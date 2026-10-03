import Foundation
import Testing
@testable import TeebeCore

@Suite("Worktree cleanup")
struct WorktreeCleanupTests {
    @Test("the remote default is found and exact refs resolve")
    func targets() {
        let refs = "refs/heads/main\u{0}aaa\u{0}\u{0}\nrefs/remotes/origin/dev\u{0}bbb\u{0}\u{0}\nrefs/remotes/origin/HEAD\u{0}bbb\u{0}\u{0}refs/remotes/origin/dev\n"
        let catalog = CleanupTargets.parse(refs)
        #expect(catalog.automatic?.ref == "refs/remotes/origin/dev")
        #expect(catalog.branch("refs/heads/main")?.sha == "aaa")
        #expect(catalog.branch("refs/heads/missing") == nil)
        #expect(catalog.branches.count == 2)
    }

    @Test("ambiguous default stays unset; a unique main falls back locally")
    func fallback() {
        let main = "refs/heads/main\u{0}aaa\u{0}\u{0}\n"
        #expect(CleanupTargets.parse(main).automatic?.ref == "refs/heads/main")
        #expect(CleanupTargets.parse(main + "refs/heads/master\u{0}bbb\u{0}\u{0}\n").automatic == nil)
    }

    @Test("merge targets: default first, then the extra, then integration branches, origin preferred, capped")
    func mergeTargetOrder() {
        func ref(_ name: String, _ sha: String = "s") -> String { "\(name)\u{0}\(sha)\u{0}\u{0}\n" }
        let refs = ref("refs/heads/main") + ref("refs/heads/dev") + ref("refs/remotes/origin/dev")
            + ref("refs/heads/master") + ref("refs/heads/develop") + ref("refs/heads/release/1")
            + ref("refs/heads/feature")
            + "refs/remotes/origin/HEAD\u{0}s\u{0}\u{0}refs/heads/main\n"
        let catalog = CleanupTargets.parse(refs)
        #expect(catalog.mergeTargets(extra: nil).map(\.ref)
            == ["refs/heads/main", "refs/remotes/origin/dev", "refs/heads/develop", "refs/heads/master"])
        // The extra is checked too, right after the default, and the cap drops the last integration name.
        #expect(catalog.mergeTargets(extra: "refs/heads/release/1").map(\.ref)
            == ["refs/heads/main", "refs/heads/release/1", "refs/remotes/origin/dev", "refs/heads/develop"])
        // An explicit local copy is kept beside origin's: it can hold unpushed merges.
        #expect(catalog.mergeTargets(extra: "refs/heads/dev").map(\.ref)
            == ["refs/heads/main", "refs/heads/dev", "refs/remotes/origin/dev", "refs/heads/develop"])
        // A saved extra that no longer exists is simply not checked.
        #expect(catalog.mergeTargets(extra: "refs/heads/gone").count == CleanupTargets.mergeTargetLimit)
        #expect(CleanupTargets.parse(ref("refs/heads/feature")).mergeTargets(extra: nil).isEmpty)
    }

    @Test("a typed extra branch name resolves to the ref it names, origin's copy first")
    func extraBranchByName() {
        func ref(_ name: String) -> String { "\(name)\u{0}s\u{0}\u{0}\n" }
        let both = CleanupTargets.parse(ref("refs/heads/main") + ref("refs/heads/release")
            + ref("refs/remotes/origin/release") + ref("refs/remotes/upstream/hotfix"))
        #expect(both.extraBranch("release")?.ref == "refs/remotes/origin/release")
        #expect(both.extraBranch(" release ")?.ref == "refs/remotes/origin/release")
        #expect(both.extraBranch("refs/heads/release")?.ref == "refs/heads/release")
        #expect(both.extraBranch("upstream/hotfix")?.ref == "refs/remotes/upstream/hotfix")
        #expect(both.extraBranch("gone") == nil)
        #expect(both.extraBranch("") == nil)
        #expect(both.extraBranch(nil) == nil)
        let localOnly = CleanupTargets.parse(ref("refs/heads/main") + ref("refs/heads/release"))
        #expect(localOnly.extraBranch("release")?.ref == "refs/heads/release")
        #expect(localOnly.mergeTargets(extra: "release").map(\.ref) == ["refs/heads/main", "refs/heads/release"])
    }

    @Test("regular and squash merges are confirmed by the appropriate evidence")
    func mergeKinds() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile("a.txt", "base")
        fixture.addWorktree(name: "feature", branch: "feature")
        let git = ProcessGitClient()
        let trees = try await git.worktrees(repoPath: fixture.repoPath)
        let feature = try #require(trees.first { $0.branch == "feature" })
        try Data("new".utf8).write(to: URL(fileURLWithPath: feature.path + "/new.txt"))
        _ = try await git.run(["add", "."], in: feature.path)
        _ = try await git.run(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "feature"], in: feature.path)
        let service = WorktreeCleanupService(git: git)
        let before = try await service.scan(repoPath: fixture.repoPath, extraTarget: nil)
        #expect(before.entries.first { $0.worktree.branch == "feature" }?.mergeStatus == .notConfirmed)
        _ = try await git.run(["merge", "--squash", "feature"], in: fixture.repoPath)
        _ = try await git.run(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "squashed"], in: fixture.repoPath)
        let squash = try await service.scan(repoPath: fixture.repoPath, extraTarget: nil)
        #expect(squash.entries.first { $0.worktree.branch == "feature" }?.mergeStatus == .merged)
        #expect(squash.entries.first { $0.worktree.branch == "feature" }?.hasEquivalentContent == true)
        _ = try await git.run(["-c", "user.name=Test", "-c", "user.email=test@example.com", "merge", "--no-ff", "feature", "-m", "merged"], in: fixture.repoPath)
        let merged = try await service.scan(repoPath: fixture.repoPath, extraTarget: nil)
        #expect(merged.entries.first { $0.worktree.branch == "feature" }?.mergeStatus == .merged)
    }

    @Test("ignored files need explicit consent and late local changes prevent removal")
    func fileSafety() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile(".gitignore", "cache/\n")
        let folder = fixture.addWorktree(name: "feature", branch: "feature")
        fixture.commitAndFastForward(branch: "feature", in: folder)
        let service = WorktreeCleanupService(git: ProcessGitClient())
        let first = try await service.scan(repoPath: fixture.repoPath, extraTarget: nil)
        let entry = try #require(first.entries.first { !$0.worktree.isPrimary })
        let cache = URL(fileURLWithPath: entry.worktree.path + "/cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("local".utf8).write(to: cache.appendingPathComponent("data.txt"))
        let second = try await service.scan(repoPath: fixture.repoPath, extraTarget: nil)
        let ignored = try #require(second.entries.first { !$0.worktree.isPrimary })
        #expect(ignored.hasIgnoredFiles)
        #expect(ignored.ignoredPaths == ["cache/"])
        #expect(!ignored.canRemove(includingIgnored: false))
        #expect(ignored.canRemove(includingIgnored: true))
        await #expect(throws: (any Error).self) {
            try await service.remove(repoPath: fixture.repoPath, entry: entry, includingIgnored: false, deleteBranch: false)
        }
        try Data("do not delete".utf8).write(to: URL(fileURLWithPath: entry.worktree.path + "/untracked.txt"))
        await #expect(throws: (any Error).self) {
            try await service.remove(repoPath: fixture.repoPath, entry: ignored, includingIgnored: true, deleteBranch: false)
        }
        #expect(FileManager.default.fileExists(atPath: entry.worktree.path + "/untracked.txt"))
        try FileManager.default.removeItem(atPath: entry.worktree.path + "/untracked.txt")
        try await service.remove(repoPath: fixture.repoPath, entry: ignored, includingIgnored: true, deleteBranch: false)
        #expect(!FileManager.default.fileExists(atPath: entry.worktree.path))
        #expect(try await ProcessGitClient().branches(repoPath: fixture.repoPath).contains { $0.name == "feature" })
    }

    @Test("ignored files that appeared after the confirmation are not deleted")
    func newIgnoredFiles() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile(".gitignore", "cache/\nsecrets.env\n")
        let folder = fixture.addWorktree(name: "feature", branch: "feature")
        fixture.commitAndFastForward(branch: "feature", in: folder)
        let cache = folder.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("local".utf8).write(to: cache.appendingPathComponent("data.txt"))
        let service = WorktreeCleanupService(git: ProcessGitClient())
        let snapshot = try await service.scan(repoPath: fixture.repoPath, extraTarget: nil)
        let entry = try #require(snapshot.entries.first { !$0.worktree.isPrimary })
        #expect(entry.ignoredPaths == ["cache/"])
        #expect(entry.canRemove(includingIgnored: true))
        let secrets = folder.appendingPathComponent("secrets.env")
        try Data("token".utf8).write(to: secrets)
        await #expect(throws: CleanupError.changed) {
            try await service.remove(repoPath: fixture.repoPath, entry: entry, includingIgnored: true, deleteBranch: false)
        }
        #expect(FileManager.default.fileExists(atPath: secrets.path))
        let rechecked = try await service.scan(repoPath: fixture.repoPath, extraTarget: nil)
        let reviewed = try #require(rechecked.entries.first { !$0.worktree.isPrimary })
        #expect(reviewed.ignoredPaths == ["cache/", "secrets.env"])
        try await service.remove(repoPath: fixture.repoPath, entry: reviewed, includingIgnored: true, deleteBranch: false)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test("changed target and primary worktree cannot be removed")
    func staleReview() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile("a.txt", "base")
        let folder = fixture.addWorktree(name: "feature", branch: "feature")
        fixture.commitAndFastForward(branch: "feature", in: folder)
        let service = WorktreeCleanupService(git: ProcessGitClient())
        let snapshot = try await service.scan(repoPath: fixture.repoPath, extraTarget: nil)
        let primary = try #require(snapshot.entries.first { $0.worktree.isPrimary })
        #expect(!primary.canRemove(includingIgnored: true))
        await #expect(throws: (any Error).self) {
            try await service.remove(repoPath: fixture.repoPath, entry: primary, includingIgnored: true, deleteBranch: false)
        }
        fixture.commitFile("a.txt", "changed target")
        let entry = try #require(snapshot.entries.first { !$0.worktree.isPrimary })
        #expect(entry.mergeStatus == .merged)
        await #expect(throws: (any Error).self) {
            try await service.remove(repoPath: fixture.repoPath, entry: entry, includingIgnored: false, deleteBranch: false)
        }
        #expect(FileManager.default.fileExists(atPath: entry.worktree.path))
    }
    @Test("new commits, locks, and the target checkout block removal")
    func protections() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile("a.txt", "base")
        let folder = fixture.addWorktree(name: "feature", branch: "feature")
        let service = WorktreeCleanupService(git: ProcessGitClient())
        let scan = try await service.scan(repoPath: fixture.repoPath, extraTarget: nil)
        let entry = try #require(scan.entries.first { !$0.worktree.isPrimary })
        let ownTarget = try await service.scan(repoPath: fixture.repoPath, extraTarget: "refs/heads/feature")
        #expect(ownTarget.entries.first { !$0.worktree.isPrimary }?.isTarget == true)
        fixture.git(["worktree", "lock", folder.path])
        await #expect(throws: (any Error).self) {
            try await service.remove(repoPath: fixture.repoPath, entry: entry, includingIgnored: false, deleteBranch: false)
        }
        fixture.git(["worktree", "unlock", folder.path])
        fixture.writeFile("a.txt", "new commit", in: folder)
        fixture.stage(in: folder)
        fixture.commit("new work", in: folder)
        await #expect(throws: (any Error).self) {
            try await service.remove(repoPath: fixture.repoPath, entry: entry, includingIgnored: false, deleteBranch: false)
        }
        #expect(FileManager.default.fileExists(atPath: folder.path))
    }

    @Test("detached and locked worktrees say why they cannot be removed")
    func namedBlockers() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile("a.txt", "base")
        let locked = fixture.addWorktree(name: "locked", branch: "locked")
        fixture.commitAndFastForward(branch: "locked", in: locked)
        let detached = fixture.root.appendingPathComponent("detached", isDirectory: true)
        fixture.git(["worktree", "add", "-q", "--detach", detached.path, "HEAD"])
        fixture.git(["worktree", "lock", locked.path])
        let service = WorktreeCleanupService(git: ProcessGitClient())
        let snapshot = try await service.scan(repoPath: fixture.repoPath, extraTarget: nil)
        let lockedEntry = try #require(snapshot.entries.first { $0.worktree.branch == "locked" })
        #expect(lockedEntry.mergeStatus == .merged)
        #expect(lockedEntry.problem == "Locked worktree")
        #expect(!lockedEntry.canRemove(includingIgnored: true))
        let detachedEntry = try #require(snapshot.entries.first { $0.worktree.isDetached })
        #expect(detachedEntry.problem == "Detached HEAD")
        #expect(!detachedEntry.canRemove(includingIgnored: true))
        let plain = try #require(snapshot.entries.first { $0.worktree.isPrimary })
        #expect(plain.problem == nil)
    }

    @Test("a missing extra target is ignored and missing worktree folders never become eligible")
    func unavailable() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile("a.txt", "base")
        let folder = fixture.addWorktree(name: "feature", branch: "feature")
        let service = WorktreeCleanupService(git: ProcessGitClient())
        let missingTarget = try await service.scan(repoPath: fixture.repoPath, extraTarget: "refs/heads/gone")
        #expect(missingTarget.targetNames == ["main"])
        try FileManager.default.removeItem(at: folder)
        let missingFolder = try await service.scan(repoPath: fixture.repoPath, extraTarget: nil)
        let missing = try #require(missingFolder.entries.first { !$0.worktree.isPrimary })
        #expect(missing.mergeStatus == .unknown)
        #expect(missing.isBroken)
        #expect(missing.problem?.contains("folder is missing") == true)
        #expect(!missing.canRemove(includingIgnored: true))
    }

    @Test("no integration branch at all: nothing is merged and Git says why")
    func noTargets() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile("a.txt", "base")
        fixture.git(["branch", "-m", "trunk-ish"])
        fixture.addWorktree(name: "feature", branch: "feature")
        let snapshot = try await WorktreeCleanupService(git: ProcessGitClient()).scan(repoPath: fixture.repoPath, extraTarget: nil)
        #expect(snapshot.mergeTargets.isEmpty)
        let entry = try #require(snapshot.entries.first { $0.worktree.branch == "feature" })
        #expect(entry.mergeStatus == .unknown)
        #expect(entry.problem == "No branch to compare against")
    }

    @Test("assume-unchanged flags cannot hide local work from cleanup")
    func uncheckedFiles() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile("a.txt", "base")
        let folder = fixture.addWorktree(name: "feature", branch: "feature")
        fixture.git(["update-index", "--assume-unchanged", "a.txt"], in: folder)
        fixture.writeFile("a.txt", "hidden edits", in: folder)
        let service = WorktreeCleanupService(git: ProcessGitClient())
        let snapshot = try await service.scan(repoPath: fixture.repoPath, extraTarget: nil)
        let entry = try #require(snapshot.entries.first { !$0.worktree.isPrimary })
        #expect(entry.hasUncheckedFiles)
        #expect(!entry.canRemove(includingIgnored: true))
    }

    @Test("feature branches tracking the merge target are not the target checkout")
    func sharedUpstream() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile("a.txt", "base")
        fixture.git(["remote", "add", "origin", fixture.repoPath])
        fixture.git(["update-ref", "refs/remotes/origin/dev", "HEAD"])
        fixture.git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/dev"])
        let feature = fixture.addWorktree(name: "feature", branch: "feature")
        fixture.commitAndFastForward(branch: "feature", in: feature)
        fixture.git(["update-ref", "refs/remotes/origin/dev", "HEAD"])
        fixture.git(["branch", "--set-upstream-to=origin/dev", "feature"])
        let dev = fixture.addWorktree(name: "dev", branch: "dev")
        let service = WorktreeCleanupService(git: ProcessGitClient())
        let snapshot = try await service.scan(repoPath: fixture.repoPath, extraTarget: nil)
        let entry = try #require(snapshot.entries.first { $0.worktree.branch == "feature" })
        let targetEntry = try #require(snapshot.entries.first { $0.worktree.branch == "dev" })
        #expect(entry.mergeStatus == .merged)
        #expect(!entry.isTarget)
        #expect(entry.canRemove(includingIgnored: false))
        #expect(targetEntry.isTarget)
        #expect(!targetEntry.canRemove(includingIgnored: true))
        try await service.remove(repoPath: fixture.repoPath, entry: entry, includingIgnored: false, deleteBranch: false)
        #expect(!FileManager.default.fileExists(atPath: feature.path))
        #expect(FileManager.default.fileExists(atPath: dev.path))
        #expect(!fixture.git(["rev-parse", "--verify", "feature"]).isEmpty)
    }

    @Test("an unmerged worktree goes through the same checks: its folder goes, its branch and commits stay")
    func unmergedRemoval() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile("a.txt", "base")
        let folder = fixture.addWorktree(name: "feature", branch: "feature")
        fixture.writeFile("f.txt", "unmerged work", in: folder)
        fixture.stage(in: folder)
        fixture.commit("unmerged work", in: folder)
        let service = WorktreeCleanupService(git: ProcessGitClient())
        let entry = try #require(try await service.scan(repoPath: fixture.repoPath, extraTarget: nil)
            .entries.first { $0.worktree.branch == "feature" })
        #expect(entry.mergeStatus == .notConfirmed)
        // Deleting an unmerged branch is never on offer.
        await #expect(throws: CleanupError.changed) {
            try await service.remove(repoPath: fixture.repoPath, entry: entry, includingIgnored: true, deleteBranch: true)
        }
        #expect(FileManager.default.fileExists(atPath: folder.path))
        let outcome = try await service.remove(repoPath: fixture.repoPath, entry: entry, includingIgnored: true, deleteBranch: false)
        #expect(outcome == .notRequested)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(!fixture.git(["rev-parse", "--verify", "feature"]).isEmpty)
    }

    @Test("an unmerged worktree with hidden edits, new commits or a detached HEAD is not removed")
    func unmergedProtections() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile("a.txt", "base")
        let hidden = fixture.addWorktree(name: "hidden", branch: "hidden")
        let moved = fixture.addWorktree(name: "moved", branch: "moved")
        let detached = fixture.root.appendingPathComponent("detached", isDirectory: true)
        fixture.git(["worktree", "add", "-q", "--detach", detached.path, "HEAD"])
        fixture.writeFile("d.txt", "detached work", in: detached)
        fixture.stage(in: detached)
        fixture.commit("detached work", in: detached)
        let service = WorktreeCleanupService(git: ProcessGitClient())
        let entries = try await service.scan(repoPath: fixture.repoPath, extraTarget: nil).entries
        func entry(_ path: URL) throws -> CleanupEntry {
            try #require(entries.first { PathUtil.standardized($0.id) == PathUtil.standardized(path.path) })
        }
        fixture.git(["update-index", "--skip-worktree", "a.txt"], in: hidden)
        fixture.writeFile("a.txt", "hidden edits", in: hidden)
        await #expect(throws: CleanupError.unsafe) {
            try await service.remove(repoPath: fixture.repoPath, entry: try entry(hidden), includingIgnored: true, deleteBranch: false)
        }
        fixture.writeFile("m.txt", "new commit", in: moved)
        fixture.stage(in: moved)
        fixture.commit("new commit", in: moved)
        await #expect(throws: CleanupError.changed) {
            try await service.remove(repoPath: fixture.repoPath, entry: try entry(moved), includingIgnored: true, deleteBranch: false)
        }
        await #expect(throws: CleanupError.unsafe) {
            try await service.remove(repoPath: fixture.repoPath, entry: try entry(detached), includingIgnored: true, deleteBranch: false)
        }
        for folder in [hidden, moved, detached] { #expect(FileManager.default.fileExists(atPath: folder.path)) }
    }

    @Test("a merge target's own checkout can have its folder removed, never its branch")
    func targetCheckoutFolder() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile("a.txt", "base")
        fixture.createBranch("dev")
        let dev = fixture.root.appendingPathComponent("dev", isDirectory: true)
        fixture.git(["worktree", "add", "-q", dev.path, "dev"])
        let service = WorktreeCleanupService(git: ProcessGitClient())
        let entry = try #require(try await service.scan(repoPath: fixture.repoPath, extraTarget: nil)
            .entries.first { $0.worktree.branch == "dev" })
        #expect(entry.isTarget)
        await #expect(throws: CleanupError.changed) {
            try await service.remove(repoPath: fixture.repoPath, entry: entry, includingIgnored: true, deleteBranch: true)
        }
        try await service.remove(repoPath: fixture.repoPath, entry: entry, includingIgnored: true, deleteBranch: false)
        #expect(!FileManager.default.fileExists(atPath: dev.path))
        #expect(!fixture.git(["rev-parse", "--verify", "dev"]).isEmpty)
    }

    /// Commits only a reflog still reaches, as a reset leaves them: merged then reset
    /// back past a new commit, or reset onto the target over one.
    @Test("commits only the worktree's or branch's reflog reaches survive removing both")
    func reflogOnlyCommitsKept() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile("a.txt", "base")
        let backFolder = fixture.addWorktree(name: "back", branch: "back")
        fixture.commitAndFastForward(branch: "back", in: backFolder)
        let ontoFolder = fixture.addWorktree(name: "onto", branch: "onto")
        var lost: [String: String] = [:]
        for (branch, folder) in [("back", backFolder), ("onto", ontoFolder)] {
            fixture.writeFile(branch + ".txt", "committed, then reset away", in: folder)
            fixture.stage(in: folder)
            fixture.commit("work on " + branch, in: folder)
            lost[branch] = fixture.git(["rev-parse", "HEAD"], in: folder).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        fixture.git(["reset", "-q", "--hard", "HEAD~1"], in: backFolder)
        fixture.commitFile("main.txt", "main moves on")
        fixture.git(["reset", "-q", "--hard", "main"], in: ontoFolder)
        let service = WorktreeCleanupService(git: ProcessGitClient())
        let entries = try await service.scan(repoPath: fixture.repoPath, extraTarget: nil).entries
        for branch in ["back", "onto"] {
            let entry = try #require(entries.first { $0.worktree.branch == branch })
            #expect(entry.canRemove(includingIgnored: false))
            let outcome = try await service.remove(repoPath: fixture.repoPath, entry: entry, includingIgnored: false, deleteBranch: true)
            #expect(outcome == .deleted)
        }
        let unreachable = fixture.git(["fsck", "--unreachable", "--no-progress"])
        let reachable = fixture.git(["rev-list", "--all"])
        for (branch, commit) in lost {
            #expect(!unreachable.contains(commit))
            #expect(reachable.contains(commit))
            #expect(!fixture.git(["for-each-ref", "--contains", commit, WorktreeCleanupService.backupRefPrefix + branch + "/"])
                .isEmpty)
        }
    }

    @Test("removal keeps no backup when nothing would be lost, and drops backups past their lifetime")
    func reflogBackupsPruned() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile("a.txt", "base")
        let tree = fixture.git(["rev-parse", "HEAD^{tree}"]).trimmingCharacters(in: .whitespacesAndNewlines)
        func backup(_ name: String, daysAgo: Int) {
            let date = "\(Int(Date().timeIntervalSince1970) - daysAgo * 86_400) +0000"
            fixture.git(["update-ref", WorktreeCleanupService.backupRefPrefix + name,
                         datedCommit(fixture, tree: tree, message: name, date: date)])
        }
        backup("old/1", daysAgo: 91)
        backup("recent/1", daysAgo: 10)
        let folder = fixture.addWorktree(name: "feature", branch: "feature")
        fixture.commitAndFastForward(branch: "feature", in: folder)
        let service = WorktreeCleanupService(git: ProcessGitClient())
        let entry = try #require(try await service.scan(repoPath: fixture.repoPath, extraTarget: nil)
            .entries.first { $0.worktree.branch == "feature" })
        #expect(try await service.remove(repoPath: fixture.repoPath, entry: entry, includingIgnored: false, deleteBranch: true)
            == .deleted)
        let backups = fixture.git(["for-each-ref", "--format=%(refname)", WorktreeCleanupService.backupRefPrefix])
        #expect(backups == WorktreeCleanupService.backupRefPrefix + "recent/1\n")
    }
}

private func datedCommit(_ fixture: GitFixture, tree: String, message: String, date: String) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git", "-c", "user.name=t", "-c", "user.email=t@t", "commit-tree", tree, "-m", message]
    process.currentDirectoryURL = fixture.repoURL
    var environment = ProcessInfo.processInfo.environment
    environment["GIT_COMMITTER_DATE"] = date
    process.environment = environment
    let output = Pipe()
    process.standardOutput = output
    try? process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (String(bytes: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
}
