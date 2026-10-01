import Foundation

public struct CleanupBranch: Identifiable, Equatable, Sendable {
    public let ref: String
    public let sha: String
    public let upstream: String
    public var id: String { ref }
    public var name: String {
        let prefix = ref.hasPrefix("refs/heads/") ? "refs/heads/" : "refs/remotes/"
        return String(ref.dropFirst(prefix.count))
    }
    /// The name without its remote: `origin/dev` and `dev` are both `dev`.
    public var shortName: String {
        guard ref.hasPrefix("refs/remotes/") else { return name }
        return name.split(separator: "/", maxSplits: 1).last.map(String.init) ?? name
    }
}

public struct CleanupTargets: Equatable, Sendable {
    public let branches: [CleanupBranch]
    public let automatic: CleanupBranch?

    /// The branches work conventionally merges into, checked when they exist.
    public static let integrationNames = ["dev", "develop", "main", "master"]
    /// Ancestry is one cheap `merge-base` per target, but an unmerged branch also
    /// pays a content (squash) check against every target, up to ~20 tree diffs
    /// each. Four covers the default plus dev/develop/main/master in practice.
    public static let mergeTargetLimit = 4

    /// The branch with exactly this ref, if the repository still has it.
    public func branch(_ ref: String) -> CleanupBranch? {
        branches.first { $0.ref == ref }
    }

    /// The branch a saved extra target names: a full ref as the picker saves it, or a
    /// name typed in Settings (`release`, `origin/release`), origin's copy first.
    public func extraBranch(_ extra: String?) -> CleanupBranch? {
        guard let name = extra?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        return branch(name) ?? branch("refs/remotes/origin/" + name) ?? branch("refs/heads/" + name)
            ?? branch("refs/remotes/" + name)
    }

    /// What every worktree is checked against, in display order: the automatic
    /// default, the per-repository extra branch, then the integration branches that
    /// exist (origin's copy preferred over the local one). Integration branches are
    /// one per name; an explicitly chosen extra is kept even when it shares a name,
    /// since a local `dev` can hold merges its origin copy does not have yet.
    public func mergeTargets(extra: String?) -> [CleanupBranch] {
        let extraBranch = self.extraBranch(extra)
        var result: [CleanupBranch] = []
        func add(_ branch: CleanupBranch?) {
            guard let branch, result.count < Self.mergeTargetLimit, !result.contains(where: {
                $0.ref == branch.ref || (extraBranch?.ref != branch.ref && extraBranch?.ref != $0.ref
                                         && $0.shortName == branch.shortName)
            }) else { return }
            result.append(branch)
        }
        add(automatic)
        add(extraBranch)
        for name in Self.integrationNames {
            add(branch("refs/remotes/origin/" + name) ?? branch("refs/heads/" + name))
        }
        return result
    }

    public static func parse(_ output: String) -> CleanupTargets {
        let records = output.split(separator: "\n").map {
            $0.split(separator: "\u{0}", omittingEmptySubsequences: false).map(String.init)
        }.filter { $0.count == 4 }
        let branches = records.filter { $0[3].isEmpty }.map {
            CleanupBranch(ref: $0[0], sha: $0[1], upstream: $0[2])
        }
        let defaults = records.filter { $0[0].hasPrefix("refs/remotes/") && $0[0].hasSuffix("/HEAD") && !$0[3].isEmpty }
        let recorded = defaults.first { $0[0] == "refs/remotes/origin/HEAD" }?[3]
            ?? (defaults.count == 1 ? defaults.first?[3] : nil)
        var automatic = branches.first { $0.ref == recorded }
        if automatic == nil {
            let candidates = ["main", "master"].compactMap { name in
                branches.first { $0.ref == "refs/remotes/origin/" + name }
                    ?? branches.first { $0.ref == "refs/heads/" + name }
            }
            if candidates.count == 1 { automatic = candidates.first }
        }
        return CleanupTargets(branches: branches, automatic: automatic)
    }
}

public enum CleanupMergeStatus: Equatable, Sendable {
    case merged, notConfirmed, unknown
}

