import Darwin
import Foundation

/// Registered worktrees whose folder is not on disk. One gone from a connected
/// disk is deleted: it can't be browsed and holds nothing, so its record may be
/// forgotten. One that is only out of reach (on a volume that isn't mounted, or
/// locked) is left alone, so it comes back when its drive does.
public struct MissingWorktrees: Sendable {
    public enum Disposition: Equatable, Sendable {
        /// The folder is there (or it is the primary checkout): listed as usual.
        case present
        /// The folder is gone from a connected disk: its record may be forgotten.
        case deleted
        /// Out of reach for now: hidden, never forgotten.
        case unreachable
    }

    private let git: GitClient
    private let folderIsGone: @Sendable (String) -> Bool
    private let isVolumeMounted: @Sendable (String) -> Bool

    public init(git: GitClient,
                folderIsGone: @escaping @Sendable (String) -> Bool = { MissingWorktrees.isGone($0) },
                isVolumeMounted: @escaping @Sendable (String) -> Bool = { MissingWorktrees.isOnMountedVolume($0) }) {
        self.git = git
        self.folderIsGone = folderIsGone
        self.isVolumeMounted = isVolumeMounted
    }

    public func disposition(of worktree: Worktree) -> Disposition {
        guard !worktree.isPrimary, folderIsGone(worktree.path) else { return .present }
        return worktree.isLocked || !isVolumeMounted(worktree.path) ? .unreachable : .deleted
    }

    /// Forget one deleted worktree's record and nothing else. For a folder that is
    /// gone, `git worktree remove` only drops Git's record: the branch is kept, and
    /// Git itself refuses a locked worktree. The folder is checked again right
    /// before, so one that came back is left alone. Returns whether it was forgotten.
    public func forget(_ worktree: Worktree, repoPath: String) async -> Bool {
        guard disposition(of: worktree) == .deleted,
              PathUtil.standardized(worktree.path) != PathUtil.standardized(repoPath) else { return false }
        do {
            try await git.removeWorktree(repoPath: repoPath, worktreePath: worktree.path, force: false)
            return true
        } catch {
            return false
        }
    }

    /// Only "no such file" counts as gone: a folder Teebe may not read (permissions,
    /// privacy settings) is not evidence that it was deleted.
    public static func isGone(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) != 0 else { return false }
        return errno == ENOENT || errno == ENOTDIR
    }

    /// A path under `/Volumes/<name>` is reachable only while that volume is
    /// mounted: its mount point must be on a different device than `/Volumes`
    /// itself (a leftover empty folder there is not a mounted drive). Every other
    /// path is on a disk that is always connected.
    public static func isOnMountedVolume(_ path: String) -> Bool {
        guard let root = volumeRoot(of: path) else { return true }
        var volume = stat()
        var parent = stat()
        return stat(root, &volume) == 0 && stat("/Volumes", &parent) == 0 && volume.st_dev != parent.st_dev
    }

    /// `/Volumes/<name>` for a path on that volume; nil for any other path.
    public static func volumeRoot(of path: String) -> String? {
        let components = (path as NSString).standardizingPath.split(separator: "/")
        guard components.count >= 2, components[0] == "Volumes" else { return nil }
        return "/Volumes/" + components[1]
    }
}
