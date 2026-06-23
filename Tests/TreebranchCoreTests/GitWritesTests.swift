import Testing
import Foundation
@testable import TreebranchCore

@Suite("RepoGitQueue (integration writes)")
struct GitWritesTests {
    let git = ProcessGitClient()

    private func queue(_ fixture: GitFixture) -> RepoGitQueue {
        RepoGitQueue(git: git, repoPath: fixture.repoPath, maxLockRetries: 3, lockBackoff: 0.02)
    }

    @Test("stage then unstage")
    func stageUnstage() async throws {
        let fixture = try GitFixture(); defer { fixture.cleanup() }
        fixture.commitFile("seed.txt", "seed\n")
        fixture.writeFile("new.txt", "new\n")

        let q = queue(fixture)
        try await q.stage(worktreePath: fixture.repoPath, paths: ["new.txt"])
        var status = try await git.status(worktreePath: fixture.repoPath)
        #expect(status.changes.first { $0.path == "new.txt" }?.indexStatus == .added)

        try await q.unstage(worktreePath: fixture.repoPath, paths: ["new.txt"])
        status = try await git.status(worktreePath: fixture.repoPath)
        #expect(status.changes.first { $0.path == "new.txt" }?.isUntracked == true)
    }

    @Test("discard working restores committed content")
    func discardWorking() async throws {
        let fixture = try GitFixture(); defer { fixture.cleanup() }
        fixture.commitFile("a.txt", "original\n")
        fixture.writeFile("a.txt", "changed\n")

        try await queue(fixture).discardWorking(worktreePath: fixture.repoPath, paths: ["a.txt"])
        let content = try String(contentsOf: fixture.repoURL.appendingPathComponent("a.txt"), encoding: .utf8)
        #expect(content == "original\n")
    }

    @Test("commit clears staged changes")
    func commit() async throws {
        let fixture = try GitFixture(); defer { fixture.cleanup() }
        fixture.commitFile("seed.txt", "seed\n")
        fixture.writeFile("feature.txt", "feature\n")

        let q = queue(fixture)
        try await q.stage(worktreePath: fixture.repoPath, paths: ["feature.txt"])
        try await q.commit(worktreePath: fixture.repoPath, message: "add feature")

        let status = try await git.status(worktreePath: fixture.repoPath)
        #expect(status.changes.isEmpty)
        let log = fixture.git(["log", "--oneline"])
        #expect(log.contains("add feature"))
    }

    @Test("serialized concurrent stages all apply")
    func serializedConcurrency() async throws {
        let fixture = try GitFixture(); defer { fixture.cleanup() }
        fixture.commitFile("seed.txt", "seed\n")
        for i in 0..<5 { fixture.writeFile("f\(i).txt", "x\n") }

        let q = queue(fixture)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<5 {
                group.addTask { try await q.stage(worktreePath: fixture.repoPath, paths: ["f\(i).txt"]) }
            }
            try await group.waitForAll()
        }
        let status = try await git.status(worktreePath: fixture.repoPath)
        let staged = status.changes.filter { $0.indexStatus == .added }.map(\.path).sorted()
        #expect(staged == ["f0.txt", "f1.txt", "f2.txt", "f3.txt", "f4.txt"])
    }
}

@Suite("RepoGitQueue retry + busy guard (fakes)")
struct GitWriteGuardTests {
    @Test("retries through transient index.lock then succeeds")
    func retrySucceeds() async throws {
        let fake = FakeGitClient()
        fake.lockFailuresBeforeSuccess = 2
        let q = RepoGitQueue(git: fake, repoPath: "/repo", maxLockRetries: 5, lockBackoff: 0.01)
        try await q.stage(worktreePath: "/repo", paths: ["a.txt"])
        #expect(fake.stagedPaths == [["a.txt"]]) // succeeded exactly once
    }

    @Test("gives up after exceeding retry budget")
    func retryExhausted() async throws {
        let fake = FakeGitClient()
        fake.lockFailuresBeforeSuccess = 10
        let q = RepoGitQueue(git: fake, repoPath: "/repo", maxLockRetries: 2, lockBackoff: 0.01)
        await #expect(throws: GitError.self) {
            try await q.stage(worktreePath: "/repo", paths: ["a.txt"])
        }
    }

    @Test("WorktreeActivityMonitor reports busy within the window")
    func busyMonitor() {
        let monitor = WorktreeActivityMonitor()
        let base = Date(timeIntervalSince1970: 1000)
        monitor.recordActivity(worktreePath: "/wt", at: base)

        #expect(monitor.isBusy(worktreePath: "/wt", within: 5, now: base.addingTimeInterval(2)) == true)
        #expect(monitor.isBusy(worktreePath: "/wt", within: 5, now: base.addingTimeInterval(10)) == false)
        #expect(monitor.isBusy(worktreePath: "/unknown", within: 5, now: base) == false)
    }
}
