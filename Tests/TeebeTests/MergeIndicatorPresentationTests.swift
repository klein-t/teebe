import Testing
import TeebeCore
@testable import Teebe

@Suite("Merge icon meaning")
struct MergeIndicatorPresentationTests {
    @Test("titles are the group's own words and never more than one detail follows")
    func titlesMatchGroups() {
        var entry = CleanupEntry(worktree: Worktree(path: "/feature"))
        entry.mergeStatus = .merged
        #expect(presentation(entry).title == WorktreeGroup.merged.title)
        #expect(presentation(entry).details == ["All commits are in dev."])
        #expect(presentation(entry).symbol == .merge)
        #expect(presentation(entry).tone == .merged)

        entry.hasLocalChanges = true
        #expect(presentation(entry).title == WorktreeGroup.localChanges.title)
        #expect(presentation(entry).symbol == .edit)
        #expect(presentation(entry).tone != .merged)

        entry.hasLocalChanges = false
        entry.mergeStatus = .notConfirmed
        #expect(presentation(entry).title == WorktreeGroup.notMerged.title)
        #expect(presentation(entry).details == ["Commits not found in dev."])
        #expect(presentation(entry).symbol == .branch)
    }

    @Test("a squash merge is stated as merged, with no hedging")
    func squashIsMerged() {
        var entry = CleanupEntry(worktree: Worktree(path: "/feature"))
        entry.mergeStatus = .merged
        entry.hasEquivalentContent = true
        #expect(presentation(entry).title == "Merged")
        #expect(presentation(entry).details == ["All commits are in dev."])
        #expect(!presentation(entry).description.contains("not confirmed"))
        #expect(!presentation(entry).description.contains("unconfirmed"))
    }

    @Test("each state keeps exactly one detail, the highest-precedence cause")
    func onePrecedenceOrderedDetail() {
        for kind in 0..<3 {
            var entry = CleanupEntry(worktree: Worktree(path: "/feature"))
            entry.mergeStatus = .merged
            entry.hasIgnoredFiles = kind == 0
            entry.hasUncheckedFiles = kind == 1
            entry.hasSubmodules = kind == 2
            let result = presentation(entry)
            #expect(result.details.count <= 1)
            #expect(result.symbol == (entry.hasIgnoredFiles ? .ignored : .warning))
            #expect(result.description.count < 100)
            #expect(result.description.contains("Ignored files remain") == entry.hasIgnoredFiles)
            #expect(result.description.contains("marked unchanged in Git") == entry.hasUncheckedFiles)
            #expect(result.description.contains("Contains a submodule") == entry.hasSubmodules)
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
        #expect(combined.details == ["3 uncommitted files."])
        #expect(combined.description == "Local changes. 3 uncommitted files.")
        #expect(presentation(entry).details == ["Uncommitted changes in this folder."])
    }

    @Test("the spoken label never doubles a period")
    func accessibilityLabel() {
        var entry = CleanupEntry(worktree: Worktree(path: "/feature"))
        entry.mergeStatus = .merged
        entry.hasIgnoredFiles = true
        entry.ignoredPaths = ["build/", ".env"]
        #expect(presentation(entry).description == "Merged. Ignored files remain (build/, .env).")
        #expect(!presentation(entry).description.contains(".."))
    }

    @Test("broken worktrees name the concrete failure")
    func explanations() {
        var entry = CleanupEntry(worktree: Worktree(path: "/feature"))
        entry.isBroken = true
        entry.problem = "Broken worktree: its .git link is missing. Remaining files were not changed."
        #expect(presentation(entry).title == WorktreeGroup.broken.title)
        #expect(presentation(entry).tone == .error)
        #expect(presentation(entry).details == ["The .git link is missing."])
    }

    @Test("checking and missing-target states remain actionable")
    func unavailableHelp() {
        let checking = MergeIndicatorPresentation(status: nil, targetName: nil, isChecking: true)
        #expect(checking.symbol == .checking)
        #expect(checking.title == WorktreeGroup.notChecked.title)
        #expect(checking.details == [MergeIndicatorPresentation.checkingDetail])
        #expect(!checking.description.contains("unavailable"))
        #expect(MergeIndicatorPresentation(status: nil, targetName: nil, isChecking: false)
            .details == ["Git could not check this worktree."])
        let entry = CleanupEntry(worktree: Worktree(path: "/feature"))
        #expect(MergeIndicatorPresentation(status: WorktreeMergeEntry(entry: entry), targetName: nil, isChecking: false)
            .details == ["Choose a comparison branch."])
    }

    @Test("a worktree that just committed says so instead of losing its result")
    func rechecking() {
        var entry = CleanupEntry(worktree: Worktree(path: "/feature"))
        entry.mergeStatus = .merged
        let status = WorktreeMergeEntry(entry: entry, isRechecking: true)
        let result = MergeIndicatorPresentation(status: status, targetName: "dev", isChecking: false)
        #expect(result.symbol == .checking)
        #expect(result.title == WorktreeGroup.merged.title)   // it keeps its group
        #expect(result.details == [MergeIndicatorPresentation.checkingDetail])
    }

    @Test("ignored-file examples are real, bounded and only shown for ignored files")
    func ignoredExamples() {
        var entry = CleanupEntry(worktree: Worktree(path: "/feature"))
        entry.mergeStatus = .merged
        entry.hasIgnoredFiles = true
        entry.ignoredPaths = ["node_modules/", ".build/", "cache/"]
        let result = presentation(entry)
        #expect(result.symbol == .ignored)
        #expect(result.details[0] == "Ignored files remain (node_modules/, .build/, …).")
        entry.ignoredPaths = [String(repeating: "long", count: 100)]
        #expect(presentation(entry).details[0].count < 80)
        entry.hasIgnoredFiles = false
        #expect(!presentation(entry).description.contains("Ignored files remain"))
    }

    private func presentation(_ entry: CleanupEntry) -> MergeIndicatorPresentation {
        MergeIndicatorPresentation(status: WorktreeMergeEntry(entry: entry), targetName: "dev", isChecking: false)
    }
}
