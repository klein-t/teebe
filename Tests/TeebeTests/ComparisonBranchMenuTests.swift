import Testing
import TeebeCore
@testable import Teebe

@Suite("Comparison branch menu")
struct ComparisonBranchMenuTests {
    @Test("only plausible integration branches reach the menu")
    func filtersToIntegrationBranches() {
        let refs = branches([
            "refs/heads/main", "refs/heads/feat/row-hover", "refs/heads/staging",
            "refs/heads/release/1.2", "refs/heads/releases/2026", "refs/heads/trunk",
            "refs/heads/production", "refs/heads/prod", "refs/heads/development",
            "refs/heads/mainline", "refs/heads/devops"
        ])
        #expect(ComparisonBranchMenu.entries(refs).map(\.name)
            == ["main", "development", "prod", "production", "release/1.2",
                "releases/2026", "staging", "trunk"])
    }

    @Test("origin stands in for its local twin, and a repo with no remote keeps its own")
    func deduplicatesAgainstOrigin() {
        let withRemote = branches([
            "refs/heads/main", "refs/heads/dev", "refs/heads/staging",
            "refs/remotes/origin/main", "refs/remotes/origin/dev"
        ])
        #expect(ComparisonBranchMenu.entries(withRemote).map(\.name)
            == ["origin/main", "origin/dev", "staging"])

        let local = branches(["refs/heads/main", "refs/heads/dev"])
        #expect(ComparisonBranchMenu.entries(local).map(\.name) == ["main", "dev"])
    }

    @Test("another remote's copies stay out of the menu")
    func onlyOriginIsOffered() {
        let refs = branches(["refs/heads/main", "refs/remotes/upstream/main", "refs/remotes/upstream/dev"])
        #expect(ComparisonBranchMenu.entries(refs).map(\.name) == ["main"])
    }

    @Test("main, master, dev and develop read first; the rest are alphabetical")
    func ordering() {
        let refs = branches([
            "refs/heads/release/9", "refs/heads/develop", "refs/heads/master",
            "refs/heads/staging", "refs/heads/dev", "refs/heads/main", "refs/heads/prod"
        ])
        #expect(ComparisonBranchMenu.entries(refs).map(\.name)
            == ["main", "master", "dev", "develop", "prod", "release/9", "staging"])
    }

    @Test("the saved choice is listed even when the filter would drop it")
    func savedChoiceSurvivesTheFilter() {
        let refs = branches(["refs/heads/main", "refs/heads/feat/spike"])
        #expect(ComparisonBranchMenu.entries(refs, saved: "refs/heads/feat/spike").map(\.name)
            == ["main", "feat/spike"])
        #expect(ComparisonBranchMenu.entries(refs).map(\.name) == ["main"])
    }

    @Test("the picker suggests Automatic, then origin's integration lines, then local orphans")
    func picksSuggested() {
        let refs = branches([
            "refs/heads/main", "refs/heads/dev", "refs/heads/develop", "refs/heads/feat/x",
            "refs/remotes/origin/main", "refs/remotes/origin/dev"
        ])
        let sections = ComparisonBranchMenu.sections(refs, automatic: refs.first { $0.name == "origin/main" })
        #expect(sections.suggested.map(\.name) == ["Automatic", "main", "dev", "develop"])
        #expect(sections.suggested.map(\.detail) == ["origin/main", "origin", "origin", "local"])
        #expect(sections.suggested.map(\.id)
            == ["", "refs/remotes/origin/main", "refs/remotes/origin/dev", "refs/heads/develop"])
    }

    @Test("everything else is alphabetical, local and remote interleaved by name")
    func picksRest() {
        let refs = branches([
            "refs/heads/main", "refs/heads/zeta", "refs/heads/alpha", "refs/heads/beta",
            "refs/remotes/origin/beta", "refs/remotes/upstream/alpha"
        ])
        let sections = ComparisonBranchMenu.sections(refs, automatic: nil)
        #expect(sections.suggested.map(\.name) == ["Automatic", "main"])
        #expect(sections.all.map(\.name) == ["alpha", "alpha", "beta", "beta", "zeta"])
        #expect(sections.all.map(\.detail) == ["local", "upstream", "local", "origin", "local"])
    }

    @Test("an unresolved Automatic row says so and cannot be picked")
    func automaticUnavailable() {
        let sections = ComparisonBranchMenu.sections(branches(["refs/heads/spike"]), automatic: nil)
        #expect(sections.suggested.first?.detail == "unavailable")
        #expect(sections.suggested.first?.isEnabled == false)
        #expect(sections.all.map(\.name) == ["spike"])
    }

    @Test("search filters both sections, case-insensitively, on the full ref name")
    func searchFilters() {
        let refs = branches([
            "refs/heads/main", "refs/heads/Feature/Login", "refs/remotes/origin/main",
            "refs/remotes/origin/hotfix"
        ])
        let automatic = refs.first { $0.name == "origin/main" }
        #expect(ComparisonBranchMenu.sections(refs, automatic: automatic, search: "LOG").all.map(\.name)
            == ["Feature/Login"])
        // A bare name and its remote form both find the tracked copy.
        #expect(ComparisonBranchMenu.sections(refs, automatic: automatic, search: "origin/hot").all.map(\.name)
            == ["hotfix"])
        #expect(ComparisonBranchMenu.sections(refs, automatic: automatic, search: "hot").all.map(\.name)
            == ["hotfix"])
        // Automatic answers to its own name and to the branch it resolved to.
        #expect(ComparisonBranchMenu.sections(refs, automatic: automatic, search: "auto").suggested.map(\.name)
            == ["Automatic"])
        #expect(ComparisonBranchMenu.sections(refs, automatic: automatic, search: "zzz").isEmpty)
    }

    @Test("the saved choice is a row the picker can preselect")
    func savedChoiceIsListed() {
        let refs = branches(["refs/heads/main", "refs/heads/feat/spike"])
        let sections = ComparisonBranchMenu.sections(refs, automatic: nil)
        #expect(sections.all.map(\.id) == ["refs/heads/feat/spike"])
        #expect((sections.suggested + sections.all).first { $0.id == "refs/heads/feat/spike" } != nil)
    }

    /// Through the real parser, so the menu is fed exactly what a repository yields.
    private func branches(_ refs: [String]) -> [CleanupBranch] {
        CleanupTargets.parse(refs.map { "\($0)\u{0}sha\u{0}\u{0}" }.joined(separator: "\n")).branches
    }
}
