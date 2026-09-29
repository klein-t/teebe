import Testing
import TeebeCore

@Suite("Ignored path discovery")
struct IgnoredPathsTests {
    @Test("honors ignored directories and files while retaining tracked exceptions")
    func ignoredFiles() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile("tracked.log", "keep")
        fixture.writeFile(".gitignore", "build/\n*.log\n")
        fixture.writeFile("build/nested/output.bin", "generated")
        fixture.writeFile("debug.log", "ignored")
        fixture.writeFile("odd\nname.log", "ignored newline")
        fixture.writeFile("untracked.txt", "visible")
        let paths = try await StatusService(git: ProcessGitClient()).ignoredPaths(worktreePath: fixture.repoPath)
        #expect(Set(paths) == ["build/", "debug.log", "odd\nname.log"])
        let root = try FileTreeBuilder(rootPath: fixture.repoPath,
            options: .init(showIgnored: false, ignoredPaths: Set(paths))).buildRoot()
        #expect(root.children?.map(\.name).sorted() == [".gitignore", "tracked.log", "untracked.txt"])
    }
}
