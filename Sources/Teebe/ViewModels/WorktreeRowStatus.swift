import TeebeCore

/// Local edits and committed-work inclusion are independent. An unlabelled row
/// is not a promise of either a clean folder or an unmerged branch.
struct WorktreeRowStatus {
    let changesLabel: String?
    let changesHelp: String
    let mergedHelp: String?

    init(status: WorktreeMergeEntry?, changeCount: Int, targetName: String?, isChecking: Bool) {
        if changeCount > 0 {
            changesLabel = "\(changeCount) change\(changeCount == 1 ? "" : "s")"
        } else {
            changesLabel = status?.entry.hasLocalChanges == true ? "Changes" : nil
        }
        let localHelp = "Uncommitted file changes in this worktree."
        guard let status, let targetName, !isChecking, !status.isRechecking,
              !status.entry.isBroken, !status.entry.isTarget,
              status.entry.mergeStatus == .merged else {
            changesHelp = localHelp
            mergedHelp = nil
            return
        }
        let inclusion = status.entry.hasEquivalentContent
            ? "Committed changes are included in \(targetName)."
            : "All commits are in \(targetName)."
        changesHelp = localHelp + " " + inclusion
        // A positive live count wins even if the last merge scan saw a clean tree.
        guard changesLabel == nil, !status.entry.hasUncheckedFiles, !status.entry.hasSubmodules else {
            mergedHelp = nil
            return
        }
        mergedHelp = inclusion + " No uncommitted changes. Local files may still need keeping."
    }
}
