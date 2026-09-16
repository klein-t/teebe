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
        #expect(WorktreeGroup.classify(status(entry)) == .merged)
        entry.hasIgnoredFiles = true
        #expect(WorktreeGroup.classify(status(entry)) == .merged)
        #expect(!entry.canRemove(includingIgnored: false))
        entry.hasLocalChanges = true
        #expect(WorktreeGroup.classify(status(entry)) == .localChanges)
        entry.isBroken = true
        #expect(WorktreeGroup.classify(status(entry)) == .broken)
        entry.isBroken = false
        entry.hasLocalChanges = false
        entry.hasUncheckedFiles = true
        #expect(WorktreeGroup.classify(status(entry)) == .notChecked)
        #expect(WorktreeGroup.classify(nil) == .notChecked)
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
        let entries = [clean.path: status(cleanEntry), dirty.path: status(dirtyEntry), target.path: status(targetEntry)]
        let open = WorktreeListPresentation(worktrees: trees, entries: entries, grouped: true,
                                           collapsed: [], hasRepository: true)
        let closed = WorktreeListPresentation(worktrees: trees, entries: entries, grouped: true,
                                             collapsed: [.merged], hasRepository: true)
        #expect(open.visibleWorktrees.map(\.path) == ["/primary", "/dev", "/merged", "/dirty"])
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

    @Test("groups read in a fixed order and their rows sort by branch name")
    func groupOrderAndRowSorting() {
        #expect(WorktreeGroup.allCases.map(\.title)
            == ["Merged", "Local changes", "Not merged", "Broken", "Not checked"])
        let zed = Worktree(path: "/one", branch: "zed")
        let alpha = Worktree(path: "/two", branch: "alpha")
        let unnamed = Worktree(path: "/mid")   // detached: falls back to the folder name
        var entries: [String: WorktreeMergeEntry] = [:]
        for tree in [zed, alpha, unnamed] {
            var entry = CleanupEntry(worktree: tree)
            entry.mergeStatus = .merged
            entries[tree.path] = status(entry)
        }
        let list = WorktreeListPresentation(worktrees: [zed, alpha, unnamed], entries: entries,
                                            grouped: true, collapsed: [], hasRepository: true)
        #expect(list.groups.map(\.kind) == [.merged])
        #expect(list.groups[0].worktrees.map { $0.branch ?? $0.name } == ["alpha", "mid", "zed"])
    }

    @Test("with no comparison branch the list stays flat and asks for one once")
    func noComparisonBranch() {
        let trees = [Worktree(path: "/primary", isPrimary: true), Worktree(path: "/feature", branch: "feature")]
        var unresolved = CleanupEntry(worktree: trees[1])
        unresolved.problem = "Choose a comparison branch"
        let list = WorktreeListPresentation(worktrees: trees, entries: [trees[1].path: status(unresolved)],
                                            grouped: true, collapsed: [], hasRepository: true, needsTarget: true)
        #expect(list.needsTarget)
        #expect(list.groups.isEmpty)
        #expect(list.visibleWorktrees == trees)
    }

    @Test("a worktree removed mid-scan leaves no row behind")
    func removedWorktreeLeavesNoRow() {
        let kept = Worktree(path: "/kept", branch: "kept")
        let gone = Worktree(path: "/gone", branch: "gone")
        var keptEntry = CleanupEntry(worktree: kept)
        keptEntry.mergeStatus = .merged
        var goneEntry = CleanupEntry(worktree: gone)
        goneEntry.mergeStatus = .merged
        // The scan finished after the worktree was removed, so its result outlives it.
        let list = WorktreeListPresentation(worktrees: [kept],
                                            entries: [kept.path: status(keptEntry), gone.path: status(goneEntry)],
                                            grouped: true, collapsed: [], hasRepository: true)
        #expect(list.visibleWorktrees.map(\.path) == ["/kept"])
        #expect(!list.groups.contains { $0.worktrees.contains { $0.path == "/gone" } })
        #expect(list.naturalHeight == WorktreeListPresentation.repoHeight
                + WorktreeListPresentation.verticalPadding
                + WorktreeListPresentation.rowHeight + WorktreeListPresentation.groupHeight)
    }

    @Test("collapsing every group with nothing pinned leaves only the headers")
    func heightWithEverythingCollapsed() {
        let merged = Worktree(path: "/merged", branch: "merged")
        let dirty = Worktree(path: "/dirty", branch: "dirty")
        var mergedEntry = CleanupEntry(worktree: merged)
        mergedEntry.mergeStatus = .merged
        var dirtyEntry = CleanupEntry(worktree: dirty)
        dirtyEntry.hasLocalChanges = true
        let list = WorktreeListPresentation(
            worktrees: [merged, dirty],
            entries: [merged.path: status(mergedEntry), dirty.path: status(dirtyEntry)],
            grouped: true, collapsed: [.merged, .localChanges], hasRepository: true)
        #expect(list.pinned.isEmpty)
        #expect(list.visibleWorktrees.isEmpty)
        #expect(list.naturalHeight == WorktreeListPresentation.repoHeight
                + WorktreeListPresentation.verticalPadding
                + 2 * WorktreeListPresentation.groupHeight)
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
            entries: [clean.path: status(cleanEntry), dirty.path: status(dirtyEntry), target.path: status(targetEntry)],
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
        #expect(WorktreeSectionSizing.height(preferred: 340, natural: 600, available: 700) == 340)
        #expect(WorktreeSectionSizing.height(preferred: 900, natural: 600, available: 370) == 370)
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

    @Test("the chosen height is a maximum: the pane hugs its rows and keeps the preference")
    func heightHugsContent() {
        // A group collapsed after a drag leaves fewer rows: the pane follows them down
        // instead of holding the dragged height open with blank material…
        #expect(WorktreeSectionSizing.height(preferred: 340, natural: 120, available: 700) == 120)
        // …and the 80pt floor never pads out content that is genuinely shorter.
        #expect(WorktreeSectionSizing.height(preferred: 340, natural: 55, available: 700) == 55)
        #expect(WorktreeSectionSizing.height(preferred: nil, natural: 55, available: 700) == 55)
        // The preference survives a small window: it is clamped for display only, so the
        // same preference renders tall again once there is room.
        #expect(WorktreeSectionSizing.height(preferred: 340, natural: 600, available: 150) == 150)
        #expect(WorktreeSectionSizing.height(preferred: 340, natural: 600, available: 700) == 340)
    }

    private func status(_ entry: CleanupEntry) -> WorktreeMergeEntry { WorktreeMergeEntry(entry: entry) }
}
