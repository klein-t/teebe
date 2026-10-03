import Foundation

/// A branch's relationship to its remote, counted only against the remote copy of
/// the same branch. A feature branch tracking `origin/dev` is not compared with
/// it: arrows against someone else's branch mislead. Nothing here says whether
/// work is safe; it only describes the remote.
public enum RemoteSync: Equatable, Sendable {
    /// Tracks `<remote>/<this branch>`, which exists.
    case sameBranch(remote: String, ahead: Int, behind: Int)
    /// Tracked `<remote>/<this branch>`, which has since been deleted.
    case remoteDeleted
    /// Tracks a branch with another name, e.g. `origin/dev`.
    case otherUpstream(String, isGone: Bool)
    /// No upstream is set (or the HEAD is detached), and whether the remote has a
    /// branch of this name can't be told.
    case noUpstream
    /// No upstream is set and the named remote has no branch of this name.
    case notOnRemote(String)
    /// The status read failed.
    case unknown

    public init(status: StatusResult) {
        self.init(status: status, remoteBranches: nil)
    }

    /// `remoteBranches`: the remote-tracking branches, short names like
    /// `origin/feat/x`, used to tell a branch the remote doesn't have from one that
    /// only has no upstream set. The remote named is `origin`, or the only one.
    public init(status: StatusResult, remoteBranches: Set<String>?) {
        guard !status.isDetached, let branch = status.branch else {
            self = .noUpstream
            return
        }
        guard let upstream = status.upstream else {
            let remotes = Set((remoteBranches ?? []).compactMap { $0.split(separator: "/", maxSplits: 1).first.map(String.init) })
            let remote = remotes.contains("origin") ? "origin" : remotes.count == 1 ? remotes.first : nil
            if let remote, remoteBranches?.contains(remote + "/" + branch) == false {
                self = .notOnRemote(remote)
            } else {
                self = .noUpstream
            }
            return
        }
        guard let slash = upstream.firstIndex(of: "/"), upstream[upstream.index(after: slash)...] == branch else {
            self = .otherUpstream(upstream, isGone: status.isUpstreamGone)
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
