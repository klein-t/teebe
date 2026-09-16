import Foundation
import Testing
import TeebeCore
@testable import Teebe

@MainActor
@Suite("Worktree groups and section sizing")
struct WorktreeListPresentationTests {
    @Test("dirty and broken worktrees never enter the merged group; ignored files stay details")
    func classification() {
        var entry = CleanupEntry(worktree: Worktree(path: "/feature"))
        entry.mergeStatus = .merged
        #expect(WorktreeGroup.classify(entry) == .merged)
        entry.hasIgnoredFiles = true
        #expect(WorktreeGroup.classify(entry) == .merged)
        #expect(!entry.canRemove(includingIgnored: false))
        entry.hasLocalChanges = true
        #expect(WorktreeGroup.classify(entry) == .localChanges)
        entry.isBroken = true
        #expect(WorktreeGroup.classify(entry) == .broken)
        entry.isBroken = false
        entry.hasLocalChanges = false
        entry.hasUncheckedFiles = true
        #expect(WorktreeGroup.classify(entry) == .needsReview)
        #expect(WorktreeGroup.classify(nil) == .needsReview)
    }

    @Test("group order, collapsed navigation, and the comparison checkout stay consistent")
    func groupingAndNavigation() {
        let primary = Worktree(path: "/primary", isPrimary: true)
        let clean = Worktree(path: "/merged")
        let dirty = Worktree(path: "/dirty")
        let target = Worktree(path: "/dev")
        var cleanEntry = CleanupEntry(worktree: clean)
        cleanEntry.mergeStatus = .merged
        var dirtyEntry = CleanupEntry(worktree: dirty)
        dirtyEntry.hasLocalChanges = true
        var targetEntry = CleanupEntry(worktree: target)
        targetEntry.isTarget = true
        let trees = [primary, clean, dirty, target]
        let entries = [clean.path: cleanEntry, dirty.path: dirtyEntry, target.path: targetEntry]
        let open = WorktreeListPresentation(worktrees: trees, entries: entries, grouped: true,
                                           collapsed: [], hasRepository: true)
        let closed = WorktreeListPresentation(worktrees: trees, entries: entries, grouped: true,
                                             collapsed: [.merged], hasRepository: true)
        #expect(open.visibleWorktrees.map(\.path) == ["/primary", "/dev", "/dirty", "/merged"])
        #expect(closed.visibleWorktrees.map(\.path) == ["/primary", "/dev", "/dirty"])
        #expect(open.naturalHeight - closed.naturalHeight == WorktreeListPresentation.rowHeight)
        let selector = AppModel(environment: makeTestEnvironment()).selector
        selector.highlightedWorktree = primary
        selector.moveWorktreeHighlight(by: 1, in: closed.visibleWorktrees)
        #expect(selector.highlightedWorktree?.path == "/dev")
        selector.moveWorktreeHighlight(by: 10, in: closed.visibleWorktrees)
        #expect(selector.highlightedWorktree?.path == "/dirty")
        let flat = WorktreeListPresentation(worktrees: trees, entries: entries, grouped: false,
                                           collapsed: [.merged], hasRepository: true)
        #expect(flat.groups.isEmpty)
        #expect(flat.visibleWorktrees == trees)
    }

    @Test("the cursor steps out of a collapsed group instead of jumping to the top")
    func navigationFromHiddenRow() async {
        let git = FakeGitClient()
        // Discovery order is primary first, then by folder name: the hidden row
        // sits between two visible ones.
        let primary = Worktree(path: "/primary", isPrimary: true)
        let clean = Worktree(path: "/aaa")
        let dirty = Worktree(path: "/bbb")
        let target = Worktree(path: "/dev")
        git.worktreesResult = [primary, clean, dirty, target]
        var cleanEntry = CleanupEntry(worktree: clean)
        cleanEntry.mergeStatus = .merged
        var dirtyEntry = CleanupEntry(worktree: dirty)
        dirtyEntry.hasLocalChanges = true
        var targetEntry = CleanupEntry(worktree: target)
        targetEntry.isTarget = true
        let closed = WorktreeListPresentation(
            worktrees: git.worktreesResult,
            entries: [clean.path: cleanEntry, dirty.path: dirtyEntry, target.path: targetEntry],
            grouped: true, collapsed: [.merged], hasRepository: true)
        #expect(!closed.visibleWorktrees.contains { $0.path == "/aaa" })

        let selector = SelectorModel(environment: makeTestEnvironment(git: git))
        await selector.selectRepo(Repository(path: "/primary"))
        // The cursor is parked on a row that the user then collapsed out of sight.
        selector.highlightedWorktree = clean
        selector.moveWorktreeHighlight(by: 1, in: closed.visibleWorktrees)
        #expect(selector.highlightedWorktree?.path == "/bbb")
        selector.highlightedWorktree = clean
        selector.moveWorktreeHighlight(by: -1, in: closed.visibleWorktrees)
        #expect(selector.highlightedWorktree?.path == "/primary")
    }

    @Test("resizing preserves the chosen reveal, clamps to available screen, and accepts old layouts")
    func resizeAndPersistence() throws {
        #expect(WorktreeSectionSizing.height(preferred: nil, natural: 400, available: 700) == 200)
        #expect(WorktreeSectionSizing.height(preferred: 340, natural: 200, available: 700) == 340)
        #expect(WorktreeSectionSizing.height(preferred: 900, natural: 200, available: 370) == 370)
        #expect(WorktreeSectionSizing.height(preferred: -50, natural: 200, available: 370) == 80)
        let old = Data(#"{"worktreesOpen":true,"changesOpen":true,"filesOpen":true,"windowHeight":300}"#.utf8)
        let decoded = try JSONDecoder().decode(SectionLayout.self, from: old)
        #expect(decoded.worktreesHeight == nil)
        #expect(decoded.collapsedWorktreeGroups == nil)
        let env = makeTestEnvironment()
        let app = AppModel(environment: env)
        let layout = SectionLayout(windowHeight: 300, worktreesHeight: 340, collapsedWorktreeGroups: ["merged"])
        app.saveLayout(layout, forRepo: "/repo")
        #expect(AppModel(environment: env).layout(forRepo: "/repo") == layout)
        #expect(app.layout(forRepo: "/other") == nil)
    }
}
