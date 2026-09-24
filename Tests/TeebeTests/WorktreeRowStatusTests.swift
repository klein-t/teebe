import Testing
import TeebeCore
@testable import Teebe

@Suite("Worktree row labels")
struct WorktreeRowStatusTests {
    @Test("clean unmerged worktrees need no status label")
    func quietCleanRow() {
        var entry = CleanupEntry(worktree: Worktree(path: "/feature", branch: "feature"))
        entry.mergeStatus = .notConfirmed
        let row = presentation(entry)
        #expect(row.changesLabel == nil)
        #expect(row.mergedHelp == nil)
    }

    @Test("local edits take precedence over the merged badge")
    func mergedWithEdits() {
        var entry = CleanupEntry(worktree: Worktree(path: "/feature", branch: "feature"))
        entry.mergeStatus = .merged
        #expect(presentation(entry).mergedHelp?.contains("All commits are in origin/dev.") == true)
        entry.hasLocalChanges = true
        #expect(presentation(entry, count: 3).changesLabel == "3 changes")
        #expect(presentation(entry, count: 3).mergedHelp == nil)
        #expect(presentation(entry, count: 3).changesHelp.contains("All commits are in origin/dev."))
        #expect(presentation(entry, count: 1).changesLabel == "1 change")
        #expect(presentation(entry).changesLabel == "Changes")
        #expect(presentation(entry).mergedHelp == nil)
        entry.hasLocalChanges = false
        #expect(presentation(entry, count: 1).mergedHelp == nil)
        entry.hasEquivalentContent = true
        #expect(presentation(entry).mergedHelp?.contains("Committed changes are included in origin/dev.") == true)
        #expect(presentation(entry).mergedHelp?.contains("files may still need keeping") == true)
    }

    @Test("unchecked files and submodules cannot claim a verified clean merge")
    func uncheckedLocalState() {
        var entry = CleanupEntry(worktree: Worktree(path: "/feature"))
        entry.mergeStatus = .merged
        entry.hasUncheckedFiles = true
        #expect(presentation(entry).mergedHelp == nil)
        entry.hasUncheckedFiles = false
        entry.hasSubmodules = true
        #expect(presentation(entry).mergedHelp == nil)
    }

    @Test("unknown, rechecking, missing target, and broken states never claim merged")
    func noFalseMergeLabels() {
        var entry = CleanupEntry(worktree: Worktree(path: "/feature"))
        #expect(presentation(entry).mergedHelp == nil)
        entry.mergeStatus = .merged
        let status = WorktreeMergeEntry(entry: entry, isRechecking: true)
        #expect(WorktreeRowStatus(status: status, changeCount: 0, targetName: "main", isChecking: false).mergedHelp == nil)
        #expect(WorktreeRowStatus(status: .init(entry: entry), changeCount: 0,
                                 targetName: nil, isChecking: false).mergedHelp == nil)
        #expect(WorktreeRowStatus(status: .init(entry: entry), changeCount: 0,
                                 targetName: "main", isChecking: true).mergedHelp == nil)
        entry.isBroken = true
        #expect(presentation(entry).mergedHelp == nil)
        let absent = WorktreeRowStatus(status: nil, changeCount: 2, targetName: "main", isChecking: false)
        #expect(absent.mergedHelp == nil)
        #expect(absent.changesLabel == "2 changes")
    }

    @Test("the comparison worktree does not label itself merged")
    func targetIsQuiet() {
        var entry = CleanupEntry(worktree: Worktree(path: "/main", branch: "main", isPrimary: true))
        entry.mergeStatus = .merged
        entry.isTarget = true
        #expect(presentation(entry).mergedHelp == nil)
        #expect(presentation(entry, count: 1).changesLabel == "1 change")
    }

    private func presentation(_ entry: CleanupEntry, count: Int = 0) -> WorktreeRowStatus {
        WorktreeRowStatus(status: .init(entry: entry), changeCount: count, targetName: "origin/dev", isChecking: false)
    }
}
