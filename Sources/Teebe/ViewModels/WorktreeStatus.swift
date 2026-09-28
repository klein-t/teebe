import Foundation
import TeebeCore

/// The one mark a worktree row shows. Case order is precedence: the first that
/// applies wins. Agent activity and uncommitted work outrank what Git says about
/// merging, because they are what needs attention now.
enum WorktreeMark: Equatable {
    /// An agent is mid-turn, or files are changing with no agent.
    case working
    /// The agent finished its turn and is waiting for the user.
    case waiting
    case uncommitted
    /// The folder is there but its `.git` link is gone, so Git can't read it. It
    /// may still hold uncommitted files, so it stays listed and is never forgotten.
    case brokenLink
    /// Merged into a target, nothing uncommitted, nothing Git could be hiding,
    /// nothing protecting it: safe to delete.
    case merged
    /// Not merged yet, merged but protected, being checked, or Git could not tell
    /// (including no result yet).
    case notMerged
    /// The checkout of a merge target itself: merge state does not apply.
    case none
}

/// Icons the hover card and removal prompt use. The view maps them to SF Symbols
/// (pencil, icloud, eye.slash, exclamationmark.triangle) or its own drawing (the
/// git-merge glyph). The card footer uses one fixed icon per fact: pencil, merge,
/// cloud.
enum WorktreeCardIcon: Equatable {
    case pencil, merge, cloud, ignoredFiles, warning
}

struct WorktreeCardFact: Equatable {
    /// `positive`: good news (merged), drawn with a green icon.
    enum Tone: Equatable { case normal, muted, warn, positive }
    let icon: WorktreeCardIcon
    let text: String
    let tone: Tone
}

/// The hover card: a headline (the mark, a title, one line of detail) and the
/// facts the headline does not already say.
struct WorktreeCard: Equatable {
    let title: String
    let subtitle: String
    let facts: [WorktreeCardFact]
}

/// Everything a worktree row shows, resolved from the last merge scan, the live
/// status and the agent state. Pure, so every rule is testable without a view.
struct WorktreeStatus: Equatable {
    /// What the hover trash does, when the row has one.
    enum TrashAction: Equatable {
        /// Remove the folder of a merged row (optionally deleting its local branch).
        case remove(CleanupEntry)
    }

    let mark: WorktreeMark
    /// The group the row belongs to, from Git state only: agent activity never
    /// moves a row. Pinned rows are listed above the groups instead.
    let group: WorktreeGroup
    /// The primary checkout and merge-target checkouts sit above the groups.
    let isPinned: Bool
    let trashAction: TrashAction?
    let card: WorktreeCard
    /// Uncommitted files (live count when known).
    let changeCount: Int
    let remote: RemoteSync
    /// The merge result is known to be out of date: the checkout committed since
    /// it was scanned. The row keeps its group but shows no ✓ and no trash.
    let isRechecking: Bool
    /// What is working in the folder right now, said where removal is confirmed;
    /// nil when nothing is.
    let activityWarning: String?

    var showsTrash: Bool { trashAction != nil }

    /// The mark the row itself draws. Inside a group the heading already says the
    /// Git state, so a grouped row only keeps an agent orb, the broken link (its
    /// heading can't say that), or the ring of a result being rechecked (its
    /// heading is out of date); pinned rows sit above the groups and keep their mark.
    func rowMark(grouped: Bool) -> WorktreeMark {
        guard grouped, !isPinned, mark != .working, mark != .waiting, mark != .brokenLink,
              !(isRechecking && mark == .notMerged) else { return mark }
        return .none
    }

    /// The hover card opens from the mark, so a row that draws none has no card.
    func hasHoverCard(grouped: Bool) -> Bool { rowMark(grouped: grouped) != .none }

    private static func group(_ facts: Facts, isMergedClean: Bool) -> WorktreeGroup {
        if facts.hasUncommitted { return .localChanges }
        // Git can't read a folder whose .git link is gone, so it can't be merged.
        if facts.isBrokenLink { return .notMerged }
        return isMergedClean ? .merged : .notMerged
    }

    private static func mark(_ facts: Facts, isMergedClean: Bool) -> WorktreeMark {
        let agent = facts.info.agentState
        if agent == .working || (agent == .idle && facts.info.isLive) { return .working }
        if agent == .needsAttention { return .waiting }
        if facts.hasUncommitted { return .uncommitted }
        if facts.isBrokenLink { return .brokenLink }
        if facts.isTarget { return .none }
        return isMergedClean ? .merged : .notMerged
    }

