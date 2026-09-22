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

    /// The window has drifted from the height the layout asks for and must be sized
    /// again. AppKit can grow the window on its own (a constraint pass, a restored
    /// frame, a screen change), and SwiftUI clears the maximum height we set on it
    /// after every layout, so nothing else pulls it back. A drag is the one time the
    /// mismatch is intended: the divider holds the window still until it is let go,
    /// and dragging the edge *is* the user choosing a height.
    /// The tolerance is a full point because AppKit rounds the frame it hands back.
    static func needsResize(frameHeight: CGFloat, target: CGFloat,
                            draggingDivider: Bool, liveResizing: Bool) -> Bool {
        guard !draggingDivider, !liveResizing else { return false }
        return abs(frameHeight - target) >= 1
    }

    /// The chosen height is a *maximum*: the pane hugs its rows rather than padding
    /// them out with blank material, stays inside the room left on screen, and only
    /// dips below `minimumHeight` when the content itself is shorter than that.
    func height(preferred: CGFloat?, natural: CGFloat, available: CGFloat) -> CGFloat {
        let wanted = preferred.flatMap { $0.isFinite ? $0 : nil } ?? defaultHeight
        let floor = min(minimumHeight, natural)
        return max(0, min(max(floor, min(wanted, natural)), max(0, available)))
    }
}
