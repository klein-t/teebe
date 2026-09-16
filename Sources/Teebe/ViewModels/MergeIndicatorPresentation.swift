import TeebeCore

struct MergeIndicatorPresentation {
    enum Symbol { case branch, merge, edit, ignored, unknown, warning, broken, checking }
    enum Tone { case merged, attention, error, secondary }
    let symbol: Symbol
    let tone: Tone
    let hasLocalFiles: Bool
    let title: String
    let details: [String]
    var description: String { ([title] + details).joined(separator: ". ") }

    init(status: WorktreeMergeEntry?, targetName: String?, isChecking: Bool) {
        guard let status else {
            self.init(symbol: isChecking ? .checking : .unknown,
                      title: isChecking ? "Checking merge status" : "Status unavailable",
                      details: isChecking ? ["Reading local Git history"] : ["Git could not be checked. Refresh to try again."])
            return
        }
        let entry = status.entry
        if status.isRechecking {
            self.init(symbol: .checking, title: "Checking new commits",
                      details: ["Rechecking this worktree against \(targetName ?? "the comparison branch")."])
            return
        }
        if entry.isBroken {
            let reason = entry.problem?.contains(".git link is missing") == true
                ? "This folder is no longer connected to Git: its .git link is missing."
                : (entry.problem?.contains("folder is missing") == true
                   ? "The worktree folder no longer exists." : "Git cannot access this checkout.")
            self.init(symbol: .broken, tone: .error, title: "Broken worktree", details: [reason])
            return
        }
        let local = Self.localDetails(entry)
        guard let targetName else {
            self.init(symbol: .unknown, hasLocalFiles: !local.isEmpty, title: "Choose a comparison branch",
                      details: ["Select the branch to compare against above the worktree list."] + local)
            return
        }
        if !local.isEmpty, entry.mergeStatus != .unknown {
            let symbol: Symbol = entry.hasLocalChanges ? .edit
                : (entry.hasUncheckedFiles || entry.hasSubmodules ? .warning : .ignored)
            let title = entry.hasLocalChanges ? "Uncommitted changes"
                : (entry.hasUncheckedFiles ? "Some edits may be hidden"
                   : (entry.hasSubmodules ? "Nested Git repository" : "Files ignored by Git"))
            let merge = entry.mergeStatus == .merged
                ? (entry.hasEquivalentContent ? "Changes were included in \(targetName)." : "Commits are already in \(targetName).")
                : "Merge into \(targetName) not confirmed."
            self.init(symbol: symbol, tone: symbol == .ignored ? .secondary : .attention,
                      hasLocalFiles: true, title: title, details: local + [merge])
            return
        }
        switch entry.mergeStatus {
        case .merged:
            self.init(symbol: .merge, tone: .merged,
                      title: entry.hasEquivalentContent ? "Changes included in \(targetName)" : "Merged into \(targetName)",
                      details: ["No uncommitted or ignored files found."])
        case .notConfirmed:
            self.init(symbol: .branch, title: "Merge not confirmed",
                      details: ["Could not verify this branch's changes in \(targetName)."])
        case .unknown:
            self.init(symbol: .unknown, hasLocalFiles: !local.isEmpty, title: "Status unavailable",
                      details: [entry.problem ?? "Git could not check this worktree. Refresh to try again."] + local)
        }
    }

    private static func localDetails(_ entry: CleanupEntry) -> [String] {
        var result: [String] = []
        if entry.hasLocalChanges { result.append("Changes in this folder have not been committed.") }
        if entry.hasIgnoredFiles {
            let examples = entry.ignoredPaths.prefix(2).map { path in
                path.count > 36 ? String(path.prefix(16)) + "…" + String(path.suffix(16)) : path
            }.joined(separator: ", ")
            result.append(examples.isEmpty ? "Git ignore rules exclude files from commits."
                          : "Not included in commits: " + examples + (entry.ignoredPaths.count > 2 ? ", …" : ""))
        }
        if entry.hasUncheckedFiles { result.append("Git is set to skip checking some tracked files for edits.") }
        if entry.hasSubmodules { result.append("A submodule has its own files and changes to check.") }
        return result
    }

    private init(symbol: Symbol, tone: Tone = .secondary, hasLocalFiles: Bool = false,
                 title: String, details: [String]) {
        self.symbol = symbol
        self.tone = tone
        self.hasLocalFiles = hasLocalFiles
        self.title = title
        self.details = details
    }
}
