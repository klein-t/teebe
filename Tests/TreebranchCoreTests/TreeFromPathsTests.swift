import Testing
import Foundation
@testable import TreebranchCore

@Suite("FileTreeBuilder.tree(fromRelativePaths:)")
struct TreeFromPathsTests {
    @Test("builds nested directories from flat paths")
    func nested() {
        let tree = FileTreeBuilder.tree(
            fromRelativePaths: ["a.txt", "src/b.swift", "src/util/c.swift"],
            rootPath: "/repo"
        )
        #expect(tree.isDirectory)
        let names = tree.children?.map(\.name)
        // Directories sort before files: src, then a.txt.
        #expect(names == ["src", "a.txt"])

        let src = tree.children?.first { $0.name == "src" }
        #expect(src?.isDirectory == true)
        let srcNames = src?.children?.map(\.name)
        #expect(srcNames == ["util", "b.swift"])

        let util = src?.children?.first { $0.name == "util" }
        #expect(util?.children?.first?.name == "c.swift")
        #expect(util?.children?.first?.isDirectory == false)
    }

    @Test("empty paths yield an empty root directory")
    func empty() {
        let tree = FileTreeBuilder.tree(fromRelativePaths: [], rootPath: "/repo")
        #expect(tree.isDirectory)
        #expect(tree.children?.isEmpty == true)
    }
}
