import Foundation

/// A branch's relationship to its remote, counted only against the remote copy of
/// the same branch. A feature branch tracking `origin/dev` is not on the remote as
/// far as this is concerned: arrows against someone else's branch mislead.
public enum RemoteSync: Equatable, Sendable {
    /// Tracks `<remote>/<this branch>`, which exists.
    case sameBranch(remote: String, ahead: Int, behind: Int)
    /// No upstream, an upstream with another name, or a detached HEAD.
    case notOnRemote
    /// Tracked `<remote>/<this branch>`, which has since been deleted.
    case remoteDeleted

    public init(status: StatusResult) {
        guard !status.isDetached, let branch = status.branch, let upstream = status.upstream,
              let slash = upstream.firstIndex(of: "/"),
              upstream[upstream.index(after: slash)...] == branch else {
            self = .notOnRemote
            return
        }
        let remote = String(upstream[..<slash])
        self = status.isUpstreamGone
            ? .remoteDeleted : .sameBranch(remote: remote, ahead: status.ahead, behind: status.behind)
    }

    /// Commits to push and pull; zero unless tracking the same-named branch.
    public var ahead: Int {
        if case let .sameBranch(_, ahead, _) = self { return ahead }
        return 0
    }

    public var behind: Int {
        if case let .sameBranch(_, _, behind) = self { return behind }
        return 0
    }
}
