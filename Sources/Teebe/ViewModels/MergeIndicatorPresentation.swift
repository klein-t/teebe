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
                      description: isChecking ? "Checking merge status…"
                        : "Merge status unavailable. Refresh worktrees to try again.")
            return
        }
        if entry.isBroken {
            self.init(symbol: "exclamationmark.triangle", tone: .attention,
                      description: entry.problem ?? "Broken worktree: Git cannot access this checkout.")
            return
        }
        let merge = Self.mergeDescription(entry, targetName: targetName)
        let localFiles = Self.localFileDescriptions(entry)
        let explanation = ([merge] + localFiles).joined(separator: "\n\n")
        if entry.hasLocalChanges {
            self.init(symbol: "pencil.circle", tone: .attention, description: explanation)
        } else if !localFiles.isEmpty {
            self.init(symbol: "doc.badge.ellipsis", tone: .secondary, description: explanation)
        } else if entry.mergeStatus == .merged {
            self.init(symbol: "arrow.triangle.merge", tone: .merged,
                      description: merge + "\n\nClean folder: no uncommitted changes or ignored files found.")
        } else {
            self.init(symbol: entry.mergeStatus == .notConfirmed ? "circle.dotted" : "questionmark.circle",
                      tone: .secondary, description: merge)
        }
    }

    private static func mergeDescription(_ entry: CleanupEntry, targetName: String?) -> String {
        guard let targetName else {
            return entry.problem ?? "No comparison branch selected. Choose one in Clean up worktrees."
        }
        switch entry.mergeStatus {
        case .merged:
            return entry.hasEquivalentContent
                ? "Changes already in \(targetName). The changed files match, even though the commit history differs."
                : "All commits are already in \(targetName)."
        case .notConfirmed:
            return "Merge into \(targetName) not confirmed. This branch may have unmerged work. "
                + "Later changes to the same files can also prevent Teebe from recognizing a squash merge."
        case .unknown:
            return entry.problem ?? "Could not check the merge into \(targetName). Refresh worktrees to try again."
        }
    }

    private static func localFileDescriptions(_ entry: CleanupEntry) -> [String] {
        var reasons: [String] = []
        if entry.hasLocalChanges {
            reasons.append("Uncommitted changes: edited, deleted or new files have not been committed.")
        }
        if entry.hasIgnoredFiles {
            reasons.append("Ignored files are present. Git excludes these from commits, often build output or dependencies. "
                + "Removing this folder would also remove them.")
        }
        if entry.hasUncheckedFiles {
            reasons.append("Some tracked files are excluded from Git's change checks. "
                + "Edits to them may be hidden, so Teebe cannot confirm this folder is clean.")
        }
        if entry.hasSubmodules {
            reasons.append("Contains a nested Git repository (submodule). "
                + "Its files and uncommitted changes must be checked inside that repository.")
        }
        return reasons
    }

    private init(symbol: String, tone: Tone, description: String) {
        self.symbol = symbol
        self.tone = tone
        self.description = description
    }
}
