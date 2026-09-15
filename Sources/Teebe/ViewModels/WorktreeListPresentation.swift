import Foundation
import TeebeCore

/// One group describes each checkout; ignored files remain details, not a merge state.
enum WorktreeGroup: String, CaseIterable, Identifiable {
    case localChanges, merged, unconfirmed, broken, needsReview
    var id: String { rawValue }
    var title: String {
        switch self {
        case .localChanges: "Local changes"
        case .merged: "Merged"
        case .unconfirmed: "Merge unconfirmed"
        case .broken: "Broken worktree"
        case .needsReview: "Needs review"
        }
    }
    var symbol: MergeIndicatorPresentation.Symbol {
        switch self {
        case .localChanges: .edit
        case .merged: .merge
        case .unconfirmed: .branch
        case .broken: .broken
        case .needsReview: .unknown
        }
    }
    static func classify(_ entry: CleanupEntry?) -> WorktreeGroup {
        guard let entry else { return .needsReview }
        if entry.isBroken { return .broken }
        if entry.hasLocalChanges { return .localChanges }
        if entry.hasUncheckedFiles || entry.hasSubmodules { return .needsReview }
        switch entry.mergeStatus {
        case .merged: return .merged
        case .notConfirmed: return .unconfirmed
        case .unknown: return .needsReview
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

    init(worktrees: [Worktree], entries: [String: CleanupEntry], grouped: Bool,
         collapsed: Set<WorktreeGroup>, hasRepository: Bool) {
        pinned = grouped ? worktrees.filter { $0.isPrimary || entries[$0.path]?.isTarget == true } : worktrees
        let pinnedPaths = Set(pinned.map(\.path))
        let remaining = grouped ? worktrees.filter { !pinnedPaths.contains($0.path) } : []
        groups = WorktreeGroup.allCases.compactMap { kind in
            let rows = remaining.filter { WorktreeGroup.classify(entries[$0.path]) == kind }
            return rows.isEmpty ? nil : Group(kind: kind, worktrees: rows)
        }
        visibleWorktrees = pinned + groups.filter { !collapsed.contains($0.kind) }.flatMap(\.worktrees)
        naturalHeight = (hasRepository ? Self.repoHeight : 0) + Self.verticalPadding
            + CGFloat(max(visibleWorktrees.count, worktrees.isEmpty ? 1 : 0)) * Self.rowHeight
            + CGFloat(groups.count) * Self.groupHeight
    }
}

/// Keep the divider and window in agreement, including on a small screen.
enum WorktreeSectionSizing {
    static let defaultHeight: CGFloat = 200
    static let dividerExtra: CGFloat = 7
    static func height(preferred: CGFloat?, natural: CGFloat, available: CGFloat) -> CGFloat {
        let desired = preferred.flatMap { $0.isFinite ? max(80, $0) : nil } ?? min(natural, defaultHeight)
        return max(0, min(desired, max(0, available)))
    }
}

extension AppModel {
    func worktreeList(collapsed: Set<WorktreeGroup>) -> WorktreeListPresentation {
        let entries = selector.worktrees.compactMap { tree -> CleanupEntry? in
            let local = selector.worktree.worktreePath == tree.path ? selector.worktree.status : nil
            return mergeStatus.entry(for: tree.path, localStatus: local)
        }
        return WorktreeListPresentation(worktrees: selector.worktrees,
                                       entries: Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) }),
                                       grouped: showMergeStatus, collapsed: collapsed,
                                       hasRepository: selector.selectedRepo != nil)
    }
}
