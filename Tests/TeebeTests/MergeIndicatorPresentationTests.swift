import Testing
import TeebeCore
@testable import Teebe

@Suite("Merge icon meaning")
struct MergeIndicatorPresentationTests {
    @Test("distinct shapes show clean, edited and unconfirmed states without dots")
    func cleanAndDirty() {
        var entry = CleanupEntry(worktree: Worktree(path: "/feature"))
        entry.mergeStatus = .merged
        #expect(presentation(entry).symbol == .merge)
        #expect(presentation(entry).tone == .merged)
        #expect(!presentation(entry).hasLocalFiles)
        entry.hasLocalChanges = true
        #expect(presentation(entry).symbol == .edit)
        #expect(presentation(entry).tone != .merged)
        #expect(presentation(entry).hasLocalFiles)
        #expect(presentation(entry).title == "Uncommitted changes")
        #expect(presentation(entry).details == ["Merged into dev"])
        entry.mergeStatus = .notConfirmed
        #expect(presentation(entry).symbol == .edit)
        #expect(presentation(entry).details == ["Merge unconfirmed against dev"])
        entry.hasLocalChanges = false
        #expect(presentation(entry).symbol == .branch)
        #expect(presentation(entry).title == "Merge unconfirmed")
    }

    @Test("each local condition stays specific and concise")
    func otherLocalFiles() {
        for kind in 0..<3 {
            var entry = CleanupEntry(worktree: Worktree(path: "/feature"))
            entry.mergeStatus = .merged
            entry.hasIgnoredFiles = kind == 0
            entry.hasUncheckedFiles = kind == 1
            entry.hasSubmodules = kind == 2
            let result = presentation(entry)
            #expect(result.hasLocalFiles)
            #expect(result.tone != .merged)
            #expect(result.details.count == 2)
            #expect(result.symbol == (entry.hasIgnoredFiles ? .ignored : .warning))
            #expect(result.description.count < 130)
            #expect(result.description.contains("Ignored files") == entry.hasIgnoredFiles)
            #expect(result.description.contains("skips change checks") == entry.hasUncheckedFiles)
            #expect(result.description.contains("Nested Git repository") == entry.hasSubmodules)
        }
    }

    @Test("broken and squash-equivalent results have distinct explanations")
    func explanations() {
        var entry = CleanupEntry(worktree: Worktree(path: "/feature"))
        entry.isBroken = true
        entry.problem = "Broken worktree: its .git link is missing. Remaining files were not changed."
        #expect(presentation(entry).symbol == .warning)
        #expect(presentation(entry).details == ["its .git link is missing."])
        entry.isBroken = false
        entry.problem = nil
        #expect(presentation(entry).symbol == .unknown)
        entry.mergeStatus = .merged
        entry.hasEquivalentContent = true
        #expect(presentation(entry).title == "Changes already in dev")
    }

    @Test("multiple conditions remain short without dropping reasons")
    func combinedConditions() {
        var entry = CleanupEntry(worktree: Worktree(path: "/feature"))
        entry.mergeStatus = .merged
        entry.hasLocalChanges = true
        entry.hasIgnoredFiles = true
        entry.hasUncheckedFiles = true
        entry.hasSubmodules = true
        let result = presentation(entry)
        #expect(result.details.count == 4)
        #expect(result.description.count < 200)
    }

    @Test("checking and missing-target states remain actionable")
    func unavailableHelp() {
        #expect(MergeIndicatorPresentation(entry: nil, targetName: nil, isChecking: true).symbol == .checking)
        #expect(MergeIndicatorPresentation(entry: nil, targetName: nil, isChecking: false)
            .details == ["Refresh to try again"])
        let entry = CleanupEntry(worktree: Worktree(path: "/feature"))
        #expect(MergeIndicatorPresentation(entry: entry, targetName: nil, isChecking: false)
            .details == ["Choose one in Clean up worktrees"])
    }

    private func presentation(_ entry: CleanupEntry) -> MergeIndicatorPresentation {
        MergeIndicatorPresentation(entry: entry, targetName: "dev", isChecking: false)
    }
}
