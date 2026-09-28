import CoreGraphics
import Observation
import TeebeCore

/// The open folders the FILES tree pins over its top while it is scrolled (sticky
/// scroll). It holds the tree's shape, rebuilt only when the rows change; which
/// folders are pinned is worked out from it for each scroll position, and a scroll
/// itself changes nothing here that a view observes.
@MainActor @Observable
final class StickyFolders {
    /// Every FILES row is this tall, and the rows start this far below the top of
    /// the scroll content (FileRowsView's padding).
    static let rowHeight: CGFloat = 24
    static let topInset: CGFloat = 2

    private(set) var rows: [WorktreeModel.TreeRow] = []
    private(set) var outline = StickyOutline(depths: [])
    private(set) var viewportHeight: CGFloat = 0
    /// Where the list is scrolled to, for revealing a row; views never read it.
    @ObservationIgnored private var scrollOffset: CGFloat = 0

    private var maxLevels: Int {
        StickyOutline.levelLimit(viewportHeight: viewportHeight, rowHeight: Self.rowHeight)
    }

    func update(rows: [WorktreeModel.TreeRow]) {
        self.rows = rows
        let depths = rows.map(\.depth)
        if depths != outline.depths { outline = StickyOutline(depths: depths) }
    }

    func update(scrollOffset: CGFloat) {
        self.scrollOffset = scrollOffset
    }

    func update(viewportHeight: CGFloat) {
        guard viewportHeight != self.viewportHeight else { return }
        self.viewportHeight = viewportHeight
    }

    /// The pinned folders' rows (outermost first) when the list is scrolled
    /// `scrollOffset` points down, and how far the innermost is pushed up.
    func pinned(at scrollOffset: CGFloat) -> (rows: [WorktreeModel.TreeRow], pushOffset: CGFloat) {
        let stack = outline.stack(scrollOffset: scrollOffset, rowHeight: Self.rowHeight,
                                  topInset: Self.topInset, maxLevels: maxLevels)
        return (stack.rows.map { rows[$0] }, stack.pushOffset)
    }

    /// The row to scroll to the top so `path`'s row shows just below its pinned
    /// folders, when it is hidden under them or above the list; `nil` otherwise.
    func revealAnchor(for path: String) -> String? {
        guard let index = rows.firstIndex(where: { $0.id == path }),
              let anchor = outline.revealAnchor(for: index, scrollOffset: scrollOffset, rowHeight: Self.rowHeight,
                                                topInset: Self.topInset, maxLevels: maxLevels)
        else { return nil }
        return rows[anchor].id
    }
}