    /// - Parameters:
    ///   - merge: the row's last merge result; nil before any scan covered it.
    ///   - targetNames: what the scan checks against, e.g. ["dev", "main"].
    ///   - isChecking: a scan is running (only matters while `merge` is nil).
    init(worktree: Worktree, merge: WorktreeMergeEntry?, info: SelectorModel.WorktreeInfo,
         targetNames: [String], isChecking: Bool) {
        let entry = merge?.entry
        // The worktree list already has a HEAD the scan never saw: a commit in a row
        // that isn't open (an open row's commit sets `isRechecking` itself).
        let headMoved = entry.map { !worktree.head.isEmpty && !$0.worktree.head.isEmpty && $0.worktree.head != worktree.head }
            ?? false
        isRechecking = merge?.isRechecking == true || headMoved
        let facts = Facts(worktree: worktree, entry: entry, info: info,
                          changes: merge?.localChangeCount ?? info.changeCount,
                          targetNames: targetNames, isChecking: isChecking, isRechecking: isRechecking)
        changeCount = facts.changes
        remote = info.remote
        isPinned = worktree.isPrimary || facts.isTarget
        activityWarning = facts.activityWarning
        // Safe to delete means removable: a merged row something protects (locked,
        // detached, files Git hides, a submodule) is not, and says why on its card.
        let isSafeToDelete = entry.map { !facts.hasUncommitted && $0.canRemove(includingIgnored: true) } ?? false
        group = Self.group(facts, isMergedClean: isSafeToDelete)
        mark = Self.mark(facts, isMergedClean: isSafeToDelete && !isRechecking)

        if mark == .merged, let entry, entry.canRemove(includingIgnored: true) {
            trashAction = .remove(entry)
        } else {
            trashAction = nil
        }
        card = facts.card(mark: mark, isRemovable: trashAction != nil)
    }
}

/// The inputs a card is written from, and the wording shared by cards and prompts.
private struct Facts {
    let worktree: Worktree
    let entry: CleanupEntry?
    let info: SelectorModel.WorktreeInfo
    let changes: Int
    let targetNames: [String]
    let isChecking: Bool
    /// The result in `entry` is known to be out of date.
    let isRechecking: Bool

    var hasUncommitted: Bool { changes > 0 || entry?.hasLocalChanges == true }
    var isBrokenLink: Bool { entry?.isBroken == true }
    var isTarget: Bool { entry?.isTarget == true }
    /// Merged and unprotected: only the uncommitted work stands in the way.
    var isRemovableOnceClean: Bool {
        guard var clean = entry else { return false }
        clean.hasLocalChanges = false
        return clean.canRemove(includingIgnored: true)
    }

    var activityWarning: String? {
        switch info.agentState {
        case .working: return "An agent is working here"
        case .needsAttention: return "An agent is waiting for you here"
        case .idle: return info.isLive ? "Files are changing or a command is running here" : nil
        }
    }

    /// Every card: a fixed state title, one short sentence, and the same three facts
    /// (changes, merge, remote) in that order. A broken link has no footer: Git
    /// can't read the folder, so there is nothing to report.
    func card(mark: WorktreeMark, isRemovable: Bool) -> WorktreeCard {
        let (title, subtitle) = headline(mark: mark, isRemovable: isRemovable)
        let facts = mark == .brokenLink ? [] : [changesFact, mergeFact, WorktreeWording.remoteFact(info.remote)]
        return WorktreeCard(title: title, subtitle: subtitle, facts: facts)
    }

    private func headline(mark: WorktreeMark, isRemovable: Bool) -> (String, String) {
        switch mark {
        case .none: return ("Base branch", "Other worktrees are compared to it.")
        case .working:
            return ("Agent working", info.agentState == .working ? "An agent is working in this worktree."
                        : "Files are changing or a command is running here.")
        case .waiting: return ("Waiting for you", "An agent is waiting for your input.")
        case .uncommitted:
            return ("Uncommitted changes", isRemovableOnceClean ? "Commit or discard them before removing."
                        : "Work here isn’t committed yet.")
        case .brokenLink:
            return ("Broken link", "The folder’s .git link is missing, so Teebe leaves its files alone.")
        case .merged:
            return isRemovable ? ("Safe to delete", "All its work is merged. You can remove it.")
                : ("Merged", protectionReason + ", so Teebe won’t remove it.")
        case .notMerged: return notMergedHeadline
        }
    }