public struct CleanupEntry: Identifiable, Equatable, Sendable {
    public var worktree: Worktree
    public var mergeStatus: CleanupMergeStatus = .unknown
    /// The targets that contain this branch, as they were when checked: by ancestry
    /// every one that does, or else the first that contains it by content.
    public var mergedTargets: [CleanupBranch] = []
    /// True when changed paths match the target despite different commit IDs
    /// (a squash merge), rather than the branch being an ancestor.
    public var hasEquivalentContent = false
    public var isBroken = false
    /// Broken because the folder itself is gone, not only its `.git` link.
    public var isFolderMissing = false
    public var hasLocalChanges = false
    public var hasIgnoredFiles = false
    public var ignoredPaths: [String] = []
    /// The files inside `ignoredPaths`, read for a checkout nothing else keeps
    /// from being removed; nil otherwise.
    public var ignoredFiles: IgnoredFiles?
    public var hasSubmodules = false
    public var hasUncheckedFiles = false
    /// The checkout's branch is one of the merge targets.
    public var isTarget = false
    /// The branch has no commits of its own yet: its tip is still where it was
    /// created from. Ancestry would call it merged, but there is no work of its
    /// own to be merged, so it is reported as not merged.
    public var hasNoCommits = false
    /// `hasNoCommits` is proven by the branch's own record of where it was
    /// created, rather than inferred from where its tip sits (which a branch
    /// fast-forwarded into a target, with its reflogs gone, looks the same as).
    public var hasNoCommitsConfirmed = false
    /// A rebase, merge, cherry-pick, revert or bisect left unfinished here. Its
    /// state is in the checkout's git directory, so the folder is never removed.
    public var operation: GitOperation?
    /// The folder's status and index were read, so the local-work flags above are
    /// facts rather than defaults.
    public var isInspected = false
    public var problem: String?
    public var id: String { worktree.path }

    public init(worktree: Worktree) { self.worktree = worktree }

    /// Short names of the branches this is merged into, in target order, e.g. ["dev", "main"].
    public var mergedInto: [String] {
        mergedTargets.map(\.shortName).reduce(into: []) { names, name in
            if !names.contains(name) { names.append(name) }
        }
    }

    public func canRemove(includingIgnored: Bool) -> Bool {
        mergeStatus == .merged && problem == nil && isFolderRemovable(includingIgnored: includingIgnored)
    }

    /// Removing the folder alone loses nothing and nothing protects it, whether or
    /// not the branch is merged: the branch keeps its commits.
    public func canRemoveFolder(includingIgnored: Bool) -> Bool {
        isInspected && !isBroken && isFolderRemovable(includingIgnored: includingIgnored)
    }

    private func isFolderRemovable(includingIgnored: Bool) -> Bool {
        !hasLocalChanges && !hasSubmodules && !hasUncheckedFiles && (!hasIgnoredFiles || includingIgnored) && !isTarget
            && operation == nil
            && !worktree.isPrimary && !worktree.isLocked && !worktree.isBare && !worktree.isDetached
    }
}

public struct CleanupSnapshot: Sendable {
    public let targets: CleanupTargets
    /// What the entries were checked against, in order.
    public let mergeTargets: [CleanupBranch]
    public let entries: [CleanupEntry]
    public let checkedAt: Date

    public init(targets: CleanupTargets, mergeTargets: [CleanupBranch], entries: [CleanupEntry], checkedAt: Date = Date()) {
        self.targets = targets
        self.mergeTargets = mergeTargets
        self.entries = entries
        self.checkedAt = checkedAt
    }

    /// Short names of the merge targets, deduplicated, e.g. ["dev", "main"].
    public var targetNames: [String] {
        mergeTargets.map(\.shortName).reduce(into: []) { names, name in
            if !names.contains(name) { names.append(name) }
        }
    }
}

/// What happened to the local branch after its worktree folder was removed.
public enum BranchDeletion: Equatable, Sendable {
    /// Deleting it was not asked for.
    case notRequested
    case deleted
    /// Asked for, but the branch moved, a target changed, or Git refused: it stays.
    case kept
}

