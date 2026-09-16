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

    @Test("a typed branch resolves against every ref, or not at all")
    func resolvesTypedNames() {
        let refs = branches(["refs/heads/feat/spike", "refs/remotes/origin/dev"])
        #expect(ComparisonBranchMenu.resolve("feat/spike", in: refs)?.ref == "refs/heads/feat/spike")
        #expect(ComparisonBranchMenu.resolve("origin/dev", in: refs)?.ref == "refs/remotes/origin/dev")
        // A bare name means its tracked copy when that is the only one there is.
        #expect(ComparisonBranchMenu.resolve("dev", in: refs)?.ref == "refs/remotes/origin/dev")
        #expect(ComparisonBranchMenu.resolve("  origin/dev  ", in: refs)?.ref == "refs/remotes/origin/dev")
        #expect(ComparisonBranchMenu.resolve("nope", in: refs) == nil)
        #expect(ComparisonBranchMenu.resolve("   ", in: refs) == nil)
    }

    /// Through the real parser, so the menu is fed exactly what a repository yields.
    private func branches(_ refs: [String]) -> [CleanupBranch] {
        CleanupTargets.parse(refs.map { "\($0)\u{0}sha\u{0}\u{0}" }.joined(separator: "\n")).branches
    }
}