    /// No ✓: not merged, not known (yet, or any more), or merged but protected.
    private var notMergedHeadline: (String, String) {
        if isRechecking || (entry == nil && isChecking) {
            let targets = targetNames.isEmpty ? "its merge targets" : WorktreeWording.list(targetNames, joiner: "or")
            return ("Checking…", "Looking for this branch in \(targets).")
        }
        guard let entry else { return ("Couldn’t check", "Git couldn’t compare this branch.") }
        switch entry.mergeStatus {
        case .merged: return ("Merged", protectionReason + ", so Teebe won’t remove it.")
        case .notConfirmed:
            return ("Not merged", entry.hasNoCommits ? "No commits yet." : "Its commits aren’t merged yet.")
        case .unknown: return ("Couldn’t check", "Git couldn’t compare this branch.")
        }
    }

    /// Why a merged row stays, as the start of a sentence.
    private var protectionReason: String { WorktreeWording.protection(worktree, entry) ?? "Protected" }

    var changesFact: WorktreeCardFact {
        guard hasUncommitted else { return WorktreeCardFact(icon: .pencil, text: "No uncommitted changes", tone: .muted) }
        return WorktreeCardFact(icon: .pencil,
                                text: changes > 0 ? WorktreeWording.plural(changes, "uncommitted change") : "Uncommitted changes",
                                tone: .warn)
    }

    var mergeFact: WorktreeCardFact {
        func muted(_ text: String) -> WorktreeCardFact { WorktreeCardFact(icon: .merge, text: text, tone: .muted) }
        if isTarget { return muted("Merge target") }
        if isRechecking { return muted("Checking merge status…") }
        guard let entry else { return muted(isChecking ? "Checking merge status…" : "Couldn’t check merge status") }
        switch entry.mergeStatus {
        case .merged: return WorktreeCardFact(icon: .merge, text: WorktreeWording.mergedText(entry), tone: .positive)
        case .notConfirmed:
            if entry.hasNoCommits { return muted("No commits yet") }
            return muted(targetNames.isEmpty ? "Not merged yet" : "Not in \(WorktreeWording.list(targetNames, joiner: "or")) yet")
        case .unknown: return muted("Couldn’t check merge status")
        }
    }
}

/// Copy shared by the card, the removal prompt and the group headers.
enum WorktreeWording {
    static func plural(_ count: Int, _ word: String) -> String { "\(count) \(word)\(count == 1 ? "" : "s")" }

    /// "dev", "dev and main", "dev, develop and main".
    static func list(_ items: [String], joiner: String = "and") -> String {
        guard items.count > 1, let last = items.last else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " \(joiner) " + last
    }

    /// "Merged into dev and main", "Merged into dev (squashed)".
    static func mergedText(_ entry: CleanupEntry?) -> String {
        guard let entry, !entry.mergedInto.isEmpty else { return "Merged" }
        return "Merged into " + list(entry.mergedInto) + (entry.hasEquivalentContent ? " (squashed)" : "")
    }

    static func remoteFact(_ remote: RemoteSync) -> WorktreeCardFact {
        switch remote {
        case .remoteDeleted: return WorktreeCardFact(icon: .cloud, text: "Remote branch deleted", tone: .muted)
        case .notOnRemote: return WorktreeCardFact(icon: .cloud, text: "Not on remote", tone: .muted)
        case let .sameBranch(name, ahead, behind):
            guard ahead > 0 || behind > 0 else {
                return WorktreeCardFact(icon: .cloud, text: "Up to date with \(name)", tone: .muted)
            }
            let parts = [ahead > 0 ? "\(ahead) to push" : nil, behind > 0 ? "\(behind) to pull" : nil].compactMap { $0 }
            return WorktreeCardFact(icon: .cloud, text: parts.joined(separator: " · "), tone: ahead > 0 ? .normal : .muted)
        }
    }

    /// What keeps Teebe from removing a worktree whatever its merge state, as the
    /// start of a sentence; nil when nothing does.
    static func protection(_ worktree: Worktree, _ entry: CleanupEntry?) -> String? {
        if worktree.isPrimary { return "The main checkout" }
        if worktree.isLocked { return "Locked" }
        if entry?.isBroken == true { return "Its .git link is missing" }
        if worktree.isDetached { return "Detached HEAD" }
        if entry?.hasUncheckedFiles == true { return "Some files are marked unchanged in Git" }
        if entry?.hasSubmodules == true { return "It contains a submodule" }
        return nil
    }

