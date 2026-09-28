import Testing
@testable import TeebeCore

@Suite("StickyOutline: folders pinned at the top of a scrolled tree")
struct StickyOutlineTests {
    /// .audit/            0
    ///   open/            1
    ///     10 files       2...11
    ///   closed/          12
    ///     2 files        13, 14
    ///   README.md        15
    /// src/               16
    ///   10 files         17...26
    static let depths = [0, 1] + Array(repeating: 2, count: 10) + [1, 2, 2, 1, 0] + Array(repeating: 1, count: 10)
    let outline = StickyOutline(depths: Self.depths)
    let h = 24.0

    func stack(_ offset: Double, inset: Double = 0, levels: Int = 4) -> StickyStack {
        outline.stack(scrollOffset: offset, rowHeight: h, topInset: inset, maxLevels: levels)
    }

    @Test("nothing is pinned at the top of the list")
    func nothingAtTop() {
        #expect(stack(0) == .empty)
        #expect(stack(-30) == .empty, "an overscroll bounce pins nothing")
    }

    @Test("pins the chain of open folders above the first visible row")
    func pinsAncestorChain() {
        #expect(stack(10) == StickyStack(rows: [0, 1], pushOffset: 0))
        #expect(stack(100) == StickyStack(rows: [0, 1], pushOffset: 0))
    }

    @Test("a folder's row is pinned only once it scrolls past its slot")
    func pinsOnlyPastTheSlot() {
        // `closed` (row 12) sits exactly in the second slot: its real row shows.
        #expect(stack(264) == StickyStack(rows: [0], pushOffset: 0))
        #expect(stack(270) == StickyStack(rows: [0, 12], pushOffset: 0))
    }

    @Test("the end of a pinned folder's contents pushes it up")
    func pushOff() {
        // `open` ends at row 11 (bottom 288); its slot's bottom is offset + 48.
        #expect(stack(240) == StickyStack(rows: [0, 1], pushOffset: 0))
        #expect(stack(250) == StickyStack(rows: [0, 1], pushOffset: -10))
        #expect(stack(263) == StickyStack(rows: [0, 1], pushOffset: -23))
        // `.audit` ends at row 15 (bottom 384): it slides up and nothing pins below it.
        #expect(stack(360) == StickyStack(rows: [0], pushOffset: 0))
        #expect(stack(370) == StickyStack(rows: [0], pushOffset: -10))
        #expect(stack(390) == StickyStack(rows: [16], pushOffset: 0))
    }

    @Test("files and folders without visible contents are never pinned")
    func onlyFoldersWithContents() {
        let flat = StickyOutline(depths: [0, 0, 0, 0, 0])
        #expect(flat.stack(scrollOffset: 30, rowHeight: h, topInset: 0, maxLevels: 4) == .empty)
        // An expanded but empty folder (row 1) has nothing to pin over.
        let empty = StickyOutline(depths: [0, 1, 0, 1, 1, 1])
        #expect(empty.stack(scrollOffset: 10, rowHeight: h, topInset: 0, maxLevels: 4)
                == StickyStack(rows: [0], pushOffset: 0))
    }

    @Test("the stack is capped, dropping the deepest folders")
    func capsDepth() {
        let deep = StickyOutline(depths: [0, 1, 2, 3, 4, 5] + Array(repeating: 6, count: 20))
        let four = deep.stack(scrollOffset: 200, rowHeight: h, topInset: 0, maxLevels: 4)
        #expect(four == StickyStack(rows: [0, 1, 2, 3], pushOffset: 0))
        let two = deep.stack(scrollOffset: 200, rowHeight: h, topInset: 0, maxLevels: 2)
        #expect(two == StickyStack(rows: [0, 1], pushOffset: 0))
        #expect(deep.stack(scrollOffset: 200, rowHeight: h, topInset: 0, maxLevels: 0) == .empty)
    }

    @Test("honors padding above the first row")
    func topInset() {
        #expect(stack(2, inset: 2) == .empty)
        #expect(stack(3, inset: 2) == StickyStack(rows: [0, 1], pushOffset: 0))
    }

    @Test("degenerate input pins nothing")
    func degenerate() {
        #expect(StickyOutline(depths: []).stack(scrollOffset: 50, rowHeight: h, topInset: 0, maxLevels: 4) == .empty)
        #expect(outline.stack(scrollOffset: 50, rowHeight: 0, topInset: 0, maxLevels: 4) == .empty)
        #expect(stack(10_000) == .empty, "past the last row")
    }

    @Test("the stack's visible height follows the push")
    func visibleHeight() {
        #expect(StickyStack.empty.height(rowHeight: h) == 0)
        #expect(StickyStack(rows: [0, 1], pushOffset: 0).height(rowHeight: h) == 48)
        #expect(StickyStack(rows: [0, 1], pushOffset: -10).height(rowHeight: h) == 38)
    }

    @Test("a row hidden under the stack or above the list is revealed just below its folders")
    func revealTarget() {
        // Row 5 (depth 2) is under the stack at offset 100 (rows 4.2...): put row 3 at the top.
        #expect(outline.revealAnchor(for: 5, scrollOffset: 100, rowHeight: h, topInset: 0, maxLevels: 4) == 3)
        // Far above the viewport.
        #expect(outline.revealAnchor(for: 2, scrollOffset: 300, rowHeight: h, topInset: 0, maxLevels: 4) == 0)
        // A top-level row goes straight to the top.
        #expect(outline.revealAnchor(for: 0, scrollOffset: 100, rowHeight: h, topInset: 0, maxLevels: 4) == 0)
        // Only as many folders as the cap allows sit above it.
        #expect(outline.revealAnchor(for: 5, scrollOffset: 100, rowHeight: h, topInset: 0, maxLevels: 1) == 4)
    }

    @Test("a row that is already in view needs no reveal")
    func revealNotNeeded() {
        // Offset 100 pins two rows (height 48): rows from 148 down are clear.
        #expect(outline.revealAnchor(for: 7, scrollOffset: 100, rowHeight: h, topInset: 0, maxLevels: 4) == nil)
        // Below the viewport is the plain scroll's job.
        #expect(outline.revealAnchor(for: 26, scrollOffset: 0, rowHeight: h, topInset: 0, maxLevels: 4) == nil)
        #expect(outline.revealAnchor(for: 99, scrollOffset: 100, rowHeight: h, topInset: 0, maxLevels: 4) == nil)
    }

    @Test("short lists allow fewer pinned levels")
    func levelLimit() {
        #expect(StickyOutline.levelLimit(viewportHeight: 600, rowHeight: h) == 4)
        #expect(StickyOutline.levelLimit(viewportHeight: 150, rowHeight: h) == 2)
        #expect(StickyOutline.levelLimit(viewportHeight: 40, rowHeight: h) == 0)
        #expect(StickyOutline.levelLimit(viewportHeight: 600, rowHeight: 0) == 0)
    }
}