public protocol WorktreeCleanupChecking: Sendable {
    func scan(repoPath: String, extraTarget: String?) async throws -> CleanupSnapshot
    /// Removes the folder without force, after revalidating the entry: the same
    /// commit, nothing uncommitted or hidden, nothing protecting it, and, for a
    /// merged entry, a target it was merged into that has not moved. With
    /// `deleteBranch` (merged entries only), then deletes the local branch (never a
    /// remote one) if it is still merged into an unchanged target. An unmerged
    /// entry's branch always stays: it holds the commits. So does a merge target's.
    @discardableResult
    func remove(repoPath: String, entry: CleanupEntry, includingIgnored: Bool, deleteBranch: Bool) async throws -> BranchDeletion
}

public enum CleanupError: Error, LocalizedError {
    case changed, unsafe, gitFailed

    public var errorDescription: String? {
        switch self {
        case .changed: return "The worktree or the branch it was merged into changed. Recheck before removing it."
        case .unsafe: return "This worktree has local work or is protected. It was not removed."
        case .gitFailed: return "Git could not complete the check. Recheck after resolving the repository error."
        }
    }
}

/// All scans are local: fetching is the `RemoteRefresher`'s job, in the background.
/// Removal is non-forced and revalidates both the reviewed commit and the targets it
/// was merged into immediately.
public struct WorktreeCleanupService: WorktreeCleanupChecking {
    private let git: GitClient
    public init(git: GitClient) { self.git = git }

    private func targets(in repoPath: String) async throws -> CleanupTargets {
        let result = try await checked([
            "for-each-ref", "--format=%(refname)%00%(objectname)%00%(upstream)%00%(symref)",
            "refs/heads/", "refs/remotes/"
        ], in: repoPath)
        return CleanupTargets.parse(result.stdoutString)
    }

    public func scan(repoPath: String, extraTarget: String?) async throws -> CleanupSnapshot {
        let catalog = try await targets(in: repoPath)
        let mergeTargets = catalog.mergeTargets(extra: extraTarget)
        let worktrees = try await git.worktrees(repoPath: repoPath)
        let commonDirectory = try await commonDirectory(in: repoPath)
        let entries = await withTaskGroup(of: (Int, CleanupEntry).self) { group in
            var results = [CleanupEntry?](repeating: nil, count: worktrees.count)
            var next = 0
            func enqueue(_ index: Int) {
                group.addTask {
                    (index, await inspect(worktrees[index], targets: mergeTargets, commonDirectory: commonDirectory))
                }
            }
            while next < min(4, worktrees.count) { enqueue(next); next += 1 }
            for await (index, entry) in group {
                results[index] = entry
                if next < worktrees.count, !Task.isCancelled { enqueue(next); next += 1 }
            }
            return results.compactMap { $0 }
        }
        try Task.checkCancellation()
        return CleanupSnapshot(targets: catalog, mergeTargets: mergeTargets, entries: entries)
    }

    @discardableResult
    public func remove(
        repoPath: String, entry: CleanupEntry, includingIgnored: Bool, deleteBranch: Bool
    ) async throws -> BranchDeletion {
        // A merge target's own checkout is only ever a folder removal: its branch is
        // what the others are compared against.
        let isMerged = !entry.mergedTargets.isEmpty && !entry.isTarget
        // Asked to delete the branch of work that wasn't merged when it was checked:
        // what was confirmed is not what is being removed.
        guard isMerged || !deleteBranch else { throw CleanupError.changed }
        let catalog = try await targets(in: repoPath)
        // Only a target still at the commit that was checked vouches for the merge.
        let unchanged = entry.mergedTargets.filter { catalog.branch($0.ref)?.sha == $0.sha }
        guard !isMerged || !unchanged.isEmpty else { throw CleanupError.changed }
        let worktrees = try await git.worktrees(repoPath: repoPath)
        guard let current = worktrees.first(where: { $0.path == entry.id }),
              current.head == entry.worktree.head, current.branch == entry.worktree.branch else { throw CleanupError.changed }
        let commonDirectory = try await commonDirectory(in: repoPath)
        let checked = await inspect(current, targets: isMerged ? unchanged : [], commonDirectory: commonDirectory)
        guard checked.worktree.head == entry.worktree.head else { throw CleanupError.changed }
        // Consent covers the ignored files that were reviewed, not any that showed
        // up since, even inside a folder that was already listed. A new secrets file
        // or nested repository voids the confirmation.
        guard !includingIgnored || (checked.ignoredPaths == entry.ignoredPaths && checked.ignoredFiles == entry.ignoredFiles)
        else { throw CleanupError.changed }
        let isRemovable = isMerged ? checked.canRemove(includingIgnored: includingIgnored)
            : checked.canRemoveFolder(includingIgnored: includingIgnored)
        guard isRemovable, !isMerged || !Self.isTarget(current, among: catalog.mergeTargets(extra: nil)) else {
            throw CleanupError.unsafe
        }
        try Task.checkCancellation()
        try await git.removeWorktree(repoPath: repoPath, worktreePath: current.path, force: false)
        guard deleteBranch, let branch = current.branch else { return .notRequested }
        return await deleteMergedBranch(branch, head: checked.worktree.head,
                                        targets: checked.mergedTargets, repoPath: repoPath)
    }

