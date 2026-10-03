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
        #expect(RemoteSync(status: other) == .otherUpstream("origin/dev", isGone: false))
        #expect(RemoteSync(status: other).ahead == 0)
        #expect(RemoteSync(status: parse(["# branch.head feat/x"])) == .noUpstream)
        #expect(RemoteSync(status: parse(["# branch.head (detached)"])) == .noUpstream)
        // A suffix match is not a name match.
        let suffix = parse(["# branch.head x", "# branch.upstream origin/feat/x", "# branch.ab +0 -0"])
        #expect(RemoteSync(status: suffix) == .otherUpstream("origin/feat/x", isGone: false))
    }

    @Test("with no upstream, it is not on the remote only when that remote has no branch of its name")
    func noUpstream() {
        let unset = parse(["# branch.head feat/x"])
        // The remote has other branches but not this one.
        #expect(RemoteSync(status: unset, remoteBranches: ["origin/main"]) == .notOnRemote("origin"))
        // It is there, only no upstream is set.
        #expect(RemoteSync(status: unset, remoteBranches: ["origin/main", "origin/feat/x"]) == .noUpstream)
        // Origin is the one named; another remote's copy doesn't count for it.
        #expect(RemoteSync(status: unset, remoteBranches: ["origin/main", "fork/feat/x"]) == .notOnRemote("origin"))
        #expect(RemoteSync(status: unset, remoteBranches: ["fork/main"]) == .notOnRemote("fork"))
        // Several remotes, none of them origin: which one would it be on?
        #expect(RemoteSync(status: unset, remoteBranches: ["a/main", "b/main"]) == .noUpstream)
        // No remote branches known at all.
        #expect(RemoteSync(status: unset, remoteBranches: []) == .noUpstream)
        #expect(RemoteSync(status: unset) == .noUpstream)
    }

    @Test("an upstream without ahead/behind is gone")
    func goneUpstream() {
        let gone = parse(["# branch.head feat/x", "# branch.upstream origin/feat/x"])
        #expect(gone.isUpstreamGone)
        #expect(RemoteSync(status: gone) == .remoteDeleted)
        let goneOther = parse(["# branch.head feat/x", "# branch.upstream origin/dev"])
        #expect(RemoteSync(status: goneOther) == .otherUpstream("origin/dev", isGone: true))
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
        #expect(RemoteSync(status: try await git.status(worktreePath: folder.path)) == .otherUpstream("origin/main", isGone: false))
    }
}
