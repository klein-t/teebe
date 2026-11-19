import Foundation
import Testing
@testable import TeebeCore

/// `git diff -w` against real throwaway repositories.
@Suite("Ignore whitespace (integration)")
struct IgnoreWhitespaceDiffTests {
    let git = ProcessGitClient()

    @Test("ignoring whitespace drops whitespace-only lines and keeps real edits")
    func mixedChange() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile("a.swift", "func a() {\n    return 1\n}\nlet b = 2\n")
        fixture.writeFile("a.swift", "func a() {\n        return 1\n}\nlet b = 3\n")

        let full = try #require(try await git.workingDiff(worktreePath: fixture.repoPath, path: "a.swift",
                                                          staged: false, ignoreWhitespace: false))
        #expect(full.addedCount == 2)
        let ignored = try #require(try await git.workingDiff(worktreePath: fixture.repoPath, path: "a.swift",
                                                             staged: false, ignoreWhitespace: true))
        #expect(ignored.addedCount == 1)
        #expect(ignored.hunks.flatMap(\.lines).contains { $0.kind == .addition && $0.content == "let b = 3" })
        #expect(!ignored.onlyWhitespaceChanged)
    }

    @Test("a whitespace-only change says so instead of reading as no diff")
    func whitespaceOnly() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile("a.py", "def a():\n    return 1\n")
        fixture.writeFile("a.py", "def a():\n\treturn 1  \n")
        let service = DiffService(git: git)
        let change = FileChange(path: "a.py", worktreeStatus: .modified)

        let full = try #require(try await service.diff(for: change, worktreePath: fixture.repoPath))
        #expect(full.addedCount == 1 && !full.onlyWhitespaceChanged)

        let ignored = try #require(try await service.diff(for: change, worktreePath: fixture.repoPath,
                                                          ignoringWhitespace: true))
        #expect(ignored.onlyWhitespaceChanged)
        #expect(ignored.hunks.isEmpty)
        #expect(ignored.displayPath == "a.py")
    }

    @Test("the staged diff honors the option too")
    func staged() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile("a.json", "{\n  \"a\": 1\n}\n")
        fixture.writeFile("a.json", "{\n    \"a\": 1\n}\n")
        fixture.git(["add", "a.json"])
        let service = DiffService(git: git)
        let change = FileChange(path: "a.json", indexStatus: .modified, worktreeStatus: .unmodified)

        let ignored = try #require(try await service.diff(for: change, worktreePath: fixture.repoPath,
                                                          ignoringWhitespace: true))
        #expect(ignored.onlyWhitespaceChanged)
    }

    @Test("an untouched file stays no diff at all")
    func noChange() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile("a.md", "# A\n")
        let diff = try await DiffService(git: git).diff(
            for: FileChange(path: "a.md", worktreeStatus: .modified), worktreePath: fixture.repoPath,
            ignoringWhitespace: true)
        #expect(diff == nil)
    }
}
