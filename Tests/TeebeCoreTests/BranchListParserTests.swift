import Testing
@testable import TeebeCore

@Suite("BranchListParser")
struct BranchListParserTests {
    static let z = "\u{0}"

    @Test("parses local branches with current marker")
    func locals() {
        // Real for-each-ref output: non-current HEAD field is a space.
        let z = Self.z
        let lines = [
            "refs/heads/feature\(z)29350bf\(z)\(z) ",
            "refs/heads/main\(z)29350bf\(z)origin/main\(z)*",
        ]
        let result = BranchListParser.parse(lines.joined(separator: "\n"))
        #expect(result.count == 2)

        let feature = result.first { $0.name == "feature" }
        #expect(feature?.isCurrent == false)
        #expect(feature?.isRemote == false)
        #expect(feature?.upstream == nil)
        #expect(feature?.targetSHA == "29350bf")

        let main = result.first { $0.name == "main" }
        #expect(main?.isCurrent == true)
        #expect(main?.upstream == "origin/main")
    }

    @Test("remote branches flagged, origin/HEAD skipped")
    func remotes() {
        let z = Self.z
        let lines = [
            "refs/heads/main\(z)abc\(z)\(z)*",
            "refs/remotes/origin/main\(z)abc\(z)\(z) ",
            "refs/remotes/origin/HEAD\(z)abc\(z)\(z) ",
        ]
        let result = BranchListParser.parse(lines.joined(separator: "\n"))
        #expect(result.count == 2) // origin/HEAD filtered out
        let remote = result.first { $0.isRemote }
        #expect(remote?.name == "origin/main")
        #expect(remote?.isRemote == true)
    }

    @Test("empty output yields no branches")
    func empty() {
        #expect(BranchListParser.parse("").isEmpty)
    }
}
