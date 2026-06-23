import Testing
@testable import TeebeCore

@Suite("StatusParser")
struct StatusParserTests {
    /// NUL byte separating porcelain v2 -z records.
    static let z = "\u{0}"

    /// The authentic fixture captured from a real repo with a staged add, a staged
    /// rename, an unstaged delete, an unstaged modify, and an untracked file.
    static func realFixture() -> String {
        let tokens = [
            "# branch.oid 29350bf3dcdcf1116c07b6e9517ce6c0066b6aff",
            "# branch.head main",
            "1 A. N... 000000 100644 100644 0000000000000000000000000000000000000000 a17dbbc3a785c31df9f661183f747d40ae9bbbad newstaged.txt",
            "2 R. N... 100644 100644 100644 33194a0a6f3f99e366d606c24d9b1ab0e0086e69 33194a0a6f3f99e366d606c24d9b1ab0e0086e69 R100 renamed.txt",
            "torename.txt",
            "1 .D N... 100644 100644 000000 3b1bafd0868f8236dbe5c12715e7536123af73f0 3b1bafd0868f8236dbe5c12715e7536123af73f0 todelete.txt",
            "1 .M N... 100644 100644 100644 83db48f84ec878fbfb30b46d16630e944e34f205 83db48f84ec878fbfb30b46d16630e944e34f205 tracked.txt",
            "? untracked.txt",
        ]
        return tokens.joined(separator: z) + z
    }

    @Test("parses branch + all change kinds from real fixture")
    func realFixtureParses() {
        let result = StatusParser.parse(Self.realFixture())
        #expect(result.branch == "main")
        #expect(result.isDetached == false)
        #expect(result.oid == "29350bf3dcdcf1116c07b6e9517ce6c0066b6aff")
        #expect(result.changes.count == 5)

        let byPath = Dictionary(uniqueKeysWithValues: result.changes.map { ($0.path, $0) })

        #expect(byPath["newstaged.txt"]?.indexStatus == .added)
        #expect(byPath["newstaged.txt"]?.worktreeStatus == .unmodified)
        #expect(byPath["newstaged.txt"]?.isStaged == true)

        #expect(byPath["renamed.txt"]?.indexStatus == .renamed)
        #expect(byPath["renamed.txt"]?.originalPath == "torename.txt")

        #expect(byPath["todelete.txt"]?.worktreeStatus == .deleted)
        #expect(byPath["todelete.txt"]?.indexStatus == .unmodified)

        #expect(byPath["tracked.txt"]?.worktreeStatus == .modified)
        #expect(byPath["tracked.txt"]?.primaryStatus == .modified)

        #expect(byPath["untracked.txt"]?.worktreeStatus == .untracked)
        #expect(byPath["untracked.txt"]?.isUntracked == true)
    }

    @Test("ahead/behind + upstream parsed")
    func aheadBehind() {
        let tokens = [
            "# branch.oid abcdef",
            "# branch.head main",
            "# branch.upstream origin/main",
            "# branch.ab +3 -2",
        ]
        let result = StatusParser.parse(tokens.joined(separator: Self.z) + Self.z)
        #expect(result.branch == "main")
        #expect(result.upstream == "origin/main")
        #expect(result.ahead == 3)
        #expect(result.behind == 2)
        #expect(result.changes.isEmpty)
    }

    @Test("detached head")
    func detached() {
        let tokens = ["# branch.oid abcdef", "# branch.head (detached)"]
        let result = StatusParser.parse(tokens.joined(separator: Self.z) + Self.z)
        #expect(result.isDetached == true)
        #expect(result.branch == nil)
    }

    @Test("initial commit has nil oid")
    func initialOid() {
        let tokens = ["# branch.oid (initial)", "# branch.head main"]
        let result = StatusParser.parse(tokens.joined(separator: Self.z) + Self.z)
        #expect(result.oid == nil)
    }

    @Test("staged + unstaged modify (MM)")
    func stagedAndUnstaged() {
        let token = "1 MM N... 100644 100644 100644 aaa bbb both.txt"
        let result = StatusParser.parse("# branch.head main" + Self.z + token + Self.z)
        let change = result.changes.first
        #expect(change?.indexStatus == .modified)
        #expect(change?.worktreeStatus == .modified)
        #expect(change?.isStaged == true)
    }

    @Test("unmerged entry is conflicted")
    func unmerged() {
        let token = "u UU N... 100644 100644 100644 100644 h1 h2 h3 conflict.txt"
        let result = StatusParser.parse(token + Self.z)
        #expect(result.changes.first?.isConflicted == true)
    }

    @Test("empty output yields empty result")
    func empty() {
        let result = StatusParser.parse("")
        #expect(result.changes.isEmpty)
        #expect(result.branch == nil)
    }
}
