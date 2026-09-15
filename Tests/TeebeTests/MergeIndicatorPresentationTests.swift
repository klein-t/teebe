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
        #expect(presentation(entry).description.contains("Commits included in dev"))
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
        #expect(presentation(entry).description.contains("squash-equivalent"))
    }

    private func presentation(_ entry: CleanupEntry) -> MergeIndicatorPresentation {
        MergeIndicatorPresentation(entry: entry, targetName: "dev", isChecking: false)
    }
}
