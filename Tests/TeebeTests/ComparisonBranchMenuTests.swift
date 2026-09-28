import Testing
import TeebeCore
@testable import Teebe

@Suite("Comparison branch menu")
struct ComparisonBranchMenuTests {
    @Test("the picker suggests None, then origin's integration lines, then local orphans")
    func picksSuggested() {
        let refs = branches([
            "refs/heads/main", "refs/heads/dev", "refs/heads/develop", "refs/heads/feat/x",
            "refs/remotes/origin/main", "refs/remotes/origin/dev"
        ])
        let sections = ComparisonBranchMenu.sections(refs)
        #expect(sections.suggested.map(\.name) == ["None", "main", "dev", "develop"])
        #expect(sections.suggested.map(\.detail) == ["No extra branch", "origin", "origin", "local"])
        #expect(sections.suggested.map(\.id)
            == ["", "refs/remotes/origin/main", "refs/remotes/origin/dev", "refs/heads/develop"])
    }

    @Test("everything else is alphabetical, local and remote interleaved by name")
    func picksRest() {
        let refs = branches([
            "refs/heads/main", "refs/heads/zeta", "refs/heads/alpha", "refs/heads/beta",
            "refs/remotes/origin/beta", "refs/remotes/upstream/alpha"
        ])
        let sections = ComparisonBranchMenu.sections(refs)
        #expect(sections.suggested.map(\.name) == ["None", "main"])
        #expect(sections.all.map(\.name) == ["alpha", "alpha", "beta", "beta", "zeta"])
        #expect(sections.all.map(\.detail) == ["local", "upstream", "local", "origin", "local"])
    }

    @Test("None clears the extra branch and can always be picked")
    func noneIsAlwaysAvailable() {
        let sections = ComparisonBranchMenu.sections(branches(["refs/heads/spike"]))
        #expect(sections.suggested.first?.id == "")
        #expect(sections.all.map(\.name) == ["spike"])
    }

    @Test("search filters both sections, case-insensitively, on the full ref name")
    func searchFilters() {
        let refs = branches([
            "refs/heads/main", "refs/heads/Feature/Login", "refs/remotes/origin/main",
            "refs/remotes/origin/hotfix"
        ])
        #expect(ComparisonBranchMenu.sections(refs, search: "LOG").all.map(\.name)
            == ["Feature/Login"])
        // A bare name and its remote form both find the tracked copy.
        #expect(ComparisonBranchMenu.sections(refs, search: "origin/hot").all.map(\.name)
            == ["hotfix"])
        #expect(ComparisonBranchMenu.sections(refs, search: "hot").all.map(\.name)
            == ["hotfix"])
        // None answers to its own wording.
        #expect(ComparisonBranchMenu.sections(refs, search: "none").suggested.map(\.name) == ["None"])
        #expect(ComparisonBranchMenu.sections(refs, search: "extra").suggested.map(\.name) == ["None"])
        #expect(ComparisonBranchMenu.sections(refs, search: "zzz").isEmpty)
    }

    @Test("the saved choice is a row the picker can preselect")
    func savedChoiceIsListed() {
        let refs = branches(["refs/heads/main", "refs/heads/feat/spike"])
        let sections = ComparisonBranchMenu.sections(refs)
        #expect(sections.all.map(\.id) == ["refs/heads/feat/spike"])
        #expect((sections.suggested + sections.all).first { $0.id == "refs/heads/feat/spike" } != nil)
    }

    /// Through the real parser, so the menu is fed exactly what a repository yields.
    private func branches(_ refs: [String]) -> [CleanupBranch] {
        CleanupTargets.parse(refs.map { "\($0)\u{0}sha\u{0}\u{0}" }.joined(separator: "\n")).branches
    }
}
