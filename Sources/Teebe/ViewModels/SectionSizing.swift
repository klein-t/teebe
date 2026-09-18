import Foundation

/// Keep a resizable section's divider and the window in agreement, including on a
/// small screen. WORKTREES and CHANGES each drive one of these; the only difference
/// between them is how tall they are without a remembered preference and how short
/// they may be dragged.
struct SectionSizing {
    /// Height used while the section has no remembered preference.
    let defaultHeight: CGFloat
    /// Shortest the pane may be dragged while it still has that many points of rows.
    let minimumHeight: CGFloat
    /// What the drag divider adds below the pane, in the window maths.
    static let dividerExtra: CGFloat = 7

    static let worktrees = SectionSizing(defaultHeight: 200, minimumHeight: 80)
    /// ~6 rows unresized, then scroll: browsing between worktrees with very different
    /// change counts shouldn't lurch the window.
    static let changes = SectionSizing(defaultHeight: 144, minimumHeight: 48)

    /// The chosen height is a *maximum*: the pane hugs its rows rather than padding
    /// them out with blank material, stays inside the room left on screen, and only
    /// dips below `minimumHeight` when the content itself is shorter than that.
    func height(preferred: CGFloat?, natural: CGFloat, available: CGFloat) -> CGFloat {
        let wanted = preferred.flatMap { $0.isFinite ? $0 : nil } ?? defaultHeight
        let floor = min(minimumHeight, natural)
        return max(0, min(max(floor, min(wanted, natural)), max(0, available)))
    }
}
