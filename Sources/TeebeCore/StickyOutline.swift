import Foundation

/// The folders pinned at the top of a scrolled tree ("sticky scroll"): the open
/// folders that contain the first visible row, outermost first.
public struct StickyStack: Equatable, Sendable {
    /// Row indices of the pinned folders, outermost first. Level `k` sits `k` rows
    /// below the top of the viewport.
    public var rows: [Int]
    /// How far (≤ 0) the innermost pinned row is pushed up, because its folder's
    /// contents end above the bottom of its slot.
    public var pushOffset: Double

    public init(rows: [Int], pushOffset: Double) {
        self.rows = rows
        self.pushOffset = pushOffset
    }

    public static let empty = StickyStack(rows: [], pushOffset: 0)

    /// The height the stack covers at the top of the viewport.
    public func height(rowHeight: Double) -> Double {
        rows.isEmpty ? 0 : Double(rows.count) * rowHeight + pushOffset
    }
}

/// The parent/extent structure of a flattened tree of equal-height rows, from each
/// row's depth. Built once per change to the rows, so working out the pinned
/// folders for a scroll offset costs a few steps per level, not a pass over the rows.
public struct StickyOutline: Equatable, Sendable {
    public let depths: [Int]
    /// The nearest earlier row one level up (−1 at the top level).
    private let parents: [Int]
    /// The last row inside each row's folder (the row itself when it has no children).
    private let ends: [Int]

    public init(depths: [Int]) {
        self.depths = depths
        var parents = [Int](repeating: -1, count: depths.count)
        var ends = Array(depths.indices)
        var open: [Int] = []   // the chain of folders the current row is inside
        for (index, depth) in depths.enumerated() {
            while let last = open.last, depths[last] >= depth {
                open.removeLast()
            }
            parents[index] = open.last ?? -1
            for ancestor in open { ends[ancestor] = index }
            open.append(index)
        }
        self.parents = parents
        self.ends = ends
    }

    /// The folders pinned when the content is scrolled `scrollOffset` points down.
    /// Rows are `rowHeight` tall and start `topInset` below the top of the content.
    /// A folder is pinned once its own row scrolls above its slot and while some of
    /// its contents are still below the slot; when the contents run out, the row is
    /// pushed up and nothing deeper is pinned. At most `maxLevels` folders.
    public func stack(scrollOffset: Double, rowHeight: Double, topInset: Double, maxLevels: Int) -> StickyStack {
        guard rowHeight > 0, !depths.isEmpty else { return .empty }
        var rows: [Int] = []
        for level in 0..<max(0, maxLevels) {
            let line = scrollOffset + Double(level) * rowHeight
            let position = ((line - topInset) / rowHeight).rounded(.down)
            guard position >= 0, position < Double(depths.count) else { break }
            // The row under the slot. Past the pinned folder's contents its depth is
            // at most the folder's, which ends the stack here.
            var candidate = Int(position)
            guard depths[candidate] >= level else { break }
            while depths[candidate] > level, parents[candidate] >= 0 { candidate = parents[candidate] }
            guard depths[candidate] == level else { break }
            let top = topInset + Double(candidate) * rowHeight
            guard top < line, ends[candidate] > candidate else { break }
            rows.append(candidate)
            let contentBottom = topInset + Double(ends[candidate] + 1) * rowHeight
            let slotBottom = line + rowHeight
            if contentBottom < slotBottom {
                return StickyStack(rows: rows, pushOffset: contentBottom - slotBottom)
            }
        }
        return StickyStack(rows: rows, pushOffset: 0)
    }

    /// When `row` is hidden under the pinned folders or above the viewport, the row
    /// to scroll to the top so `row` lands just below its (capped) chain of folders.
    /// `nil` when it is already clear of the stack (below the viewport is a plain
    /// scroll's job).
    public func revealAnchor(for row: Int, scrollOffset: Double, rowHeight: Double,
                             topInset: Double, maxLevels: Int) -> Int? {
        guard depths.indices.contains(row) else { return nil }
        let pinned = stack(scrollOffset: scrollOffset, rowHeight: rowHeight, topInset: topInset, maxLevels: maxLevels)
        let top = topInset + Double(row) * rowHeight
        guard top < scrollOffset + pinned.height(rowHeight: rowHeight) else { return nil }
        return row - min(depths[row], max(0, maxLevels))
    }

    /// How many folders may be pinned in a viewport this tall: up to four, and never
    /// more than 40% of it, so the stack can't take over a short list.
    public static func levelLimit(viewportHeight: Double, rowHeight: Double) -> Int {
        guard rowHeight > 0, viewportHeight > 0 else { return 0 }
        return min(4, Int((viewportHeight * 0.4 / rowHeight).rounded(.down)))
    }
}