    /// Deletes the local branch only while its tip is the commit that was checked
    /// and is still merged into a target that has not moved. Remote branches are
    /// never touched. Any doubt keeps the branch: the folder is already gone, so
    /// failing here loses nothing. The delete itself names the checked commit, so
    /// Git refuses it if the branch moved at any point after the check.
    private func deleteMergedBranch(
        _ branch: String, head: String, targets: [CleanupBranch], repoPath: String
    ) async -> BranchDeletion {
        let ref = "refs/heads/" + branch
        guard let worktrees = try? await git.worktrees(repoPath: repoPath),
              !worktrees.contains(where: { $0.branch == branch }),
              let catalog = try? await self.targets(in: repoPath),
              catalog.branch(ref)?.sha == head else { return .kept }
        let unchanged = targets.filter { catalog.branch($0.ref)?.sha == $0.sha }
        guard let confirmed = try? await mergedTargets(of: head, among: unchanged, in: repoPath).targets,
              !confirmed.isEmpty,
              let result = try? await git.run(["update-ref", "--no-deref", "-d", ref, head], in: repoPath),
              result.succeeded else { return .kept }
        // What `git branch -D` also drops: the branch's upstream and other settings.
        _ = try? await git.run(["config", "--remove-section", "branch." + branch], in: repoPath)
        return .deleted
    }

