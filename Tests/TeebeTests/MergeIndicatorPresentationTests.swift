import Testing
import TeebeCore
@testable import Teebe

@Suite("Merge icon meaning")
struct MergeIndicatorPresentationTests {
    @Test("only confirmed clean entries get the green arrow")
    func cleanAndDirty() {
        var entry = CleanupEntry(worktree: Worktree(path: "/feature"))
        entry.mergeStatus = .merged
        #expect(presentation(entry).symbol == "arrow.triangle.merge")
        entry.hasLocalChanges = true
        #expect(presentation(entry).symbol == "pencil.circle")
        #expect(presentation(entry).tone == .attention)
        #expect(presentation(entry).description.contains("Uncommitted"))
        #expect(presentation(entry).description.contains("All commits are already in dev"))
        entry.mergeStatus = .notConfirmed
        #expect(presentation(entry).symbol == "pencil.circle")
        #expect(presentation(entry).description.contains("not confirmed"))
    }

    @Test("ignored, unchecked and submodule content cannot look clean")
    func otherLocalFiles() {
        for kind in 0..<3 {
            var entry = CleanupEntry(worktree: Worktree(path: "/feature"))
            entry.mergeStatus = .merged
            entry.hasIgnoredFiles = kind == 0
            entry.hasUncheckedFiles = kind == 1
            entry.hasSubmodules = kind == 2
            #expect(presentation(entry).symbol == "doc.badge.ellipsis")
            #expect(presentation(entry).tone != .merged)
            let text = presentation(entry).description
            #expect(text.contains("All commits are already in dev"))
            #expect(text.contains("Ignored files are present") == entry.hasIgnoredFiles)
            #expect(text.contains("excluded from Git's change checks") == entry.hasUncheckedFiles)
            #expect(text.contains("nested Git repository") == entry.hasSubmodules)
            #expect(!text.contains("separate checks"))
        }
    }

    @Test("broken, unavailable and squash-equivalent results have distinct explanations")
    func explanations() {
        var entry = CleanupEntry(worktree: Worktree(path: "/feature"))
        entry.isBroken = true
        entry.problem = "Broken worktree: its .git link is missing."
        #expect(presentation(entry).symbol == "exclamationmark.triangle")
        #expect(presentation(entry).description.contains(".git link is missing"))
        entry.isBroken = false
        entry.problem = nil
        #expect(presentation(entry).symbol == "questionmark.circle")
        entry.mergeStatus = .merged
        entry.hasEquivalentContent = true
        #expect(presentation(entry).description.contains("changed files match"))
    }

    @Test("hover text includes every detected condition instead of hiding secondary reasons")
    func combinedConditions() {
        var entry = CleanupEntry(worktree: Worktree(path: "/feature"))
        entry.mergeStatus = .merged
        entry.hasLocalChanges = true
        entry.hasIgnoredFiles = true
        entry.hasUncheckedFiles = true
        entry.hasSubmodules = true
        let text = presentation(entry).description
        #expect(text.contains("Uncommitted changes"))
        #expect(text.contains("Ignored files are present"))
        #expect(text.contains("excluded from Git's change checks"))
        #expect(text.contains("nested Git repository"))
        #expect(!text.contains("Clean folder"))
    }

    @Test("checking, unavailable and missing-target icons explain the next step")
    func unavailableHelp() {
        #expect(MergeIndicatorPresentation(entry: nil, targetName: nil, isChecking: true)
            .description == "Checking merge status…")
        #expect(MergeIndicatorPresentation(entry: nil, targetName: nil, isChecking: false)
            .description.contains("Refresh worktrees"))
        let entry = CleanupEntry(worktree: Worktree(path: "/feature"))
        #expect(MergeIndicatorPresentation(entry: entry, targetName: nil, isChecking: false)
            .description.contains("Choose one in Clean up worktrees"))
    }

    private func presentation(_ entry: CleanupEntry) -> MergeIndicatorPresentation {
        MergeIndicatorPresentation(entry: entry, targetName: "dev", isChecking: false)
    }
}
