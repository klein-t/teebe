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

/// What stands between a worktree and its removal, worked out once per row. The
/// ✓, the Safe to delete group, the row trash, the group bin and the removal
/// prompt all read it, so none of them offers a row another would refuse.
/// Removal still re-checks everything as it runs.
struct RemovalEligibility: Equatable {
    enum Blocker: Equatable {
        case uncommitted
        case submodule
        /// Something protects it, as the start of a sentence: "Locked", "Rebase in
        /// progress", "The main checkout".
        case protected(String)
        /// Something is working in the folder, as the prompt says it.
        case activity(String)
        /// No result yet, or the one in hand is known to be out of date.
        case checking
        /// The folder couldn't be inspected, so nothing is known about its files.
        case notInspected
    }

    /// Most important first; empty when the folder can be removed now.
    let blockers: [Blocker]
    /// Its commits are in a merge target and it is not one, so its local branch
    /// may be deleted with the folder.
    let isMerged: Bool

    /// Remove the folder and keep the branch: also true for a clean, unmerged row.
    var canRemoveFolder: Bool { blockers.isEmpty }
    /// Safe to delete: the folder, and optionally its merged branch.
    var isSafeToDelete: Bool { blockers.isEmpty && isMerged }
    var canDeleteBranch: Bool { isSafeToDelete }
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
    /// Pinned rows are listed above the groups instead.
    let group: WorktreeGroup
    /// The primary checkout and merge-target checkouts sit above the groups.
    let isPinned: Bool
    let trashAction: TrashAction?
    let removal: RemovalEligibility
    let card: WorktreeCard
    /// Uncommitted files (live count when known).
    let changeCount: Int
    let remote: RemoteSync
    /// The merge result is known to be out of date: the checkout committed since
    /// it was scanned. No ✓ and no trash until it is checked again.
    let isRechecking: Bool
    /// What is working in the folder right now, said where removal is confirmed;
    /// nil when nothing is.
    let activityWarning: String?

    var showsTrash: Bool { trashAction != nil }
    var isSafeToDelete: Bool { removal.isSafeToDelete }

    /// The mark the row itself draws. Inside a group the heading already says the
    /// Git state, so a grouped row only keeps an agent orb, the broken link (its
    /// heading can't say that), or the ring of a result being rechecked; pinned
    /// rows sit above the groups and keep their mark.
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
        // Safe to delete means removable right now: a merged row something protects
        // (locked, detached, files Git hides, a submodule) is not, nor one whose
        // result is being rechecked or where something is working. Its card says why.
        removal = facts.removal
        group = Self.group(facts, isMergedClean: removal.isSafeToDelete)
        mark = Self.mark(facts, isMergedClean: removal.isSafeToDelete)
        trashAction = removal.isSafeToDelete ? entry.map { .remove($0) } : nil
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

