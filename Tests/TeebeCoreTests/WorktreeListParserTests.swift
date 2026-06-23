import Testing
@testable import TeebeCore

@Suite("WorktreeListParser")
struct WorktreeListParserTests {
    @Test("parses primary + linked worktrees")
    func parsesTwo() {
        let output = """
        worktree /repo/main
        HEAD 29350bf3dcdcf1116c07b6e9517ce6c0066b6aff
        branch refs/heads/main

        worktree /repo/wt-feature
        HEAD 29350bf3dcdcf1116c07b6e9517ce6c0066b6aff
        branch refs/heads/feature

        """
        let result = WorktreeListParser.parse(output)
        #expect(result.count == 2)

        #expect(result[0].path == "/repo/main")
        #expect(result[0].branch == "main")
        #expect(result[0].head == "29350bf3dcdcf1116c07b6e9517ce6c0066b6aff")
        #expect(result[0].isPrimary == true)

        #expect(result[1].path == "/repo/wt-feature")
        #expect(result[1].branch == "feature")
        #expect(result[1].isPrimary == false)
    }

    @Test("detached worktree has no branch")
    func detached() {
        let output = """
        worktree /repo/main
        HEAD abc123
        branch refs/heads/main

        worktree /repo/detached
        HEAD def456
        detached

        """
        let result = WorktreeListParser.parse(output)
        #expect(result.count == 2)
        #expect(result[1].isDetached == true)
        #expect(result[1].branch == nil)
    }

    @Test("bare and locked flags")
    func bareAndLocked() {
        let output = """
        worktree /repo/bare
        bare

        worktree /repo/wt
        HEAD abc
        branch refs/heads/x
        locked reason here

        """
        let result = WorktreeListParser.parse(output)
        #expect(result.count == 2)
        #expect(result[0].isBare == true)
        #expect(result[1].isLocked == true)
    }

    @Test("empty output yields no worktrees")
    func empty() {
        #expect(WorktreeListParser.parse("").isEmpty)
    }

    @Test("trailing entry without blank line still parsed")
    func noTrailingBlank() {
        let output = "worktree /repo/main\nHEAD abc\nbranch refs/heads/main"
        let result = WorktreeListParser.parse(output)
        #expect(result.count == 1)
        #expect(result[0].branch == "main")
    }
}
