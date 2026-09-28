import Foundation
import TeebeCore

/// The groups a checkout's Git state puts it in. Agent activity never moves a row
/// between groups. Case order is display order. The raw values are persisted
/// (collapsed groups per repo), so they outlive any rename of the titles.
enum WorktreeGroup: String, CaseIterable, Identifiable {
    case localChanges, notMerged, merged
    var id: String { rawValue }
    var title: String {
        switch self {
        case .localChanges: "Uncommitted changes"
        case .notMerged: "Not merged"
        case .merged: "Safe to delete"
        }
    }
    /// The header tooltip: what put a checkout in this group, naming the branches
    /// worktrees are checked against (e.g. ["dev", "main"]).
    func explanation(targets: [String]) -> String {
        let targetList = targets.isEmpty ? "a merge target" : WorktreeWording.list(targets, joiner: "or")
        switch self {
        case .localChanges: return "Edited or new files in the folder that are not committed yet."
        case .notMerged:
            return "Committed work not found in \(targetList) yet, merged but kept for a reason the row's card gives, "
                + "or Git couldn't check."
        case .merged: return "Merged into \(targetList) with nothing uncommitted. Removing the folder loses no work."
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
    /// (unless primary) and falls in Not merged.
    init(worktrees: [Worktree], statuses: [String: WorktreeStatus], grouped: Bool,
         collapsed: Set<WorktreeGroup>, hasRepository: Bool) {
        pinned = grouped ? worktrees.filter { $0.isPrimary || statuses[$0.path]?.isPinned == true } : worktrees
        let pinnedPaths = Set(pinned.map(\.path))
        let remaining = grouped ? worktrees.filter { !pinnedPaths.contains($0.path) } : []
        groups = WorktreeGroup.allCases.compactMap { kind in
            let rows = remaining.filter { (statuses[$0.path]?.group ?? .notMerged) == kind }
                .sorted { Self.sortKey($0).localizedStandardCompare(Self.sortKey($1)) == .orderedAscending }
            return rows.isEmpty ? nil : Group(kind: kind, worktrees: rows)
        }
        visibleWorktrees = pinned + groups.filter { !collapsed.contains($0.kind) }.flatMap(\.worktrees)
        naturalHeight = (hasRepository ? Self.repoHeight : 0) + Self.verticalPadding
            + CGFloat(max(visibleWorktrees.count, worktrees.isEmpty ? 1 : 0)) * Self.rowHeight
            + CGFloat(groups.count) * Self.groupHeight
    }

    /// Sort worktrees by their displayed label: branch, or folder for detached HEAD.
    private static func sortKey(_ worktree: Worktree) -> String { worktree.branch ?? worktree.name }
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

    func worktreeList(collapsed: Set<WorktreeGroup>) -> WorktreeListPresentation {
        let statuses = Dictionary(selector.worktrees.map { ($0.path, worktreeStatus(for: $0)) },
                                  uniquingKeysWith: { first, _ in first })
        return WorktreeListPresentation(worktrees: selector.worktrees, statuses: statuses,
                                       grouped: groupWorktreesByMergeStatus, collapsed: collapsed,
                                       hasRepository: selector.selectedRepo != nil)
    }

    /// What confirming "Remove Worktree…" on this row will do, captured when the
    /// sheet opens and re-checked in full when it runs: remove the folder as it
    /// was last checked. nil while there is no current result to act on.
    func removalAction(for worktree: Worktree) -> WorktreeStatus.TrashAction? {
        guard let merge = mergeEntry(for: worktree, info: selector.info(for: worktree)) else { return nil }
        return worktreeStatus(for: worktree).isRechecking ? nil : .remove(merge.entry)
    }
}
