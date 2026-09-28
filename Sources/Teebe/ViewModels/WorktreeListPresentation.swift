import Foundation
import TeebeCore

/// The groups a checkout's Git state puts it in. Agent activity never moves a row
/// between groups. Case order is display order. The raw values are persisted
/// (collapsed groups per repo), so they outlive any rename of the titles.
enum WorktreeGroup: String, CaseIterable, Identifiable {
    case localChanges, notMerged, merged
    var id: String { rawValue }
    /// The Not merged group's name, also the title of a card in it: one place to rename it.
    static let notMergedTitle = "Not merged"
    var title: String {
        switch self {
        case .localChanges: "Uncommitted changes"
        case .notMerged: Self.notMergedTitle
        case .merged: "Safe to delete"
        }
    }
    /// The header mark's hover card: a summary of the rows, in the row card's
    /// style. The title is the group; the facts count rows, never list them.
    /// `targets` are the branches worktrees are checked against (e.g. ["dev", "main"]).
    func card(statuses: [WorktreeStatus], targets: [String]) -> WorktreeCard {
        let count = statuses.count
        let one = count == 1
        let targetList = targets.isEmpty ? "a merge target" : WorktreeWording.list(targets, joiner: "or")
        let subtitle: String
        let countFact: WorktreeCardFact
        switch self {
        case .localChanges:
            subtitle = "Work in \(one ? "this worktree" : "these worktrees") isn’t committed yet."
            countFact = WorktreeCardFact(icon: .pencil, text: WorktreeWording.plural(count, "worktree") + " with changes", tone: .warn)
        case .notMerged:
            subtitle = "\(one ? "Its" : "Their") work isn’t in \(targetList) yet, or something keeps \(one ? "it" : "them")."
            countFact = WorktreeCardFact(icon: .merge, text: WorktreeWording.plural(count, "worktree") + " not safe to delete",
                                         tone: .muted)
        case .merged:
            subtitle = "\(one ? "Its" : "Their") committed changes are in \(targetList). You can remove \(one ? "it" : "them")."
            countFact = WorktreeCardFact(icon: .merge, text: WorktreeWording.plural(count, "worktree") + " merged",
                                         tone: .positive)
        }
        var facts = [countFact]
        let active = statuses.filter { $0.activityWarning != nil }.count
        if active > 0 {
            facts.append(WorktreeCardFact(icon: .warning, text: "Agent or command active in \(active)", tone: .warn))
        }
        let toPush = statuses.filter { if case let .sameBranch(_, ahead, _) = $0.remote { ahead > 0 } else { false } }.count
        let toPull = statuses.filter { if case let .sameBranch(_, _, behind) = $0.remote { behind > 0 } else { false } }.count
        if toPush > 0 || toPull > 0 {
            let parts = [toPush > 0 ? "\(toPush) with work to push" : nil,
                         toPull > 0 ? "\(toPull) \(toPush > 0 ? "" : "with work ")to pull" : nil].compactMap { $0 }
            facts.append(WorktreeCardFact(icon: .cloud, text: parts.joined(separator: " · "),
                                          tone: toPush > 0 ? .normal : .muted))
        }
        return WorktreeCard(title: title, subtitle: subtitle, facts: facts)
    }
}

/// How rows are ordered, within each group when grouped. The primary checkout
/// (and, grouped, the base-branch checkouts) stay on top whatever the order. The
/// raw values are persisted.
enum WorktreeSortOrder: String, CaseIterable, Identifiable {
    /// What each row shows first: agent working, agent waiting, uncommitted
    /// changes, not merged, then safe to delete.
    case status
    /// By the name the row shows: its branch, or its folder for a detached HEAD.
    case name
    /// By folder name, the order the list has always had.
    case folder

    static let menuTitle = "Sort by"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .status: "Status"
        case .name: "Name"
        case .folder: "Folder"
        }
    }

    /// Whether `lhs` comes before `rhs`. Ties fall to the name, then the path, so
    /// the order never depends on what Git listed first.
    func areInOrder(_ lhs: Worktree, _ rhs: Worktree, statuses: [String: WorktreeStatus]) -> Bool {
        switch self {
        case .status:
            let left = Self.rank(statuses[lhs.path]), right = Self.rank(statuses[rhs.path])
            if left != right { return left < right }
        case .name: break
        case .folder:
            // The comparison the list has always used, so the default keeps its order.
            let order = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if order != .orderedSame { return order == .orderedAscending }
        }
        for key in [Self.label, \.path] as [(Worktree) -> String] {
            let order = key(lhs).localizedStandardCompare(key(rhs))
            if order != .orderedSame { return order == .orderedAscending }
        }
        return false
    }

    private static func label(_ worktree: Worktree) -> String { worktree.branch ?? worktree.name }

    /// By the mark the row shows; a row with no result yet sorts with Not merged.
    private static func rank(_ status: WorktreeStatus?) -> Int {
        switch status?.mark {
        case .working?: 0
        case .waiting?: 1
        case .uncommitted?: 2
        case .merged?: 4
        default: 3
        }
    }
}