    var removal: RemovalEligibility {
        var blockers: [RemovalEligibility.Blocker] = []
        if hasUncommitted { blockers.append(.uncommitted) }
        // Git itself refuses a submodule, so that is said instead of any protection.
        if entry?.hasSubmodules == true {
            blockers.append(.submodule)
        } else if let protection = WorktreeWording.protection(worktree, entry) {
            blockers.append(.protected(protection))
        }
        if let activityWarning { blockers.append(.activity(activityWarning)) }
        if entry == nil || isRechecking {
            blockers.append(.checking)
        } else if entry?.isInspected != true {
            blockers.append(.notInspected)
        }
        return RemovalEligibility(blockers: blockers, isMerged: entry?.canRemove(includingIgnored: true) == true)
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
            return isRemovable ? ("Safe to delete", "Its committed changes are merged. You can remove it.")
                : ("Merged", WorktreeWording.reason(worktree, entry) ?? "Teebe won’t remove it right now.")
        case .notMerged: return notMergedHeadline
        }
    }

    /// No ✓, and the one specific reason why: still checking, couldn't check,
    /// an operation or a protection, then what the merge check found.
    private var notMergedHeadline: (String, String) {
        if isRechecking || (entry == nil && isChecking) {
            let targets = targetNames.isEmpty ? "its merge targets" : WorktreeWording.list(targetNames, joiner: "or")
            return ("Checking…", "Looking for this branch in \(targets).")
        }
        guard let entry, entry.isInspected else { return ("Couldn’t check", "Couldn’t check this worktree.") }
        let title = switch entry.mergeStatus {
        case .merged: "Merged"
        case .notConfirmed: WorktreeGroup.notMergedTitle
        case .unknown: "Couldn’t check"
        }
        if let reason = WorktreeWording.reason(worktree, entry) { return (title, reason) }
        switch entry.mergeStatus {
        case .merged: return (title, "Teebe won’t remove it right now.")
        case .notConfirmed:
            if isMergeUnconfirmed { return (title, "Merge not confirmed.") }
            if entry.hasNoCommits { return (title, "No commits of its own yet.") }
            let targets = targetNames.isEmpty ? "merged" : "in " + WorktreeWording.list(targetNames, joiner: "or")
            return (title, "Its commits aren’t \(targets) yet.")
        case .unknown:
            // The files were checked; only the comparison with the targets failed.
            return (title, targetNames.isEmpty ? "No branch to compare it against." : "Couldn’t check if it’s merged.")
        }
    }

    /// Not shown as merged, but it may well be: a branch that only looks unstarted
    /// (nothing proves it has no commits of its own), or one whose remote branch
    /// was deleted, as happens once a pull request is merged.
    private var isMergeUnconfirmed: Bool {
        guard let entry, entry.mergeStatus == .notConfirmed else { return false }
        return entry.hasNoCommits ? !entry.hasNoCommitsConfirmed : info.remote == .remoteDeleted
    }

    /// Clean is a fact only once the folder was fully inspected: a check that
    /// failed or hasn't finished says so rather than reading as clean.
    var changesFact: WorktreeCardFact {
        guard hasUncommitted else {
            let text = if entry?.isInspected == true { "No uncommitted changes" }
                else if entry == nil && isChecking { "Checking for changes…" }
                else { "Couldn’t check for changes" }
            return WorktreeCardFact(icon: .pencil, text: text, tone: .muted)
        }
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
            if isMergeUnconfirmed { return muted("Merge not confirmed") }
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
        if let operation = entry?.operation { return Self.inProgress(operation) }
        if worktree.isLocked { return "Locked" }
        if entry?.isBroken == true { return "Its .git link is missing" }
        if worktree.isDetached { return detachedHead }
        if entry?.hasUncheckedFiles == true { return "Some files are marked unchanged in Git" }
        if entry?.hasSubmodules == true { return "It contains a submodule" }
        return nil
    }

    /// Why the card's row can't be removed, as its one sentence: "Rebase in
    /// progress.", "Locked, so Teebe won’t remove it.", "Detached HEAD, not on a
    /// branch."; nil when nothing protects it.
    static func reason(_ worktree: Worktree, _ entry: CleanupEntry?) -> String? {
        guard let protection = protection(worktree, entry) else { return nil }
        if let operation = entry?.operation { return inProgress(operation) + "." }
        if protection == detachedHead { return "Detached HEAD, not on a branch." }
        return protection + ", so Teebe won’t remove it."
    }

    private static let detachedHead = "Detached HEAD"

    /// "Rebase in progress": what a checkout is in the middle of.
    static func inProgress(_ operation: GitOperation) -> String {
        switch operation {
        case .rebase: "Rebase in progress"
        case .applyingPatches: "Patch apply in progress"
        case .merge: "Merge in progress"
        case .cherryPick: "Cherry-pick in progress"
        case .revert: "Revert in progress"
        case .bisect: "Bisect in progress"
        }
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

    /// Removing one existing worktree folder, as the row's own eligibility allows.
    init(worktree: Worktree, status: WorktreeStatus, merge: WorktreeMergeEntry?) {
        title = "Remove “\(worktree.branch ?? worktree.name)”?"
        item = WorktreeRemovalItem(name: worktree.branch ?? worktree.name, path: worktree.path,
                                   isMerged: status.mark == .merged)
        let entry = merge?.entry
        let removal = status.removal
        let blockers = removal.blockers
        let isChecking = blockers.contains(.checking)
        var facts = [Self.mergeFact(entry, isChecking: isChecking)]
        if blockers.contains(.uncommitted) {
            let changes = status.changeCount > 0 ? WorktreeWording.plural(status.changeCount, "uncommitted change")
                : "Uncommitted changes"
            facts.append(WorktreeCardFact(icon: .pencil, text: changes + ": commit or discard them first", tone: .warn))
        } else {
            let text = blockers.contains(.notInspected) ? "Couldn’t check for changes"
                : isChecking && entry?.isInspected != true ? "Checking for changes…" : "Nothing uncommitted"
            facts.append(WorktreeCardFact(icon: .pencil, text: text, tone: .muted))
        }
        for blocker in blockers {
            switch blocker {
            case .submodule:
                facts.append(WorktreeCardFact(icon: .warning, text: "Contains a submodule: Git won’t remove it", tone: .warn))
            case .protected(let protection):
                facts.append(WorktreeCardFact(icon: .warning, text: protection + ", so Teebe won’t remove it", tone: .warn))
            case .activity(let activity):
                facts.append(WorktreeCardFact(icon: .warning, text: activity, tone: .warn))
            case .uncommitted, .checking, .notInspected: break
            }
        }
        // A clean removal takes ignored files with the folder.
        if removal.canRemoveFolder, let entry, let ignored = WorktreeWording.ignoredFact([entry]) {
            facts.append(ignored)
        }
        self.facts = facts
        canRemove = removal.canRemoveFolder
        explanation = switch blockers.first {
        case .uncommitted?: "Git only removes a worktree with nothing uncommitted. The branch is kept."
        case .submodule?: "Git won’t remove a worktree that contains a submodule without forcing it, and Teebe never forces."
        case .protected?: "Teebe only removes a worktree Git can fully check and nothing protects."
        case .activity?: "Teebe won’t remove a worktree while something is working in it. Try again when it’s done."
        case .checking?: "Teebe is still checking this worktree. Try again in a moment."
        case .notInspected?: "Teebe couldn’t check this worktree, so it won’t remove it. Refresh and try again."
        case nil: removal.isSafeToDelete ? "The worktree folder is deleted. Its commits are already merged."
            : "The worktree folder is deleted. The branch and its commits are kept."
        }
        offersBranchDeletion = removal.canDeleteBranch
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
