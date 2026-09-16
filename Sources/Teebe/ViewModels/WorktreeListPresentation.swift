import Foundation
import TeebeCore

/// The one vocabulary for a checkout's state: group headers and row tooltips read
/// these names, so nothing is called two different things. Case order is display
/// order. Ignored files remain a detail, not a merge state. The raw values are
/// persisted (collapsed groups per repo), so they outlive any rename of the titles.
enum WorktreeGroup: String, CaseIterable, Identifiable {
    case merged, localChanges, notMerged, broken
    var id: String { rawValue }
    var title: String {
        switch self {
        case .merged: "Merged"
        // The names say what is in the folder, not a verdict: "Uncommitted changes"
        // is files you have not committed, "Unmerged commits" is commits the
        // comparison branch does not have. No tooltip needed to tell them apart.
        case .localChanges: "Uncommitted changes"
        case .notMerged: "Unmerged commits"
        case .broken: "Broken"
        }
    }
    /// A status Git could not confirm — a skipped file, a submodule, no result at
    /// all — is not merged as far as anything here is concerned. The row's tooltip
    /// carries the reason; a group of its own only asked the user to judge it.
    static func classify(_ status: WorktreeMergeEntry?) -> WorktreeGroup {
        guard let entry = status?.entry else { return .notMerged }
        if entry.isBroken { return .broken }
        if entry.hasLocalChanges { return .localChanges }
        if entry.hasUncheckedFiles || entry.hasSubmodules { return .notMerged }
        return entry.mergeStatus == .merged ? .merged : .notMerged
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
    /// No comparison branch resolved, so every group would be the catch-all one.
    /// The list stays flat and the view asks for a branch once, not per row.
    let needsTarget: Bool

    static let rowHeight: CGFloat = 26
    static let groupHeight: CGFloat = 25
    static let repoHeight: CGFloat = 29
    static let verticalPadding: CGFloat = 8

    init(worktrees: [Worktree], entries: [String: WorktreeMergeEntry], grouped: Bool,
         collapsed: Set<WorktreeGroup>, hasRepository: Bool, needsTarget: Bool = false) {
        self.needsTarget = needsTarget
        let isGrouped = grouped && !needsTarget
        pinned = isGrouped ? worktrees.filter { $0.isPrimary || entries[$0.path]?.entry.isTarget == true } : worktrees
        let pinnedPaths = Set(pinned.map(\.path))
        let remaining = isGrouped ? worktrees.filter { !pinnedPaths.contains($0.path) } : []
        groups = WorktreeGroup.allCases.compactMap { kind in
            let rows = remaining.filter { WorktreeGroup.classify(entries[$0.path]) == kind }
                .sorted { Self.sortKey($0).localizedStandardCompare(Self.sortKey($1)) == .orderedAscending }
            return rows.isEmpty ? nil : Group(kind: kind, worktrees: rows)
        }
        visibleWorktrees = pinned + groups.filter { !collapsed.contains($0.kind) }.flatMap(\.worktrees)
        naturalHeight = (hasRepository ? Self.repoHeight : 0) + Self.verticalPadding
            + CGFloat(max(visibleWorktrees.count, worktrees.isEmpty ? 1 : 0)) * Self.rowHeight
            + CGFloat(groups.count) * Self.groupHeight
    }

    /// Rows read as a list of branches, so that is what they sort by.
    private static func sortKey(_ worktree: Worktree) -> String { worktree.branch ?? worktree.name }
}

extension AppModel {
    func worktreeList(collapsed: Set<WorktreeGroup>) -> WorktreeListPresentation {
        let entries = selector.worktrees.compactMap { tree -> WorktreeMergeEntry? in
            let local = selector.worktree.worktreePath == tree.path ? selector.worktree.status : nil
            return mergeStatus.entry(for: tree.path, localStatus: local,
                                     localChangeCount: selector.info(for: tree).changeCount)
        }
        return WorktreeListPresentation(worktrees: selector.worktrees,
                                       entries: Dictionary(uniqueKeysWithValues: entries.map { ($0.entry.id, $0) }),
                                       grouped: showMergeStatus, collapsed: collapsed,
                                       hasRepository: selector.selectedRepo != nil,
                                       needsTarget: mergeStatus.snapshot.map { $0.target == nil } ?? false)
    }
}
