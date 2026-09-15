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
        #expect(presentation(entry).details.contains("Commits are already in dev."))
        entry.mergeStatus = .notConfirmed
        #expect(presentation(entry).symbol == .edit)
        #expect(presentation(entry).details.contains("Merge into dev not confirmed."))
        entry.hasLocalChanges = false
        #expect(presentation(entry).symbol == .branch)
        #expect(presentation(entry).title == "Merge not confirmed")
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
            #expect(result.description.count < 170)
            #expect(result.description.contains("Git ignore rules") == entry.hasIgnoredFiles)
            #expect(result.description.contains("skip checking") == entry.hasUncheckedFiles)
            #expect(result.description.contains("Nested Git repository") == entry.hasSubmodules)
        }
    }

    @Test("broken and squash-equivalent results have distinct explanations")
    func explanations() {
        var entry = CleanupEntry(worktree: Worktree(path: "/feature"))
        entry.isBroken = true
        entry.problem = "Broken worktree: its .git link is missing. Remaining files were not changed."
        #expect(presentation(entry).symbol == .warning)
        #expect(presentation(entry).tone == .error)
        #expect(presentation(entry).details[0].contains("no longer connected to Git"))
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
        #expect(result.details.count == 5)
        #expect(result.description.count < 300)
    }

    @Test("checking and missing-target states remain actionable")
    func unavailableHelp() {
        #expect(MergeIndicatorPresentation(entry: nil, targetName: nil, isChecking: true).symbol == .checking)
        #expect(MergeIndicatorPresentation(entry: nil, targetName: nil, isChecking: false)
            .details[0].contains("Refresh to try again"))
        let entry = CleanupEntry(worktree: Worktree(path: "/feature"))
        #expect(MergeIndicatorPresentation(entry: entry, targetName: nil, isChecking: false)
            .details[0].contains("Select the branch to compare against"))
    }

    @Test("ignored-file examples are real, bounded and only shown for ignored files")
    func ignoredExamples() {
        var entry = CleanupEntry(worktree: Worktree(path: "/feature"))
        entry.mergeStatus = .merged
        entry.hasIgnoredFiles = true
        entry.ignoredPaths = ["node_modules/", ".build/", "cache/"]
        let result = presentation(entry)
        #expect(result.symbol == .ignored)
        #expect(result.details[0] == "Not included in commits: node_modules/, .build/, …")
        entry.ignoredPaths = [String(repeating: "long", count: 100)]
        #expect(presentation(entry).details[0].count < 80)
        entry.hasIgnoredFiles = false
        #expect(!presentation(entry).description.contains("Not included in commits"))
    }

    private func presentation(_ entry: CleanupEntry) -> MergeIndicatorPresentation {
        MergeIndicatorPresentation(entry: entry, targetName: "dev", isChecking: false)
    }
}
