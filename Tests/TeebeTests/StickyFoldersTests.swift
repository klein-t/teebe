import Foundation
import Observation
@testable import Teebe
import TeebeCore
import Testing

@MainActor
@Suite("Folders pinned over the FILES tree")
struct StickyFoldersTests {
    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false
        func raise() { lock.lock(); raised = true; lock.unlock() }
        var isRaised: Bool { lock.lock(); defer { lock.unlock() }; return raised }
    }

    /// src/ > app/ > f0...f9, then README.md.
    static let rows: [WorktreeModel.TreeRow] = {
        var rows = [WorktreeModel.TreeRow(node: FileNode(path: "/r/src", isDirectory: true), depth: 0),
                    WorktreeModel.TreeRow(node: FileNode(path: "/r/src/app", isDirectory: true), depth: 1)]
        rows += (0..<10).map { WorktreeModel.TreeRow(node: FileNode(path: "/r/src/app/f\($0)", isDirectory: false), depth: 2) }
        rows.append(WorktreeModel.TreeRow(node: FileNode(path: "/r/README.md", isDirectory: false), depth: 0))
        return rows
    }()

    func model(offset: CGFloat, viewport: CGFloat = 300) -> StickyFolders {
        let sticky = StickyFolders()
        sticky.update(rows: Self.rows)
        sticky.update(viewportHeight: viewport)
        sticky.update(scrollOffset: offset)
        return sticky
    }

    @Test("pins the open folders only once the list is scrolled")
    func pins() {
        let sticky = model(offset: 0)
        #expect(sticky.pinned(at: 0).rows.isEmpty)
        #expect(sticky.pinned(at: 30).rows.map(\.id) == ["/r/src", "/r/src/app"])
        #expect(sticky.pinned(at: 30).pushOffset == 0)
    }

    @Test("the innermost folder slides up as its contents end")
    func push() {
        // app's contents end at 290 (2pt padding + 12 rows); its slot ends at offset + 48.
        let pinned = model(offset: 0).pinned(at: 250)
        #expect(pinned.rows.map(\.id) == ["/r/src", "/r/src/app"])
        #expect(pinned.pushOffset == -8)
    }

    @Test("a short list pins nothing")
    func shortList() {
        #expect(model(offset: 0, viewport: 40).pinned(at: 30).rows.isEmpty)
    }

    @Test("scrolling alone changes nothing a view observes")
    func quietScroll() {
        let sticky = model(offset: 30)
        let flag = Flag()
        withObservationTracking {
            _ = sticky.pinned(at: 30)
        } onChange: { flag.raise() }
        sticky.update(scrollOffset: 60)
        sticky.update(scrollOffset: 250)
        sticky.update(viewportHeight: 300)
        #expect(!flag.isRaised)
        sticky.update(rows: Array(Self.rows.prefix(3)))
        #expect(flag.isRaised)
    }

    @Test("a row hidden under the pinned folders is revealed just below them")
    func reveal() {
        let sticky = model(offset: 100)
        #expect(sticky.revealAnchor(for: "/r/src/app/f2") == "/r/src/app/f0")
        #expect(sticky.revealAnchor(for: "/r/src/app/f8") == nil)
        #expect(sticky.revealAnchor(for: "/r/missing") == nil)
    }
}