    private func inspect(
        _ worktree: Worktree, targets: [CleanupBranch], commonDirectory: String
    ) async -> CleanupEntry {
        var entry = CleanupEntry(worktree: worktree)
        entry.isTarget = Self.isTarget(worktree, among: targets)
        guard !worktree.isBare else { entry.problem = "Bare repository"; return entry }
        entry.problem = Self.refusal(for: worktree)
        if let problem = Self.missingWorktreeProblem(worktree.path) {
            entry.isBroken = true
            entry.isFolderMissing = problem == Self.missingFolder
            entry.problem = problem
            return entry
        }
        do {
            guard try await self.commonDirectory(in: worktree.path) == commonDirectory else { throw CleanupError.gitFailed }
            let root = try await checked(["rev-parse", "--show-toplevel"], in: worktree.path)
            guard PathUtil.standardized(root.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines))
                    == PathUtil.standardized(worktree.path) else { throw CleanupError.gitFailed }
            let head = try await checked(["rev-parse", "--verify", "HEAD^{commit}"], in: worktree.path)
            entry.worktree.head = head.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            let status = try await checked([
                "status", "--porcelain=v2", "-z", "--untracked-files=normal", "--ignored=matching", "--ignore-submodules=none"
            ], in: worktree.path)
            let changes = StatusParser.parse(status.stdoutString).changes
            entry.ignoredPaths = changes.filter { $0.worktreeStatus == .ignored }.map(\.path).sorted()
            entry.hasIgnoredFiles = !entry.ignoredPaths.isEmpty
            entry.hasLocalChanges = changes.contains { $0.worktreeStatus != .ignored }
            let index = try await checked(["ls-files", "--stage", "-v", "-z"], in: worktree.path)
            let indexedFiles = index.stdoutString.split(separator: "\u{0}")
            entry.hasSubmodules = indexedFiles.contains { $0.dropFirst(2).hasPrefix("160000 ") }
            entry.hasUncheckedFiles = indexedFiles.contains { line in
                line.first == "S" || line.first?.isLowercase == true
            }
            let gitDirectory = try await checked(["rev-parse", "--path-format=absolute", "--git-dir"], in: worktree.path)
            entry.operation = GitOperation.detect(gitDirectory: gitDirectory.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines))
            entry.isInspected = true
            // Only where removal could go ahead: counting a large ignored folder costs a walk.
            if entry.hasIgnoredFiles, !entry.hasLocalChanges, !entry.hasSubmodules, !entry.hasUncheckedFiles,
               entry.operation == nil, !worktree.isPrimary, !worktree.isLocked, !worktree.isDetached {
                entry.ignoredFiles = IgnoredFiles.inventory(in: worktree.path, entries: entry.ignoredPaths)
            }
            guard !targets.isEmpty else { entry.problem = "No branch to compare against"; return entry }
            let merge = try await mergedTargets(of: entry.worktree.head, among: targets, in: worktree.path)
            entry.mergedTargets = merge.targets
            entry.hasEquivalentContent = merge.byContent
            entry.mergeStatus = merge.targets.isEmpty ? .notConfirmed : .merged
            if !merge.targets.isEmpty, !merge.byContent, !entry.isTarget {
                let fresh = await freshness(branch: worktree.branch, head: entry.worktree.head, targets: targets,
                                            in: worktree.path)
                if fresh.isFresh {
                    entry.hasNoCommits = true
                    entry.hasNoCommitsConfirmed = fresh.isConfirmed
                    entry.mergedTargets = []
                    entry.mergeStatus = .notConfirmed
                }
            }
        } catch {
            entry.mergeStatus = .unknown
            entry.mergedTargets = []
            entry.hasEquivalentContent = false
            entry.problem = "Could not inspect this worktree"
        }
        return entry
    }

    /// Every target that has `head` as an ancestor. When none does, the first
    /// target, in order, that contains its changes by content (a squash merge).
    private func mergedTargets(
        of head: String, among targets: [CleanupBranch], in path: String
    ) async throws -> (targets: [CleanupBranch], byContent: Bool) {
        var ancestors: [CleanupBranch] = []
        for target in targets {
            let ancestry = try await git.run(["merge-base", "--is-ancestor", head, target.sha], in: path)
            switch ancestry.exitCode {
            case 0: ancestors.append(target)
            case 1: continue
            default: throw CleanupError.gitFailed
            }
        }
        if !ancestors.isEmpty { return (ancestors, false) }
        let inclusion = GitContentInclusion(git: git)
        for target in targets where try await inclusion.containsChanges(from: head, in: target.sha, repoPath: path) {
            return ([target], true)
        }
        return ([], false)
    }

    /// Whether the checkout never got a commit of its own: its tip is still where it
    /// was created from.
    ///
    /// A branch's reflog says where it was created: when the oldest entry is
    /// `branch: Created from <start>`, the tip is still that commit, and the start is
    /// a target, HEAD or a commit id, nothing was committed on it (a branch cut from
    /// another feature branch carries that branch's commits, so it doesn't count).
    ///
    /// Without that record (a bare repository logs no ref updates by default, and
    /// reflogs expire; a detached checkout has no branch at all), what can be known:
    /// - a reflog entry, the branch's or the worktree's HEAD's, that committed the tip
    ///   means the tip is its own work;
    /// - otherwise a tip exactly on a target's tip, or on a target's first-parent
    ///   line, may be where it was cut, and counts as fresh. A branch fast-forwarded
    ///   into a target with every reflog gone looks the same and can't be told apart,
    ///   so it stays unconfirmed rather than risk a ✓ on a branch just started;
    /// - a tip that reached a target only through a merge commit is merged work.
    ///
    /// Only the creation record confirms it (`isConfirmed`); the rest is a likely
    /// reading.
    private func freshness(
        branch: String?, head: String, targets: [CleanupBranch], in path: String
    ) async -> (isFresh: Bool, isConfirmed: Bool) {
        let branchLog = await reflog(branch.map { "refs/heads/" + $0 }, in: path)
        if let oldest = branchLog.last, oldest.subject.hasPrefix(Self.createdPrefix) {
            guard oldest.sha == head else { return (false, false) }
            var start = String(oldest.subject.dropFirst(Self.createdPrefix.count))
            for refPrefix in ["refs/heads/", "refs/remotes/"] where start.hasPrefix(refPrefix) {
                start = String(start.dropFirst(refPrefix.count))
            }
            let isCommitID = start.count >= 7 && start.allSatisfy(\.isHexDigit)
            let targetNames = Set(targets.flatMap { [$0.name, $0.shortName] } + CleanupTargets.integrationNames)
            let isFresh = start == "HEAD" || isCommitID || targetNames.contains(start)
            return (isFresh, isFresh)
        }
        let logs = branchLog + (await reflog("HEAD", in: path))
        if logs.contains(where: { $0.sha == head && $0.subject.hasPrefix("commit") }) { return (false, false) }
        if targets.contains(where: { $0.sha == head }) { return (true, false) }
        for target in targets where await isOnFirstParentLine(head, of: target, in: path) { return (true, false) }
        return (false, false)
    }

    private static let createdPrefix = "branch: Created from "

    /// A ref's reflog, newest first; empty when it has none or Git can't read it.
    private func reflog(_ ref: String?, in path: String) async -> [(sha: String, subject: String)] {
        guard let ref, let result = try? await git.run(["reflog", "show", "--format=%H%x00%gs", ref, "--"], in: path),
              result.succeeded else { return [] }
        return result.stdoutString.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\u{0}", maxSplits: 1, omittingEmptySubsequences: false)
            return fields.count == 2 ? (String(fields[0]), String(fields[1])) : nil
        }
    }

    /// Whether `commit`, an ancestor of the target, is on the target's own
    /// first-parent line rather than reached through a merge commit. Walking first
    /// parents down from the target stops at the first commit `commit` contains;
    /// the last one walked has `commit` itself as its first parent exactly when it
    /// is on the line.
    private func isOnFirstParentLine(_ commit: String, of target: CleanupBranch, in path: String) async -> Bool {
        guard let result = try? await git.run(["rev-list", "--first-parent", "--parents", target.sha, "^" + commit], in: path),
              result.succeeded,
              let last = result.stdoutString.split(separator: "\n").last else { return false }
        let fields = last.split(separator: " ")
        return fields.count > 1 && fields[1] == commit
    }

    /// The checkout is a merge target's own branch: local `dev`, or the local
    /// branch named like a remote target (`dev` for `origin/dev`).
    private static func isTarget(_ worktree: Worktree, among targets: [CleanupBranch]) -> Bool {
        guard let branch = worktree.branch else { return false }
        return targets.contains { target in
            target.ref == "refs/heads/" + branch
                || (target.ref.hasPrefix("refs/remotes/") && target.shortName == branch)
        }
    }

    /// A worktree can be perfectly merged and still be refused. Naming the reason
    /// keeps an entry from reading as "merged, nothing wrong" behind a dead control.
    private static func refusal(for worktree: Worktree) -> String? {
        if worktree.isDetached { return "Detached HEAD" }
        if worktree.isLocked { return "Locked worktree" }
        return nil
    }

    private static let missingFolder = "Broken worktree: its folder is missing."

    private static func missingWorktreeProblem(_ path: String) -> String? {
        for (candidate, message) in [
            (path, missingFolder),
            (path + "/.git", "Broken worktree: its .git link is missing. Remaining files were not changed.")
        ] {
            do { _ = try FileManager.default.attributesOfItem(atPath: candidate) } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
                return message
            } catch { return nil } // Permission errors remain unavailable, not missing.
        }
        return nil
    }

    private func commonDirectory(in path: String) async throws -> String {
        let result = try await checked(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: path)
        return PathUtil.standardized(result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func checked(_ arguments: [String], in path: String) async throws -> GitInvocationResult {
        try Task.checkCancellation()
        let result = try await git.run(arguments, in: path)
        guard result.succeeded else { throw CleanupError.gitFailed }
        return result
    }
}
