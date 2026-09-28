import Testing
import TeebeCore
@testable import Teebe

@Suite("Worktree row tooltips")
struct MergeIndicatorPresentationTests {
    @Test("each merge state states itself in one line, against the named branch")
    func mergeStates() {
        var entry = CleanupEntry(worktree: Worktree(path: "/feature"))
        entry.mergeStatus = .merged
        #expect(detail(entry) == "All commits are in dev.")

        entry.mergeStatus = .notConfirmed
        #expect(detail(entry) == "Commits not found in dev.")

        // Uncommitted work wins the group, but the unmerged commits are still true:
        // say both, shortest first.
        entry.hasLocalChanges = true
        #expect(detail(entry) == "Uncommitted changes in this folder. Commits not found in dev.")
        #expect(MergeIndicatorPresentation(
            status: WorktreeMergeEntry(entry: entry, localChangeCount: 3), targetName: "dev", isChecking: false)
            .detail == "3 uncommitted files. Commits not found in dev.")
    }

    @Test("a squash merge is stated as merged, with no hedging")
    func squashIsMerged() {
        var entry = CleanupEntry(worktree: Worktree(path: "/feature"))
        entry.mergeStatus = .merged
        entry.hasEquivalentContent = true
        #expect(detail(entry) == "All commits are in dev.")
    }

    @Test("each state keeps exactly one detail, the highest-precedence cause")
    func onePrecedenceOrderedDetail() {
        for kind in 0..<3 {
            var entry = CleanupEntry(worktree: Worktree(path: "/feature"))
            entry.mergeStatus = .merged
            entry.hasIgnoredFiles = kind == 0
            entry.hasUncheckedFiles = kind == 1
            entry.hasSubmodules = kind == 2
            let result = detail(entry)
            #expect(result.count < 100)
            #expect(result.contains("Ignored files remain") == entry.hasIgnoredFiles)
            #expect(result.contains("marked unchanged in Git") == entry.hasUncheckedFiles)
            #expect(result.contains("Contains a submodule") == entry.hasSubmodules)
        }

        // Every condition at once still yields one line: the most important one.
        var entry = CleanupEntry(worktree: Worktree(path: "/feature"))
        entry.mergeStatus = .merged
        entry.hasLocalChanges = true
        entry.hasIgnoredFiles = true
        entry.hasUncheckedFiles = true
        entry.hasSubmodules = true
        let combined = MergeIndicatorPresentation(
            status: WorktreeMergeEntry(entry: entry, localChangeCount: 3), targetName: "dev", isChecking: false)
        #expect(combined.detail == "3 uncommitted files.")
        #expect(detail(entry) == "Uncommitted changes in this folder.")
    }

    @Test("a broken checkout names the failure, and says what clears it")
    func explanations() {
        var entry = CleanupEntry(worktree: Worktree(path: "/feature"))
        entry.isBroken = true
        entry.problem = "Broken worktree: its .git link is missing. Remaining files were not changed."
        // Prune cannot touch this one: its folder is still there.
        #expect(detail(entry) == "The .git link is missing. Remove the folder in Finder, then prune.")
        entry.problem = "Broken worktree: its folder is missing."
        #expect(detail(entry) == "The folder no longer exists.")
    }

    @Test("checking and missing-target states remain actionable")
    func unavailableHelp() {
        let checking = MergeIndicatorPresentation(status: nil, targetName: nil, isChecking: true)
        #expect(checking.detail == MergeIndicatorPresentation.checkingDetail)
        #expect(!checking.detail.contains("unavailable"))
        #expect(MergeIndicatorPresentation(status: nil, targetName: nil, isChecking: false)
            .detail == "Git could not check this worktree.")
        let entry = CleanupEntry(worktree: Worktree(path: "/feature"))
        #expect(MergeIndicatorPresentation(status: WorktreeMergeEntry(entry: entry), targetName: nil, isChecking: false)
            .detail == "Choose a comparison branch.")
    }

    @Test("a worktree that just committed says so instead of losing its result")
    func rechecking() {
        var entry = CleanupEntry(worktree: Worktree(path: "/feature"))
        entry.mergeStatus = .merged
        let status = WorktreeMergeEntry(entry: entry, isRechecking: true)
        let result = MergeIndicatorPresentation(status: status, targetName: "dev", isChecking: false)
        #expect(result.detail == MergeIndicatorPresentation.checkingDetail)
    }

    @Test("ignored-file examples are real, bounded and only shown for ignored files")
    func ignoredExamples() {
        var entry = CleanupEntry(worktree: Worktree(path: "/feature"))
        entry.mergeStatus = .merged
        entry.hasIgnoredFiles = true
        entry.ignoredPaths = ["node_modules/", ".build/", "cache/"]
        #expect(detail(entry) == "Ignored files remain (node_modules/, .build/, …).")
        entry.ignoredPaths = [String(repeating: "long", count: 100)]
        #expect(detail(entry).count < 80)
        entry.hasIgnoredFiles = false
        #expect(!detail(entry).contains("Ignored files remain"))
    }

    private func detail(_ entry: CleanupEntry) -> String {
        MergeIndicatorPresentation(status: WorktreeMergeEntry(entry: entry), targetName: "dev", isChecking: false).detail
    }
}
