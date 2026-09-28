import Foundation
import Testing
@testable import TeebeCore

@Suite("Remote sync")
struct RemoteSyncTests {
    private func parse(_ headers: [String]) -> StatusResult {
        StatusParser.parse(headers.map { $0 + "\u{0}" }.joined())
    }

    @Test("only the remote copy of the same branch counts; ahead and behind come with it")
    func sameBranchOnly() {
        let same = parse(["# branch.head feat/x", "# branch.upstream origin/feat/x", "# branch.ab +2 -3"])
        #expect(RemoteSync(status: same) == .sameBranch(remote: "origin", ahead: 2, behind: 3))
        #expect(RemoteSync(status: same).ahead == 2)
        let other = parse(["# branch.head feat/x", "# branch.upstream origin/dev", "# branch.ab +5 -1"])
        #expect(RemoteSync(status: other) == .notOnRemote)
        #expect(RemoteSync(status: other).ahead == 0)
        #expect(RemoteSync(status: parse(["# branch.head feat/x"])) == .notOnRemote)
        #expect(RemoteSync(status: parse(["# branch.head (detached)"])) == .notOnRemote)
        // A suffix match is not a name match.
        let suffix = parse(["# branch.head x", "# branch.upstream origin/feat/x", "# branch.ab +0 -0"])
        #expect(RemoteSync(status: suffix) == .notOnRemote)
    }

    @Test("an upstream without ahead/behind is gone")
    func goneUpstream() {
        let gone = parse(["# branch.head feat/x", "# branch.upstream origin/feat/x"])
        #expect(gone.isUpstreamGone)
        #expect(RemoteSync(status: gone) == .remoteDeleted)
        let goneOther = parse(["# branch.head feat/x", "# branch.upstream origin/dev"])
        #expect(RemoteSync(status: goneOther) == .notOnRemote)
        #expect(!parse(["# branch.head feat/x"]).isUpstreamGone)
    }

    @Test("real git: pushing, deleting the remote branch and pruning reads as deleted")
    func realGoneUpstream() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile("a.txt", "base")
        let remote = fixture.root.appendingPathComponent("remote.git", isDirectory: true)
        fixture.git(["init", "-q", "--bare", remote.path])
        fixture.git(["remote", "add", "origin", remote.path])
        let folder = fixture.addWorktree(name: "feature", branch: "feat/x")
        fixture.git(["push", "-q", "-u", "origin", "feat/x"], in: folder)
        fixture.writeFile("b.txt", "work", in: folder)
        fixture.stage(in: folder)
        fixture.commit("work", in: folder)
        let git = ProcessGitClient()
        let pushed = try await git.status(worktreePath: folder.path)
        #expect(RemoteSync(status: pushed) == .sameBranch(remote: "origin", ahead: 1, behind: 0))
        fixture.git(["push", "-q", "origin", "--delete", "feat/x"])
        fixture.git(["fetch", "-q", "--prune", "origin"])
        let gone = try await git.status(worktreePath: folder.path)
        #expect(gone.upstream == "origin/feat/x")
        #expect(RemoteSync(status: gone) == .remoteDeleted)
        fixture.git(["branch", "--set-upstream-to=origin/main", "feat/x"], in: folder)
        fixture.git(["push", "-q", "origin", "main"])
        fixture.git(["fetch", "-q", "origin"])
        fixture.git(["branch", "--set-upstream-to=origin/main", "feat/x"], in: folder)
        #expect(RemoteSync(status: try await git.status(worktreePath: folder.path)) == .notOnRemote)
    }
}
