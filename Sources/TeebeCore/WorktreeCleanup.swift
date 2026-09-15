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
}

public struct CleanupTargets: Equatable, Sendable {
    public let branches: [CleanupBranch]
    public let automatic: CleanupBranch?

    public func resolve(_ override: String?) -> CleanupBranch? {
        guard let override else { return automatic }
        return branches.first { $0.ref == override }
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
    /// True when changed paths match the target despite different commit IDs.
    public var hasEquivalentContent = false
    public var isBroken = false
    public var hasLocalChanges = false
    public var hasIgnoredFiles = false
    public var hasSubmodules = false
    public var hasUncheckedFiles = false
    public var isTarget = false
    public var problem: String?
    public var id: String { worktree.path }

    public init(worktree: Worktree) { self.worktree = worktree }

    public func canRemove(includingIgnored: Bool) -> Bool {
        mergeStatus == .merged && problem == nil && !hasLocalChanges && !hasSubmodules && !hasUncheckedFiles
            && (!hasIgnoredFiles || includingIgnored) && !isTarget
            && !worktree.isPrimary && !worktree.isLocked && !worktree.isBare && !worktree.isDetached
    }
}

public struct CleanupSnapshot: Sendable {
    public let targets: CleanupTargets
    public let target: CleanupBranch?
    public let entries: [CleanupEntry]
    public let checkedAt: Date

    public init(targets: CleanupTargets, target: CleanupBranch?, entries: [CleanupEntry], checkedAt: Date = Date()) {
        self.targets = targets
        self.target = target
        self.entries = entries
        self.checkedAt = checkedAt
    }
}

public protocol WorktreeCleanupChecking: Sendable {
    func scan(repoPath: String, targetOverride: String?) async throws -> CleanupSnapshot
    func fetch(repoPath: String) async throws
    func remove(repoPath: String, entry: CleanupEntry, target: CleanupBranch, includingIgnored: Bool) async throws
}

public enum CleanupError: Error, LocalizedError {
    case changed, unsafe, gitFailed

    public var errorDescription: String? {
        switch self {
        case .changed: return "The worktree or comparison branch changed. Recheck before removing it."
        case .unsafe: return "This worktree has local work or is protected. It was not removed."
        case .gitFailed: return "Git could not complete the check. Recheck after resolving the repository error."
        }
    }
}

/// All scans are local. Fetching is a separate, explicit action. Removal is
/// non-forced and revalidates both the reviewed commit and target immediately.
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

    public func scan(repoPath: String, targetOverride: String?) async throws -> CleanupSnapshot {
        let catalog = try await targets(in: repoPath)
        let target = catalog.resolve(targetOverride)
        let worktrees = try await git.worktrees(repoPath: repoPath)
        let commonDirectory = try await commonDirectory(in: repoPath)
        let entries = await withTaskGroup(of: (Int, CleanupEntry).self) { group in
            var results = [CleanupEntry?](repeating: nil, count: worktrees.count)
            var next = 0
            func enqueue(_ index: Int) {
                group.addTask {
                    (index, await inspect(worktrees[index], target: target, commonDirectory: commonDirectory))
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
        return CleanupSnapshot(targets: catalog, target: target, entries: entries)
    }

    public func fetch(repoPath: String) async throws {
        _ = try await checked(["fetch", "--all", "--no-recurse-submodules"], in: repoPath)
    }

    public func remove(repoPath: String, entry: CleanupEntry, target: CleanupBranch, includingIgnored: Bool) async throws {
        let catalog = try await targets(in: repoPath)
        guard catalog.resolve(target.ref)?.sha == target.sha else { throw CleanupError.changed }
        let worktrees = try await git.worktrees(repoPath: repoPath)
        guard let current = worktrees.first(where: { $0.path == entry.id }),
              current.head == entry.worktree.head, current.branch == entry.worktree.branch else { throw CleanupError.changed }
        let commonDirectory = try await commonDirectory(in: repoPath)
        let checked = await inspect(current, target: target, commonDirectory: commonDirectory)
        guard checked.worktree.head == entry.worktree.head else { throw CleanupError.changed }
        guard checked.canRemove(includingIgnored: includingIgnored) else { throw CleanupError.unsafe }
        try Task.checkCancellation()
        try await git.removeWorktree(repoPath: repoPath, worktreePath: current.path, force: false)
    }

    private func inspect(
        _ worktree: Worktree, target: CleanupBranch?, commonDirectory: String
    ) async -> CleanupEntry {
        var entry = CleanupEntry(worktree: worktree)
        let localRef = worktree.branch.map { "refs/heads/" + $0 }
        let remoteBranch = target?.ref.hasPrefix("refs/remotes/") == true
            ? target?.name.split(separator: "/", maxSplits: 1).last.map(String.init) : nil
        entry.isTarget = target != nil && (localRef == target?.ref
            || (remoteBranch != nil && worktree.branch == remoteBranch))
        guard !worktree.isBare else { entry.problem = "Bare repository"; return entry }
        if let problem = Self.missingWorktreeProblem(worktree.path) {
            entry.isBroken = true
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
            entry.hasIgnoredFiles = changes.contains { $0.worktreeStatus == .ignored }
            entry.hasLocalChanges = changes.contains { $0.worktreeStatus != .ignored }
            let index = try await checked(["ls-files", "--stage", "-v", "-z"], in: worktree.path)
            let indexedFiles = index.stdoutString.split(separator: "\u{0}")
            entry.hasSubmodules = indexedFiles.contains { $0.dropFirst(2).hasPrefix("160000 ") }
            entry.hasUncheckedFiles = indexedFiles.contains { line in
                line.first == "S" || line.first?.isLowercase == true
            }
            guard let target else { entry.problem = "Choose a comparison branch"; return entry }
            let ancestry = try await git.run(["merge-base", "--is-ancestor", entry.worktree.head, target.sha], in: worktree.path)
            switch ancestry.exitCode {
            case 0: entry.mergeStatus = .merged
            case 1:
                entry.hasEquivalentContent = try await GitContentInclusion(git: git).containsChanges(
                    from: entry.worktree.head, in: target.sha, repoPath: worktree.path
                )
                entry.mergeStatus = entry.hasEquivalentContent ? .merged : .notConfirmed
            default: throw CleanupError.gitFailed
            }
        } catch {
            entry.mergeStatus = .unknown
            entry.problem = "Could not inspect this worktree"
        }
        return entry
    }

    private static func missingWorktreeProblem(_ path: String) -> String? {
        for (candidate, message) in [
            (path, "Broken worktree: its folder is missing."),
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
