import Testing
@testable import TreebranchCore

@Suite("CoreInfo")
struct CoreInfoTests {
    @Test("version is non-empty")
    func versionIsSet() {
        #expect(!TreebranchCore.version.isEmpty)
    }

    @Test("base-branch candidates are main then master")
    func baseBranchCandidates() {
        #expect(TreebranchCore.defaultBaseBranchCandidates == ["main", "master"])
    }

    @Test("configured base branch wins when it exists")
    func resolvesConfigured() {
        let resolved = TreebranchCore.resolveBaseBranch(
            configured: "develop",
            availableBranches: ["main", "develop"]
        )
        #expect(resolved == "develop")
    }

    @Test("falls back to main, then master")
    func resolvesDefaults() {
        #expect(
            TreebranchCore.resolveBaseBranch(configured: nil, availableBranches: ["master", "main"])
                == "main"
        )
        #expect(
            TreebranchCore.resolveBaseBranch(configured: nil, availableBranches: ["master", "topic"])
                == "master"
        )
    }

    @Test("returns nil when neither configured nor defaults exist")
    func resolvesNil() {
        #expect(
            TreebranchCore.resolveBaseBranch(configured: "gone", availableBranches: ["topic"]) == nil
        )
    }
}