    /// Removal deletes ignored files with the folder. Said only where it matters,
    /// with at most one short example; nil when none of the entries has any.
    static func ignoredFact(_ entries: [CleanupEntry]) -> WorktreeCardFact? {
        guard let entry = entries.first(where: \.hasIgnoredFiles) else { return nil }
        var text = "Ignored files will be deleted too"
        if let path = entry.ignoredPaths.first {
            let short: String = path.count > 24 ? String(path.prefix(8)) + "…" + String(path.suffix(8)) : path
            text += " (\(short))"
        }
        return WorktreeCardFact(icon: .ignoredFiles, text: text, tone: .muted)
    }
}

/// The single-row removal confirmation, per row state.
struct WorktreeRemovalPrompt: Equatable {
    let title: String
    /// The one worktree, as the sheet's list shows it.
    let item: WorktreeRemovalItem
    let facts: [WorktreeCardFact]
    let explanation: String
    /// Show the "Also delete the branch" checkbox: only for a merged row that is
    /// safe to remove, where the branch's work is already in a target.
    let offersBranchDeletion: Bool
    /// Removal is never forced, so Git refuses a folder with uncommitted work or a
    /// submodule. The prompt says why and does not offer Remove.
    let canRemove: Bool

    /// Removing one existing worktree folder.
    init(worktree: Worktree, status: WorktreeStatus, merge: WorktreeMergeEntry?) {
        title = "Remove “\(worktree.branch ?? worktree.name)”?"
        item = WorktreeRemovalItem(name: worktree.branch ?? worktree.name, path: worktree.path,
                                   isMerged: status.mark == .merged)
        let entry = merge?.entry
        let isChecking = entry == nil || status.isRechecking
        var facts = [Self.mergeFact(entry, isChecking: isChecking)]
        let hasUncommitted = status.changeCount > 0 || entry?.hasLocalChanges == true
        if hasUncommitted {
            let changes = status.changeCount > 0 ? WorktreeWording.plural(status.changeCount, "uncommitted change")
                : "Uncommitted changes"
            facts.append(WorktreeCardFact(icon: .pencil, text: changes + ": commit or discard them first", tone: .warn))
        } else {
            facts.append(WorktreeCardFact(icon: .pencil, text: "Nothing uncommitted", tone: .muted))
        }
        let hasSubmodules = entry?.hasSubmodules == true
        if hasSubmodules {
            facts.append(WorktreeCardFact(icon: .warning, text: "Contains a submodule: Git won’t remove it", tone: .warn))
        }
        let protection = hasSubmodules ? nil : WorktreeWording.protection(worktree, entry)
        if let protection {
            facts.append(WorktreeCardFact(icon: .warning, text: protection + ", so Teebe won’t remove it", tone: .warn))
        }
        if let activity = status.activityWarning {
            facts.append(WorktreeCardFact(icon: .warning, text: activity, tone: .warn))
        }
        let isBlocked = hasUncommitted || hasSubmodules || protection != nil || status.activityWarning != nil || isChecking
        // A clean removal takes ignored files with the folder.
        if !isBlocked, let entry, let ignored = WorktreeWording.ignoredFact([entry]) {
            facts.append(ignored)
        }
        self.facts = facts
        canRemove = !isBlocked
        let safe = entry?.mergeStatus == .merged && !hasUncommitted
        explanation = if hasUncommitted {
            "Git only removes a worktree with nothing uncommitted. The branch is kept."
        } else if hasSubmodules {
            "Git won’t remove a worktree that contains a submodule without forcing it, and Teebe never forces."
        } else if protection != nil {
            "Teebe only removes a worktree Git can fully check and nothing protects."
        } else if status.activityWarning != nil {
            "Teebe won’t remove a worktree while something is working in it. Try again when it’s done."
        } else if isChecking {
            "Teebe is still checking this worktree. Try again in a moment."
        } else {
            safe ? "The worktree folder is deleted. Its commits are already merged."
                : "The worktree folder is deleted. The branch is kept."
        }
        offersBranchDeletion = safe && canRemove && status.showsTrash
    }

    private static func mergeFact(_ entry: CleanupEntry?, isChecking: Bool) -> WorktreeCardFact {
        if isChecking { return WorktreeCardFact(icon: .merge, text: "Checking if merged…", tone: .muted) }
        switch entry?.mergeStatus {
        case .merged?: return WorktreeCardFact(icon: .merge, text: WorktreeWording.mergedText(entry), tone: .positive)
        case .notConfirmed?:
            return WorktreeCardFact(icon: .merge, text: entry?.hasNoCommits == true ? "No commits yet" : "Not merged yet",
                                    tone: .muted)
        default: return WorktreeCardFact(icon: .merge, text: "Couldn’t check if merged", tone: .muted)
        }
    }
}
