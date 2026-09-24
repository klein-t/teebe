import Foundation
import TeebeCore

/// The one mark a worktree row shows. Case order is precedence: the first that
/// applies wins. Agent activity and uncommitted work outrank what Git says about
/// merging, because they are what needs attention now.
enum WorktreeMark: Equatable {
    /// An agent is mid-turn, or files are changing with no agent (the `LiveDot` rule).
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
/// icloud.slash, lock, questionmark.folder, eye.slash, exclamationmark.triangle).
enum WorktreeCardIcon: Equatable {
    case pencil, merge, branch, cloud, cloudOff, lock, missing, ignoredFiles, warning
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
    ///   - defaultBranch: the automatic default's short name, e.g. "main".
    ///   - isChecking: a scan is running (only matters while `merge` is nil).
    init(worktree: Worktree, merge: WorktreeMergeEntry?, info: SelectorModel.WorktreeInfo,
         targetNames: [String], defaultBranch: String?, isChecking: Bool) {
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
        card = facts.card(mark: mark, isRemovable: trashAction != nil, defaultBranch: defaultBranch)
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

    func card(mark: WorktreeMark, isRemovable: Bool, defaultBranch: String?) -> WorktreeCard {
        let remote = WorktreeWording.remoteFact(info.remote)
        switch mark {
        case .none:
            let isDefault = worktree.branch != nil && worktree.branch == defaultBranch
            return WorktreeCard(title: worktree.branch ?? worktree.name,
                                subtitle: (isDefault ? "Default branch." : "Integration branch.")
                                    + " Other worktrees are checked against it.",
                                facts: [remote] + details())
        case .working, .waiting:
            let (title, subtitle) = mark == .waiting
                ? ("Agent waiting for you", "The session finished its turn.")
                : info.agentState == .working
                    ? ("Agent working", "A Claude Code session is running here.")
                    : ("Files changing", "Something is writing to this folder right now.")
            return WorktreeCard(title: title, subtitle: subtitle,
                                facts: [changesFact, isTarget ? nil : mergeFact, remote].compactMap { $0 } + details())
        case .uncommitted:
            return WorktreeCard(
                title: changes > 0 ? WorktreeWording.plural(changes, "uncommitted change") : "Uncommitted changes",
                subtitle: entry?.mergeStatus == .merged ? "Commit or discard them before removing." : "Not yet committed.",
                facts: [isTarget ? nil : mergeFact, remote].compactMap { $0 } + details())
        case .missing:
            return WorktreeCard(title: "Worktree missing",
                                subtitle: WorktreeWording.missingReason(entry) + " Git still lists it; remove to clean up the record.",
                                facts: [])
        case .merged:
            return mergedCard(isRemovable: isRemovable, remote: remote)
        case .notMerged:
            return notMergedCard(remote: remote)
        }
    }

    private func mergedCard(isRemovable: Bool, remote: WorktreeCardFact) -> WorktreeCard {
        let merged = WorktreeWording.mergedText(entry)
        guard !isRemovable else {
            return WorktreeCard(title: "Safe to delete", subtitle: merged + ". Nothing uncommitted.",
                                facts: [remote] + details())
        }
        let reason: String
        var said = ""
        if worktree.isPrimary {
            reason = "This is the main checkout, so Teebe won't remove it."
        } else if worktree.isLocked {
            reason = "It's locked, so Teebe won't remove it."
            said = "Locked"
        } else if worktree.isDetached {
            reason = "Its HEAD is detached, so Teebe won't remove it."
            said = "Detached HEAD"
        } else {
            reason = "Teebe won't remove it."
        }
        return WorktreeCard(title: "Merged", subtitle: merged + ". " + reason,
                            facts: [remote] + details().filter { $0.text != said })
    }

    private func notMergedCard(remote: WorktreeCardFact) -> WorktreeCard {
        let facts = [remote] + details()
        guard let entry else {
            guard isChecking else {
                return WorktreeCard(title: "Couldn’t check", subtitle: "Git couldn’t compare this branch.", facts: facts)
            }
            let subtitle = targetNames.isEmpty ? "Comparing this branch with its merge targets."
                : "Looking for this branch in \(WorktreeWording.list(targetNames, joiner: "or"))."
            return WorktreeCard(title: "Checking…", subtitle: subtitle, facts: facts)
        }
        switch entry.mergeStatus {
        case .merged:
            // Merged commits, but Git could be hiding local work: no ✓.
            let (why, said) = entry.hasUncheckedFiles
                ? ("some files are marked unchanged in Git.", "Some files are marked unchanged in Git")
                : ("it contains a submodule.", "Contains a submodule")
            return WorktreeCard(title: "Couldn’t confirm it’s safe",
                                subtitle: WorktreeWording.mergedText(entry) + ", but " + why,
                                facts: [remote] + details().filter { $0.text != said })
        case .notConfirmed:
            let subtitle = targetNames.isEmpty ? "Committed work not merged yet."
                : "Committed work not in \(WorktreeWording.list(targetNames, joiner: "or"))."
            return WorktreeCard(title: "Not merged yet", subtitle: subtitle, facts: facts)
        case .unknown:
            let subtitle = entry.problem == "No branch to compare against"
                ? "No default or integration branch to compare against."
                : "Git couldn’t compare this branch."
            return WorktreeCard(title: "Couldn’t check", subtitle: subtitle, facts: facts)
        }
    }

    var changesFact: WorktreeCardFact? {
        guard hasUncommitted else { return nil }
        return WorktreeCardFact(icon: .pencil,
                                text: changes > 0 ? WorktreeWording.plural(changes, "uncommitted change") : "Uncommitted changes",
                                tone: .warn)
    }

    var mergeFact: WorktreeCardFact {
        guard let entry else {
            return WorktreeCardFact(icon: .branch, text: isChecking ? "Checking if merged…" : "Couldn’t check if merged",
                                    tone: .muted)
        }
        switch entry.mergeStatus {
        case .merged: return WorktreeCardFact(icon: .merge, text: WorktreeWording.mergedText(entry), tone: .normal)
        case .notConfirmed: return WorktreeCardFact(icon: .branch, text: "Not merged yet", tone: .muted)
        case .unknown: return WorktreeCardFact(icon: .branch, text: "Couldn’t check if merged", tone: .muted)
        }
    }

    /// Secondary detail worth knowing on hover, shortest first-glance wording.
    func details() -> [WorktreeCardFact] {
        var facts: [WorktreeCardFact] = []
        if let entry, !entry.isBroken {
            if entry.hasUncheckedFiles {
                facts.append(WorktreeCardFact(icon: .warning, text: "Some files are marked unchanged in Git", tone: .warn))
            }
            if entry.hasSubmodules {
                facts.append(WorktreeCardFact(icon: .warning, text: "Contains a submodule", tone: .muted))
            }
            if entry.hasIgnoredFiles {
                facts.append(WorktreeCardFact(icon: .ignoredFiles, text: WorktreeWording.ignoredText(entry), tone: .muted))
            }
        }
        if worktree.isLocked { facts.append(WorktreeCardFact(icon: .lock, text: "Locked", tone: .muted)) }
        if worktree.isDetached { facts.append(WorktreeCardFact(icon: .branch, text: "Detached HEAD", tone: .muted)) }
        return facts
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
        case .remoteDeleted: return WorktreeCardFact(icon: .cloudOff, text: "Remote branch deleted", tone: .muted)
        case .notOnRemote: return WorktreeCardFact(icon: .cloudOff, text: "Not on remote", tone: .muted)
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

    static func ignoredText(_ entry: CleanupEntry) -> String {
        let examples = entry.ignoredPaths.prefix(2).map { path in
            path.count > 36 ? String(path.prefix(16)) + "…" + String(path.suffix(16)) : path
        }.joined(separator: ", ")
        guard !examples.isEmpty else { return "Ignored files remain" }
        return "Ignored files remain (" + examples + (entry.ignoredPaths.count > 2 ? ", …" : "") + ")"
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

    init(worktree: Worktree, status: WorktreeStatus, merge: WorktreeMergeEntry?, isAgentActive: Bool) {
        let name = worktree.branch ?? worktree.name
        if status.mark == .missing {
            title = "Forget “\(name)”?"
            facts = [WorktreeCardFact(icon: .missing, text: WorktreeWording.missingReason(merge?.entry), tone: .muted)]
            explanation = "Git still has a record of this worktree. Removing it only clears that record; "
                + "nothing on disk changes and the branch is kept."
            offersBranchDeletion = false
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
            facts.append(WorktreeCardFact(icon: .pencil, text: changes + " will be lost", tone: .warn))
        } else {
            facts.append(WorktreeCardFact(icon: .pencil, text: "Nothing uncommitted", tone: .muted))
        }
        if isAgentActive {
            facts.append(WorktreeCardFact(icon: .warning, text: "An agent is active in this worktree", tone: .warn))
        }
        self.facts = facts
        let safe = entry?.mergeStatus == .merged && !hasUncommitted
        explanation = safe ? "The worktree folder is deleted. Its commits are already merged."
            : "The worktree folder is deleted. The branch is kept."
        offersBranchDeletion = safe && status.showsTrash
    }
}
