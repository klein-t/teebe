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
    /// Git lists the worktree but its folder or `.git` link is gone.
    case missing
    /// Merged into a target, nothing uncommitted, nothing Git could be hiding.
    case merged
    /// Not merged yet, or Git could not tell (including no result yet).
    case notMerged
    /// The checkout of a merge target itself: merge state does not apply.
    case none
}

/// Icons the hover card and removal prompt use. The view maps them to SF Symbols
/// (suggested: pencil, arrow.triangle.merge, arrow.triangle.branch, icloud,
/// questionmark.folder, eye.slash, exclamationmark.triangle). The card footer
/// uses one fixed icon per fact: pencil, branch, cloud.
enum WorktreeCardIcon: Equatable {
    case pencil, merge, branch, cloud, missing, ignoredFiles, warning
}

struct WorktreeCardFact: Equatable {
    enum Tone: Equatable { case normal, muted, warn }
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
        /// Forget missing worktrees (`git worktree prune`).
        case prune
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

    var showsTrash: Bool { trashAction != nil }

    /// The mark the row itself draws. Inside a group the heading already says the
    /// Git state, so a grouped row only keeps an agent orb; pinned rows sit above
    /// the groups and keep their mark.
    func rowMark(grouped: Bool) -> WorktreeMark {
        guard grouped, !isPinned, mark != .working, mark != .waiting else { return mark }
        return .none
    }

    private static func group(_ facts: Facts, isMergedClean: Bool) -> WorktreeGroup {
        if facts.hasUncommitted { return .localChanges }
        if facts.isMissing { return .broken }
        return isMergedClean ? .merged : .notMerged
    }

