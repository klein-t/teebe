import TeebeCore

/// What one worktree's status button says: the group's own title, plus at most one
/// detail line — the single highest-precedence reason, in the same precedence order
/// `WorktreeGroup.classify` uses. Six-line popovers are what this replaced.
struct MergeIndicatorPresentation {
    enum Symbol { case branch, merge, edit, ignored, unknown, warning, broken, checking }
    enum Tone { case merged, attention, error, secondary }
    let symbol: Symbol
    let tone: Tone
    let title: String
    /// At most one line. The title carries no trailing punctuation, so the spoken
    /// form never doubles up a period.
    let details: [String]
    var description: String { details.isEmpty ? title : title + ". " + details.joined(separator: " ") }

    static let checkingDetail = "Checking new commits…"

    init(status: WorktreeMergeEntry?, targetName: String?, isChecking: Bool) {
        guard let status else {
            // Nothing scanned this checkout yet. While a scan is running that is a
            // wait, not a failure — don't call it unavailable.
            self.init(symbol: isChecking ? .checking : .unknown,
                      tone: .secondary,
                      title: WorktreeGroup.notChecked.title,
                      detail: isChecking ? Self.checkingDetail : "Git could not check this worktree.")
            return
        }
        let group = WorktreeGroup.classify(status)
        self.init(symbol: Self.symbol(for: group, status: status),
                  tone: Self.tone(for: group, status: status),
                  title: group.title,
                  detail: Self.detail(status, targetName: targetName))
    }

    private static func symbol(for group: WorktreeGroup, status: WorktreeMergeEntry) -> Symbol {
        if status.isRechecking { return .checking }
        switch group {
        case .merged: return status.entry.hasIgnoredFiles ? .ignored : .merge
        case .notChecked:
            return status.entry.hasUncheckedFiles || status.entry.hasSubmodules ? .warning : .unknown
        case .localChanges, .notMerged, .broken: return group.symbol
        }
    }

    private static func tone(for group: WorktreeGroup, status: WorktreeMergeEntry) -> Tone {
        if status.isRechecking { return .secondary }
        switch group {
        case .broken: return .error
        case .localChanges: return .attention
        case .merged: return status.entry.hasIgnoredFiles ? .secondary : .merged
        case .notChecked:
            return status.entry.hasUncheckedFiles || status.entry.hasSubmodules ? .attention : .secondary
        case .notMerged: return .secondary
        }
    }

    /// The one line worth reading, picked in the order the grouping itself uses.
    private static func detail(_ status: WorktreeMergeEntry, targetName: String?) -> String {
        let entry = status.entry
        let target = targetName ?? "the comparison branch"
        if status.isRechecking { return checkingDetail }
        if entry.isBroken { return brokenReason(entry) }
        if entry.hasLocalChanges {
            guard status.localChangeCount > 0 else { return "Uncommitted changes in this folder." }
            return "\(status.localChangeCount) uncommitted file\(status.localChangeCount == 1 ? "" : "s")."
        }
        if entry.hasIgnoredFiles { return ignoredReason(entry) }
        if entry.hasUncheckedFiles { return "Some files are marked unchanged in Git." }
        if entry.hasSubmodules { return "Contains a submodule." }
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
        if entry.problem?.contains(".git link is missing") == true { return "The .git link is missing." }
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

    private init(symbol: Symbol, tone: Tone, title: String, detail: String) {
        self.symbol = symbol
        self.tone = tone
        self.title = title
        self.details = [detail]
    }
}
