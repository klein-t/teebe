import TeebeCore

/// A merge result and the folder's local state must both support a green arrow.
struct MergeIndicatorPresentation {
    enum Tone { case merged, attention, secondary }
    let symbol: String
    let tone: Tone
    let description: String

    init(entry: CleanupEntry?, targetName: String?, isChecking: Bool) {
        guard let entry else {
            self.init(symbol: "questionmark.circle", tone: .secondary,
                      description: isChecking ? "Checking merge status…" : "Merge status unavailable")
            return
        }
        if entry.isBroken {
            self.init(symbol: "exclamationmark.triangle", tone: .attention,
                      description: entry.problem ?? "Broken worktree")
            return
        }
        let merge: String
        if let targetName {
            switch entry.mergeStatus {
            case .merged:
                merge = entry.hasEquivalentContent
                    ? "Branch changes already match \(targetName), including squash-equivalent changes."
                    : "Commits included in \(targetName)."
            case .notConfirmed:
                merge = "Inclusion in \(targetName) not confirmed. Unmerged work or later edits in the target can cause this."
            case .unknown: merge = entry.problem ?? "Merge status unavailable."
            }
        } else {
            merge = entry.problem ?? "Choose a merge target in Clean up worktrees."
        }
        if entry.hasLocalChanges {
            self.init(symbol: "pencil.circle", tone: .attention,
                      description: "Uncommitted changes or new files. " + merge)
        } else if entry.hasIgnoredFiles || entry.hasUncheckedFiles || entry.hasSubmodules {
            self.init(symbol: "doc.badge.ellipsis", tone: .secondary,
                      description: "Ignored files or files requiring separate checks remain. " + merge)
        } else if entry.mergeStatus == .merged {
            self.init(symbol: "arrow.triangle.merge", tone: .merged,
                      description: merge + " No uncommitted files found. Cleanup checks removal separately.")
        } else {
            self.init(symbol: entry.mergeStatus == .notConfirmed ? "circle.dotted" : "questionmark.circle",
                      tone: .secondary, description: merge)
        }
    }

    private init(symbol: String, tone: Tone, description: String) {
        self.symbol = symbol
        self.tone = tone
        self.description = description
    }
}
