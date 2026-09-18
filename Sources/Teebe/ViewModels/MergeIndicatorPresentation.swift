import TeebeCore

/// The one line a worktree row's tooltip says about a checkout: the single
/// highest-precedence reason, in the same precedence order `WorktreeGroup.classify`
/// uses. The group header already says which group the row is in.
struct MergeIndicatorPresentation {
    let detail: String

    static let checkingDetail = "Checking new commits…"

    init(status: WorktreeMergeEntry?, targetName: String?, isChecking: Bool) {
        // Nothing scanned this checkout yet. While a scan is running that is a
        // wait, not a failure — don't call it unavailable.
        guard let status else {
            detail = isChecking ? Self.checkingDetail : "Git could not check this worktree."
            return
        }
        detail = Self.detail(status, targetName: targetName)
    }

    /// The one line worth reading, picked in the order the grouping itself uses.
    /// Uncommitted work takes the group, so when the commits are also unmerged the
    /// line says both — one line, two short sentences.
    private static func detail(_ status: WorktreeMergeEntry, targetName: String?) -> String {
        if status.isRechecking { return checkingDetail }
        if status.entry.isBroken { return brokenReason(status.entry) }
        guard let local = localReason(status) else {
            return mergeReason(status.entry, targetName: targetName)
        }
        guard status.entry.hasLocalChanges, status.entry.mergeStatus == .notConfirmed else { return local }
        return local + " " + mergeReason(status.entry, targetName: targetName)
    }

    /// What is in the folder, in the order that decides the group.
    private static func localReason(_ status: WorktreeMergeEntry) -> String? {
        let entry = status.entry
        if entry.hasLocalChanges {
            guard status.localChangeCount > 0 else { return "Uncommitted changes in this folder." }
            return "\(status.localChangeCount) uncommitted file\(status.localChangeCount == 1 ? "" : "s")."
        }
        if entry.hasIgnoredFiles { return ignoredReason(entry) }
        if entry.hasUncheckedFiles { return "Some files are marked unchanged in Git." }
        if entry.hasSubmodules { return "Contains a submodule." }
        return nil
    }

    private static func mergeReason(_ entry: CleanupEntry, targetName: String?) -> String {
        let target = targetName ?? "the comparison branch"
        switch entry.mergeStatus {
        case .merged: return "All commits are in \(target)."
        case .notConfirmed: return "Commits not found in \(target)."
        case .unknown:
            guard targetName != nil else { return "Choose a comparison branch." }
            guard let problem = entry.problem else { return "Git could not check this worktree." }
            return problem.hasSuffix(".") ? problem : problem + "."
        }
    }

    private static func brokenReason(_ entry: CleanupEntry) -> String {
        // The folder is still there, so Prune will leave this row alone: say what
        // does clear it instead of letting the button look broken.
        if entry.problem?.contains(".git link is missing") == true {
            return "The .git link is missing. Remove the folder in Finder, then prune."
        }
        if entry.problem?.contains("folder is missing") == true { return "The folder no longer exists." }
        return "Git cannot access this checkout."
    }

    private static func ignoredReason(_ entry: CleanupEntry) -> String {
        let examples = entry.ignoredPaths.prefix(2).map { path in
            path.count > 36 ? String(path.prefix(16)) + "…" + String(path.suffix(16)) : path
        }.joined(separator: ", ")
        guard !examples.isEmpty else { return "Ignored files remain." }
        return "Ignored files remain (" + examples + (entry.ignoredPaths.count > 2 ? ", …" : "") + ")."
    }
}