struct WorktreeListPresentation {
    struct Group: Identifiable {
        let kind: WorktreeGroup
        let worktrees: [Worktree]
        var id: WorktreeGroup { kind }
    }
    let pinned: [Worktree]
    let groups: [Group]
    let visibleWorktrees: [Worktree]
    let naturalHeight: CGFloat

    static let rowHeight: CGFloat = 26
    static let groupHeight: CGFloat = 25
    static let repoHeight: CGFloat = 29
    static let verticalPadding: CGFloat = 8

    /// `statuses` is keyed by worktree path; a worktree without one is not pinned
    /// (unless primary) and falls in Not merged. Flat, every row is listed in
    /// `pinned`, the primary checkout first and the rest in `sort` order.
    init(worktrees: [Worktree], statuses: [String: WorktreeStatus], grouped: Bool,
         collapsed: Set<WorktreeGroup>, hasRepository: Bool, sort: WorktreeSortOrder = .folder) {
        func sorted(_ rows: [Worktree]) -> [Worktree] { rows.sorted { sort.areInOrder($0, $1, statuses: statuses) } }
        pinned = grouped ? worktrees.filter { $0.isPrimary || statuses[$0.path]?.isPinned == true }
            : worktrees.filter(\.isPrimary) + sorted(worktrees.filter { !$0.isPrimary })
        let pinnedPaths = Set(pinned.map(\.path))
        let remaining = grouped ? worktrees.filter { !pinnedPaths.contains($0.path) } : []
        groups = WorktreeGroup.allCases.compactMap { kind in
            let rows = sorted(remaining.filter { (statuses[$0.path]?.group ?? .notMerged) == kind })
            return rows.isEmpty ? nil : Group(kind: kind, worktrees: rows)
        }
        visibleWorktrees = pinned + groups.filter { !collapsed.contains($0.kind) }.flatMap(\.worktrees)
        naturalHeight = (hasRepository ? Self.repoHeight : 0) + Self.verticalPadding
            + CGFloat(max(visibleWorktrees.count, worktrees.isEmpty ? 1 : 0)) * Self.rowHeight
            + CGFloat(groups.count) * Self.groupHeight
    }
}

extension AppModel {
    /// Everything one row shows: mark, hover card, group, trash. The single source
    /// both the list grouping and the row read, so they never disagree.
    func worktreeStatus(for worktree: Worktree) -> WorktreeStatus {
        let info = selector.info(for: worktree)
        let snapshot = mergeStatus.snapshot
        return WorktreeStatus(
            worktree: worktree, merge: mergeEntry(for: worktree, info: info),
            info: info, targetNames: snapshot?.targetNames ?? [], isChecking: mergeStatus.isChecking)
    }

    /// What the removal sheet says for this row, from the same inputs as its mark.
    func removalPrompt(for worktree: Worktree) -> WorktreeRemovalPrompt {
        WorktreeRemovalPrompt(worktree: worktree, status: worktreeStatus(for: worktree),
                              merge: mergeEntry(for: worktree, info: selector.info(for: worktree)))
    }

    private func mergeEntry(for worktree: Worktree, info: SelectorModel.WorktreeInfo) -> WorktreeMergeEntry? {
        let local = selector.worktree.statusPath == worktree.path ? selector.worktree.status : nil
        return mergeStatus.entry(for: worktree.path, localStatus: local, localChangeCount: info.hasStatus ? info.changeCount : nil)
    }

    /// The group header's hover card, from the same statuses its rows show.
    func groupCard(for group: WorktreeListPresentation.Group) -> WorktreeCard {
        group.kind.card(statuses: group.worktrees.map(worktreeStatus(for:)),
                        targets: mergeStatus.snapshot?.targetNames ?? [])
    }

    func worktreeList(collapsed: Set<WorktreeGroup>) -> WorktreeListPresentation {
        let statuses = Dictionary(selector.worktrees.map { ($0.path, worktreeStatus(for: $0)) },
                                  uniquingKeysWith: { first, _ in first })
        return WorktreeListPresentation(worktrees: selector.worktrees, statuses: statuses,
                                       grouped: groupWorktreesByMergeStatus, collapsed: collapsed,
                                       hasRepository: selector.selectedRepo != nil, sort: worktreeSortOrder)
    }

    /// What confirming "Remove Worktree…" on this row will do, captured when the
    /// sheet opens and re-checked in full when it runs: remove the folder as it
    /// was last checked. nil while there is no current result to act on.
    func removalAction(for worktree: Worktree) -> WorktreeStatus.TrashAction? {
        guard let merge = mergeEntry(for: worktree, info: selector.info(for: worktree)) else { return nil }
        return worktreeStatus(for: worktree).isRechecking ? nil : .remove(merge.entry)
    }
}