    private static func mark(_ facts: Facts, isMergedClean: Bool) -> WorktreeMark {
        let agent = facts.info.agentState
        if agent == .working || (agent == .idle && facts.info.isLive) { return .working }
        if agent == .needsAttention { return .waiting }
        if facts.hasUncommitted { return .uncommitted }
        if facts.isMissing { return .missing }
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
        let facts = Facts(worktree: worktree, entry: entry, info: info,
                          changes: merge?.localChangeCount ?? info.changeCount,
                          targetNames: targetNames, isChecking: isChecking)
        changeCount = facts.changes
        remote = info.remote
        isPinned = worktree.isPrimary || facts.isTarget
        let isMergedClean = entry.map { $0.mergeStatus == .merged && !facts.hasUncommitted && !$0.isBroken
            && !$0.hasUncheckedFiles && !$0.hasSubmodules } ?? false
        group = Self.group(facts, isMergedClean: isMergedClean)
        mark = Self.mark(facts, isMergedClean: isMergedClean)

        if mark == .missing {
            trashAction = .prune
        } else if mark == .merged, let entry, entry.canRemove(includingIgnored: true) {
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

    var hasUncommitted: Bool { changes > 0 || entry?.hasLocalChanges == true }
    var isMissing: Bool { entry?.isBroken == true }
    var isTarget: Bool { entry?.isTarget == true }
    /// Merged and unprotected: only the uncommitted work stands in the way.
    var isRemovableOnceClean: Bool {
        guard var clean = entry else { return false }
        clean.hasLocalChanges = false
        return clean.canRemove(includingIgnored: true)
    }

    /// Every card: a fixed state title, one short sentence, and the same three facts
    /// (changes, merge, remote) in that order. Missing has no footer: there is no
    /// folder left to describe.
    func card(mark: WorktreeMark, isRemovable: Bool) -> WorktreeCard {
        let (title, subtitle) = headline(mark: mark, isRemovable: isRemovable)
        let facts = mark == .missing ? [] : [changesFact, mergeFact, WorktreeWording.remoteFact(info.remote)]
        return WorktreeCard(title: title, subtitle: subtitle, facts: facts)
    }

    private func headline(mark: WorktreeMark, isRemovable: Bool) -> (String, String) {
        switch mark {
        case .none: return ("Base branch", "Other worktrees are compared to it.")
        case .working:
            return ("Agent working", info.agentState == .working ? "An agent is working in this worktree."
                        : "Files are changing in this worktree.")
        case .waiting: return ("Waiting for you", "An agent is waiting for your input.")
        case .uncommitted:
            return ("Uncommitted changes", isRemovableOnceClean ? "Commit or discard them before removing."
                        : "Work here isn’t committed yet.")
        case .missing: return ("Missing", "The folder is gone. Remove it to clean up.")
        case .merged:
            return isRemovable ? ("Safe to delete", "All its work is merged. You can remove it.")
                : ("Merged", protectionReason + ", so Teebe won’t remove it.")
        case .notMerged: return notMergedHeadline
        }
    }

    /// No ✓: not merged, not known yet, or merged but Git could be hiding local work.
    private var notMergedHeadline: (String, String) {
        guard let entry else {
            guard isChecking else { return ("Couldn’t check", "Git couldn’t compare this branch.") }
            let targets = targetNames.isEmpty ? "its merge targets" : WorktreeWording.list(targetNames, joiner: "or")
            return ("Checking…", "Looking for this branch in \(targets).")
        }
        switch entry.mergeStatus {
        case .merged: return ("Merged", protectionReason + ", so Teebe won’t remove it.")
        case .notConfirmed: return ("Not merged", "Its commits aren’t merged yet.")
        case .unknown: return ("Couldn’t check", "Git couldn’t compare this branch.")
        }
    }

    /// Why a merged row stays, as the start of a sentence.
    private var protectionReason: String {
        if worktree.isPrimary { return "The main checkout" }
        if worktree.isLocked { return "Locked" }
        if worktree.isDetached { return "Detached HEAD" }
        if entry?.hasUncheckedFiles == true { return "Some files are marked unchanged in Git" }
        if entry?.hasSubmodules == true { return "It contains a submodule" }
        return "Protected"
    }

    var changesFact: WorktreeCardFact {
        guard hasUncommitted else { return WorktreeCardFact(icon: .pencil, text: "No uncommitted changes", tone: .muted) }
        return WorktreeCardFact(icon: .pencil,
                                text: changes > 0 ? WorktreeWording.plural(changes, "uncommitted change") : "Uncommitted changes",
                                tone: .warn)
    }

    var mergeFact: WorktreeCardFact {
        func muted(_ text: String) -> WorktreeCardFact { WorktreeCardFact(icon: .branch, text: text, tone: .muted) }
        if isTarget { return muted("Merge target") }
        guard let entry else { return muted(isChecking ? "Checking merge status…" : "Couldn’t check merge status") }
        switch entry.mergeStatus {
        case .merged: return WorktreeCardFact(icon: .branch, text: WorktreeWording.mergedText(entry), tone: .normal)
        case .notConfirmed:
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

    static func missingReason(_ entry: CleanupEntry?) -> String {
        entry?.problem?.contains(".git link is missing") == true
            ? "Its .git link is missing; files left in the folder are kept."
            : "The folder was moved or deleted outside git."
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
    let facts: [WorktreeCardFact]
    let explanation: String
    /// Show the "Also delete the branch" checkbox: only for a merged row that is
    /// safe to remove, where the branch's work is already in a target.
    let offersBranchDeletion: Bool
    /// Removal is never forced, so Git refuses a folder with uncommitted work or a
    /// submodule. The prompt says why and does not offer Remove.
    let canRemove: Bool

    private init(title: String, facts: [WorktreeCardFact], explanation: String) {
        self.title = title
        self.facts = facts
        self.explanation = explanation
        offersBranchDeletion = false
        canRemove = true
    }

    /// The missing-row trash: `git worktree prune` forgets every missing worktree at
    /// once, so the prompt says so instead of naming one row.
    static func prune(missingCount: Int) -> WorktreeRemovalPrompt {
        WorktreeRemovalPrompt(
            title: "Forget missing worktrees?",
            facts: [WorktreeCardFact(icon: .missing, text: WorktreeWording.plural(missingCount, "missing worktree"), tone: .muted)],
            explanation: "Clears Git’s leftover records of every missing worktree, not only this one. "
                + "Nothing on disk changes and branches are kept.")
    }

    init(worktree: Worktree, status: WorktreeStatus, merge: WorktreeMergeEntry?, isAgentActive: Bool) {
        let name = worktree.branch ?? worktree.name
        if status.mark == .missing {
            title = "Forget “\(name)”?"
            facts = [WorktreeCardFact(icon: .missing, text: WorktreeWording.missingReason(merge?.entry), tone: .muted)]
            explanation = "Git still has a record of this worktree. Removing it only clears that record; "
                + "nothing on disk changes and the branch is kept."
            offersBranchDeletion = false
            canRemove = true
            return
        }
        title = "Remove “\(name)”?"
        let entry = merge?.entry
        var facts: [WorktreeCardFact] = []
        switch entry?.mergeStatus {
        case .merged?: facts.append(WorktreeCardFact(icon: .merge, text: WorktreeWording.mergedText(entry), tone: .normal))
        case .notConfirmed?: facts.append(WorktreeCardFact(icon: .branch, text: "Not merged yet", tone: .muted))
        default: facts.append(WorktreeCardFact(icon: .branch, text: "Couldn’t check if merged", tone: .muted))
        }
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
        if isAgentActive {
            facts.append(WorktreeCardFact(icon: .warning, text: "An agent is active in this worktree", tone: .warn))
        }
        // A clean removal takes ignored files with the folder.
        if !hasUncommitted, !hasSubmodules, let entry, let ignored = WorktreeWording.ignoredFact([entry]) {
            facts.append(ignored)
        }
        self.facts = facts
        let safe = entry?.mergeStatus == .merged && !hasUncommitted
        canRemove = !hasUncommitted && !hasSubmodules
        if hasUncommitted {
            explanation = "Git only removes a worktree with nothing uncommitted. The branch is kept."
        } else if hasSubmodules {
            explanation = "Git won’t remove a worktree that contains a submodule without forcing it, and Teebe never forces."
        } else {
            explanation = safe ? "The worktree folder is deleted. Its commits are already merged."
                : "The worktree folder is deleted. The branch is kept."
        }
        offersBranchDeletion = safe && canRemove && status.showsTrash
    }
}
