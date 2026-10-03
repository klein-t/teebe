import Testing
import TeebeCore
@testable import Teebe

struct StatusBadgeTests {
    @Test func untrackedExplanation() {
        #expect(ChangeStatus.untracked.helpText == "Untracked file · Not yet added to Git")
    }

    @Test(arguments: ChangeStatus.allCases)
    func everyVisibleBadgeHasAnExplanation(_ status: ChangeStatus) {
        if status.badgeLetter != nil {
            #expect(status.helpText.contains(" · "))
            #expect(status.helpText.count > 20)
        }
    }

    @Test func explanationFollowsDisplayedStatus() {
        let mixed = FileChange(path: "file", indexStatus: .added, worktreeStatus: .modified)
        #expect(mixed.primaryStatus.helpText == ChangeStatus.modified.helpText)
        let staged = FileChange(path: "file", indexStatus: .added)
        #expect(staged.primaryStatus.helpText == ChangeStatus.added.helpText)
        #expect(ChangeStatus.typeChanged.helpText != ChangeStatus.modified.helpText)
    }
}
