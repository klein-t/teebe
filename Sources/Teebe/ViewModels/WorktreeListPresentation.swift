import Foundation
import TeebeCore

/// The one vocabulary for a checkout's state: group headers, status popovers and the
/// cleanup sheet all read these names, so nothing is called three different things.
/// Case order is display order. Ignored files remain a detail, not a merge state.
enum WorktreeGroup: String, CaseIterable, Identifiable {
    case merged, localChanges, notMerged, broken, notChecked
    var id: String { rawValue }
    var title: String {
        switch self {
        case .merged: "Merged"
        case .localChanges: "Local changes"
        // Plainly "Not merged": a false negative only keeps a folder, it never
        // deletes one, so hedging the label buys nothing and reads as doubt.
        case .notMerged: "Not merged"
        case .broken: "Broken"
        case .notChecked: "Not checked"
        }
    }
    var symbol: MergeIndicatorPresentation.Symbol {
        switch self {
        case .merged: .merge
        case .localChanges: .edit
        case .notMerged: .branch
        case .broken: .broken
        case .notChecked: .unknown
        }
    }
    static func classify(_ status: WorktreeMergeEntry?) -> WorktreeGroup {
        guard let entry = status?.entry else { return .notChecked }
        if entry.isBroken { return .broken }
        if entry.hasLocalChanges { return .localChanges }
        if entry.hasUncheckedFiles || entry.hasSubmodules { return .notChecked }
        switch entry.mergeStatus {
        case .merged: return .merged
        case .notConfirmed: return .notMerged
        case .unknown: return .notChecked
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

/// Keep the divider and window in agreement, including on a small screen.
enum WorktreeSectionSizing {
    static let defaultHeight: CGFloat = 200
    /// Shortest the pane may be dragged while it still has that many points of rows.
    static let minimumHeight: CGFloat = 80
    static let dividerExtra: CGFloat = 7

    /// The chosen height is a *maximum*: the pane hugs its rows rather than padding
    /// them out with blank material, stays inside the room left on screen, and only
    /// dips below `minimumHeight` when the content itself is shorter than that.
    static func height(preferred: CGFloat?, natural: CGFloat, available: CGFloat) -> CGFloat {
        let wanted = preferred.flatMap { $0.isFinite ? $0 : nil } ?? defaultHeight
        let floor = min(minimumHeight, natural)
        return max(0, min(max(floor, min(wanted, natural)), max(0, available)))
    }
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
