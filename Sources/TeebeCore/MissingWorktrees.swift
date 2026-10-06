import Darwin
import Foundation

/// Registered worktrees whose folder is not on disk. One gone from a connected
/// disk is deleted: it can't be browsed, so its record may be forgotten, unless
/// that record is the last thing holding some work (`holdsUnsavedWork`). One
/// that is only out of reach (on a volume that isn't mounted, or locked) is left
/// alone, so it comes back when its drive does.
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
    private let holdsWork: (@Sendable (Worktree, String) async -> Bool)?

    /// `holdsWork` stands in for `holdsUnsavedWork`'s Git reads, for tests.
    public init(git: GitClient,
                folderIsGone: @escaping @Sendable (String) -> Bool = { MissingWorktrees.isGone($0) },
                isVolumeMounted: @escaping @Sendable (String) -> Bool = { MissingWorktrees.isOnMountedVolume($0) },
                holdsWork: (@Sendable (Worktree, String) async -> Bool)? = nil) {
        self.git = git
        self.folderIsGone = folderIsGone
        self.isVolumeMounted = isVolumeMounted
        self.holdsWork = holdsWork
    }

    public func disposition(of worktree: Worktree) -> Disposition {
        guard !worktree.isPrimary, folderIsGone(worktree.path) else { return .present }
        return worktree.isLocked || !isVolumeMounted(worktree.path) ? .unreachable : .deleted
    }

    /// Forget one deleted worktree's record and nothing else. For a folder that is
    /// gone, `git worktree remove` only drops Git's record: the branch is kept, and
    /// Git itself refuses a locked worktree. The folder is checked again right
    /// before, so one that came back is left alone, and so is a record that still
    /// holds work. Returns whether it was forgotten.
    public func forget(_ worktree: Worktree, repoPath: String) async -> Bool {
        guard disposition(of: worktree) == .deleted,
              PathUtil.standardized(worktree.path) != PathUtil.standardized(repoPath),
              !(await holdsUnsavedWork(worktree, repoPath: repoPath)) else { return false }
        do {
            try await git.removeWorktree(repoPath: repoPath, worktreePath: worktree.path, force: false)
            return true
        } catch {
            return false
        }
    }

    /// Whether forgetting this worktree's record could lose work that only it still
    /// holds: a commit its HEAD, or its HEAD's reflog, reached that no branch, tag
    /// or remote branch contains (a detached HEAD's own commits, or ones a reset
    /// left behind), or changes staged in its index. Anything that can't be
    /// verified counts as holding work.
    public func holdsUnsavedWork(_ worktree: Worktree, repoPath: String) async -> Bool {
        if let holdsWork { return await holdsWork(worktree, repoPath) }
        guard let common = try? await git.run(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: repoPath),
              common.succeeded,
              let admin = Self.adminDirectory(of: worktree.path,
                                              commonDirectory: common.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return true }
        let commits = Self.reflogCommits(at: admin.appendingPathComponent("logs/HEAD"))
            + (worktree.head.isEmpty ? [] : [worktree.head])
        guard !commits.isEmpty else { return true }
        let unique = Array(Set(commits)).sorted()
        guard let unreachable = try? await git.run(["rev-list", "-n", "1"] + unique + ["--not", "--branches", "--tags", "--remotes"],
                                                   in: repoPath),
              unreachable.succeeded,
              unreachable.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        // Its index against its HEAD, read from the record: exit 1 means something is staged.
        guard let staged = try? await git.run(["--git-dir=" + admin.path, "diff-index", "--cached", "--quiet", "HEAD", "--"],
                                              in: repoPath) else { return true }
        return staged.exitCode != 0
    }

    /// The worktree's record in `<common>/worktrees/`, found by the `gitdir` file
    /// that points back at its folder.
    static func adminDirectory(of path: String, commonDirectory: String) -> URL? {
        let records = URL(fileURLWithPath: commonDirectory).appendingPathComponent("worktrees")
        let target = PathUtil.standardized(path)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: records.path)) ?? []
        return names.map { records.appendingPathComponent($0) }.first { record in
            guard let gitdir = try? String(contentsOf: record.appendingPathComponent("gitdir"), encoding: .utf8) else { return false }
            let folder = (gitdir.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).deletingLastPathComponent
            return PathUtil.standardized(folder) == target
        }
    }

    /// Every commit a reflog file moved to, oldest first; none when there is no file.
    static func reflogCommits(at url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 2)
            guard fields.count >= 2, [40, 64].contains(fields[1].count), fields[1].allSatisfy(\.isHexDigit),
                  fields[1].contains(where: { $0 != "0" }) else { return nil }
            return String(fields[1])
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
