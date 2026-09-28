import Testing
import Foundation
@testable import TeebeCore

/// Integration tests: `ProcessGitClient` against real throwaway repos.
@Suite("ProcessGitClient (integration)")
struct ProcessGitClientTests {
    let git = ProcessGitClient()

    // MARK: M1 — Worktree discovery

    @Test("discovers primary + linked worktrees")
    func worktreeDiscovery() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile("README.md", "# repo\n")
        fixture.addWorktree(name: "wt-feature", branch: "feature")

        let worktrees = try await git.worktrees(repoPath: fixture.repoPath)
        #expect(worktrees.count == 2)
        #expect(worktrees[0].isPrimary == true)
        #expect(worktrees[0].branch == "main")
        #expect(worktrees.contains { $0.branch == "feature" })
    }

    @Test("worktree add arguments put the start point after the path")
    func worktreeAddArguments() {
        #expect(ProcessGitClient.worktreeAddArguments(
            path: "/tmp/wt", branch: "feat", createBranch: true, startPoint: "origin/dev")
            == ["worktree", "add", "-b", "feat", "/tmp/wt", "origin/dev"])
        #expect(ProcessGitClient.worktreeAddArguments(
            path: "/tmp/wt", branch: "feat", createBranch: true, startPoint: nil)
            == ["worktree", "add", "-b", "feat", "/tmp/wt"])
        // An empty start point means "from HEAD", same as nil.
        #expect(ProcessGitClient.worktreeAddArguments(
            path: "/tmp/wt", branch: "feat", createBranch: true, startPoint: "")
            == ["worktree", "add", "-b", "feat", "/tmp/wt"])
        // Checking out an existing branch: the branch is the trailing argument and
        // a start point would be meaningless.
        #expect(ProcessGitClient.worktreeAddArguments(
            path: "/tmp/wt", branch: "feat", createBranch: false, startPoint: "origin/dev")
            == ["worktree", "add", "/tmp/wt", "feat"])
    }

    @Test("worktree add branches from the given start point")
    func worktreeAddFromStartPoint() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile("seed.txt", "seed\n")
        let base = fixture.currentHead()
        fixture.createBranch("base")
        fixture.commitFile("later.txt", "later\n")

        let linked = fixture.root.appendingPathComponent("from-base").path
        try await git.addWorktree(repoPath: fixture.repoPath, path: linked, branch: "feat",
                                  createBranch: true, startPoint: "base")
        let head = fixture.git(["rev-parse", "HEAD"], in: URL(fileURLWithPath: linked))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(head == base)
    }

    // MARK: M2 — Status & change model

    @Test("status reports working changes across kinds")
    func statusChanges() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile("tracked.txt", "line1\nline2\nline3\n")
        fixture.commitFile("todelete.txt", "bye\n")

        fixture.writeFile("tracked.txt", "line1\nCHANGED\nline3\n") // modified, unstaged
        fixture.writeFile("newstaged.txt", "new\n")
        fixture.stage(["newstaged.txt"])                            // added, staged
        fixture.writeFile("untracked.txt", "u\n")                   // untracked
        fixture.deleteFile("todelete.txt")                          // deleted, unstaged

        let status = try await git.status(worktreePath: fixture.repoPath)
        #expect(status.branch == "main")
        let byPath = Dictionary(uniqueKeysWithValues: status.changes.map { ($0.path, $0) })
        #expect(byPath["tracked.txt"]?.worktreeStatus == .modified)
        #expect(byPath["newstaged.txt"]?.indexStatus == .added)
        #expect(byPath["untracked.txt"]?.isUntracked == true)
        #expect(byPath["todelete.txt"]?.worktreeStatus == .deleted)
    }

    @Test("status counts untracked files even when the repository is set to hide them")
    func statusIgnoresHidingSettings() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile("tracked.txt", "t\n")
        fixture.git(["config", "status.showUntrackedFiles", "no"])
        fixture.writeFile("untracked.txt", "u\n")
        let status = try await git.status(worktreePath: fixture.repoPath)
        #expect(status.changes.map(\.path) == ["untracked.txt"])
        // The same options the removal check reads with.
        #expect(ProcessGitClient.statusArguments.contains("--untracked-files=normal"))
        #expect(ProcessGitClient.statusArguments.contains("--ignore-submodules=none"))
    }

    // MARK: M4 — Diffs

    @Test("working diff produces hunks with line numbers")
    func workingDiff() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile("tracked.txt", "line1\nline2\nline3\n")
        fixture.writeFile("tracked.txt", "line1\nline2 CHANGED\nline3\n")

        let diff = try await git.workingDiff(worktreePath: fixture.repoPath, path: "tracked.txt", staged: false)
        let file = try #require(diff)
        #expect(file.displayPath == "tracked.txt")
        #expect(file.addedCount == 1)
        #expect(file.removedCount == 1)
        #expect(file.hunks.first?.lines.contains { $0.content == "line2 CHANGED" && $0.kind == .addition } == true)
    }

    // MARK: Launch failures

    @Test("git run in a deleted worktree folder reports the folder missing, not git")
    func missingWorkingDirectory() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile("README.md", "# repo\n")
        let worktreePath = fixture.addWorktree(name: "wt-gone", branch: "gone").path
        try FileManager.default.removeItem(atPath: worktreePath)

        await #expect(throws: GitError.workingDirectoryMissing(path: worktreePath)) {
            _ = try await git.status(worktreePath: worktreePath)
        }
    }

    @Test("a launch failure in a folder that exists still means git itself is missing")
    func launchFailureMapping() {
        #expect(ProcessGitClient.launchFailure(directory: "/repo-gone", directoryExists: false)
            == .workingDirectoryMissing(path: "/repo-gone"))
        #expect(ProcessGitClient.launchFailure(directory: "/repo", directoryExists: true) == .executableNotFound)
    }

    // MARK: Cancellation

    @Test("cancelling a task stops the git subprocess instead of waiting it out")
    func cancellationStopsGit() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile("a.txt", "base")
        // A FIFO nobody writes to: `git apply` blocks on the open until it is killed.
        let blocker = fixture.root.appendingPathComponent("blocking.patch").path
        #expect(mkfifo(blocker, 0o600) == 0)
        let started = Date()
        let task = Task { try await git.run(["apply", blocker], in: fixture.repoPath) }
        try await Task.sleep(for: .milliseconds(400))
        #expect(!fixture.git(["status", "--porcelain"]).contains("blocking"))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test("a cancelled task still finishes a worktree removal")
    func removalIgnoresCancellation() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile("a.txt", "base")
        let folder = fixture.addWorktree(name: "feature", branch: "feature")
        let task = Task {
            try? await Task.sleep(for: .seconds(60))
            #expect(Task.isCancelled)
            try await git.removeWorktree(repoPath: fixture.repoPath, worktreePath: folder.path, force: false)
        }
        task.cancel()
        try await task.value
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test("removing a worktree whose folder is gone forgets only its record and keeps the branch")
    func removeMissingFolder() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile("a.txt", "base")
        let gone = fixture.addWorktree(name: "gone", branch: "gone")
        let alsoGone = fixture.addWorktree(name: "also-gone", branch: "also-gone")
        let kept = fixture.addWorktree(name: "kept", branch: "kept")
        try FileManager.default.removeItem(at: gone)
        try FileManager.default.removeItem(at: alsoGone)
        let listedGone = try #require(try await git.worktrees(repoPath: fixture.repoPath).first { $0.path.hasSuffix("/gone") })

        try await git.removeWorktree(repoPath: fixture.repoPath, worktreePath: listedGone.path, force: false)

        let paths = try await git.worktrees(repoPath: fixture.repoPath).map(\.path)
        #expect(!paths.contains { $0.hasSuffix("/gone") })
        #expect(paths.contains { $0.hasSuffix("/also-gone") })
        #expect(paths.contains { $0.hasSuffix("/kept") })
        #expect(FileManager.default.fileExists(atPath: kept.path))
        #expect(fixture.git(["branch", "--list", "gone"]).contains("gone"))
    }

    @Test("fetching a repository with no origin fails without waiting on a prompt")
    func fetchWithoutOrigin() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile("a.txt", "base")
        await #expect(throws: GitError.self) {
            try await git.fetchOrigin(repoPath: fixture.repoPath)
        }
    }

    @Test("a fetch prunes remote branches that were deleted")
    func fetchPrunes() async throws {
        let fixture = try GitFixture(name: "origin")
        defer { fixture.cleanup() }
        fixture.commitFile("a.txt", "base")
        fixture.createBranch("gone")
        let clone = fixture.root.appendingPathComponent("clone")
        fixture.git(["clone", "-q", fixture.repoPath, clone.path], in: fixture.root)
        #expect(fixture.git(["for-each-ref", "refs/remotes/origin/gone"], in: clone).contains("gone"))
        fixture.git(["branch", "-D", "gone"])

        try await git.fetchOrigin(repoPath: clone.path)
        #expect(fixture.git(["for-each-ref", "refs/remotes/origin/gone"], in: clone).isEmpty)
    }

    @Test("a fetch keeps the repository's own SSH command, in batch mode")
    func fetchKeepsConfiguredSSHCommand() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile("a.txt", "base")
        // Stands in for ssh: records how it was called, then fails like an
        // unreachable host would.
        let bin = fixture.root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let record = fixture.root.appendingPathComponent("ssh-calls.txt")
        let ssh = bin.appendingPathComponent("ssh")
        try "#!/bin/sh\necho \"$@\" >> '\(record.path)'\nexit 255\n".write(to: ssh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ssh.path)
        fixture.git(["remote", "add", "origin", "ssh://example.invalid/repo.git"])
        fixture.git(["config", "core.sshCommand", ssh.path + " -i /tmp/acme-key"])

        await #expect(throws: GitError.self) {
            try await git.fetchOrigin(repoPath: fixture.repoPath)
        }
        let calls = (try? String(contentsOf: record, encoding: .utf8)) ?? ""
        #expect(calls.contains("-i /tmp/acme-key"))
        #expect(calls.contains("-o BatchMode=yes"))
    }

    @Test("the fetch environment never prompts and never replaces the user's SSH command")
    func fetchEnvironment() {
        let batch = "-o BatchMode=yes"
        #expect(ProcessGitClient.fetchEnvironment(inherited: [:], sshCommand: nil)
            == ["GIT_SSH_COMMAND": "ssh \(batch)", "SSH_ASKPASS_REQUIRE": "never"])
        let configured = ProcessGitClient.fetchEnvironment(inherited: [:], sshCommand: "ssh -i ~/.ssh/work")
        #expect(configured["GIT_SSH_COMMAND"] == "ssh -i ~/.ssh/work \(batch)")
        // Git prefers the environment's command over the configured one.
        let inherited = ProcessGitClient.fetchEnvironment(inherited: ["GIT_SSH_COMMAND": "ssh -F cfg"], sshCommand: "ssh -i k")
        #expect(inherited["GIT_SSH_COMMAND"] == "ssh -F cfg \(batch)")
        // A GIT_SSH program is used only when no command is set; setting one would replace it.
        #expect(ProcessGitClient.fetchEnvironment(inherited: ["GIT_SSH": "/opt/acme/ssh"], sshCommand: nil)
            == ["SSH_ASKPASS_REQUIRE": "never"])
        #expect(ProcessGitClient.fetchArguments == ["fetch", "--quiet", "--prune", "origin"])
    }

    @Test("status on a non-git directory throws notAGitRepository")
    func notARepo() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("teebe-notrepo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        await #expect(throws: GitError.self) {
            _ = try await git.status(worktreePath: tmp.path)
        }
    }
}
