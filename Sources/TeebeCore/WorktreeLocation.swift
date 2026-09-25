import Foundation

/// Where a new linked worktree's folder goes: the rules behind the New Worktree
/// sheet's pre-filled location.
public enum WorktreeLocation {
    /// The folder new worktrees go in, most specific first: the one last chosen
    /// for this repository, else the parent all its linked worktrees share, else
    /// the repository's own parent (a sibling). Linked worktrees in more than one
    /// folder don't agree on a place, so they fall through to the sibling.
    public static func parentFolder(repoPath: String, remembered: String?, worktrees: [Worktree]) -> String {
        if let remembered, !remembered.isEmpty { return remembered }
        let parents = Set(worktrees.filter { !$0.isPrimary }
            .map { ($0.path as NSString).deletingLastPathComponent })
        if parents.count == 1, let shared = parents.first { return shared }
        return (repoPath as NSString).deletingLastPathComponent
    }

    /// `<repo folder>-<branch>`, with the branch's slashes (and the few other
    /// characters a folder name can't hold) turned into dashes. Empty for no branch.
    public static func folderName(repoPath: String, branch: String) -> String {
        guard !branch.isEmpty else { return "" }
        let repoFolder = (repoPath as NSString).lastPathComponent
        let unsafe = Set("/:\\")
        let slug = String(branch.map { unsafe.contains($0) ? "-" : $0 })
        return "\(repoFolder)-\(slug)"
    }

    /// `path`, or the first of `path-2`, `path-3`, … that isn't taken.
    public static func unique(_ path: String, isTaken: (String) -> Bool) -> String {
        guard isTaken(path) else { return path }
        var suffix = 2
        while isTaken("\(path)-\(suffix)") { suffix += 1 }
        return "\(path)-\(suffix)"
    }

    /// The full, collision-free folder for `branch` inside `parent`. Empty for no branch.
    public static func path(parent: String, repoPath: String, branch: String,
                            isTaken: (String) -> Bool) -> String {
        let name = folderName(repoPath: repoPath, branch: branch)
        guard !name.isEmpty else { return "" }
        return unique((parent as NSString).appendingPathComponent(name), isTaken: isTaken)
    }
}
