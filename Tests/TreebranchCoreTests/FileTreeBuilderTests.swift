import Testing
import Foundation
@testable import TreebranchCore

@Suite("FileTreeBuilder + StatusOverlay")
struct FileTreeBuilderTests {
    /// Create a temp directory tree and return its root path.
    private func makeTree() throws -> (root: String, cleanup: () -> Void) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("tb-tree-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "z".write(to: root.appendingPathComponent("zebra.txt"), atomically: true, encoding: .utf8)
        try "a".write(to: root.appendingPathComponent("apple.txt"), atomically: true, encoding: .utf8)
        try "h".write(to: root.appendingPathComponent(".hidden"), atomically: true, encoding: .utf8)
        try "i".write(to: root.appendingPathComponent("ignored.log"), atomically: true, encoding: .utf8)
        try "s".write(to: root.appendingPathComponent("src/main.swift"), atomically: true, encoding: .utf8)
        return (root.path, { try? fm.removeItem(at: root) })
    }

    @Test("directories sort first, then files alphabetically; .git excluded")
    func sortingAndGitExcluded() throws {
        let (root, cleanup) = try makeTree()
        defer { cleanup() }
        let builder = FileTreeBuilder(rootPath: root)
        let children = try builder.loadChildren(of: root)
        let names = children.map(\.name)
        #expect(names.contains(".git") == false)
        // src (dir) first, then files apple, ignored, zebra and .hidden among files.
        #expect(names.first == "src")
        #expect(children.first?.isDirectory == true)
    }

    @Test("children are lazy: directory nodes have nil children")
    func lazyChildren() throws {
        let (root, cleanup) = try makeTree()
        defer { cleanup() }
        let builder = FileTreeBuilder(rootPath: root)
        let children = try builder.loadChildren(of: root)
        let src = try #require(children.first { $0.name == "src" })
        #expect(src.children == nil)
        // Explicitly loading the subdirectory yields its file.
        let loaded = try builder.loadChildren(of: src.path)
        #expect(loaded.map(\.name) == ["main.swift"])
    }

    @Test("showHidden=false hides dotfiles")
    func hideHidden() throws {
        let (root, cleanup) = try makeTree()
        defer { cleanup() }
        let builder = FileTreeBuilder(rootPath: root, options: .init(showHidden: false))
        let names = try builder.loadChildren(of: root).map(\.name)
        #expect(names.contains(".hidden") == false)
    }

    @Test("ignored paths excluded unless showIgnored")
    func ignoredToggle() throws {
        let (root, cleanup) = try makeTree()
        defer { cleanup() }

        let hidden = FileTreeBuilder(rootPath: root, options: .init(showIgnored: false, ignoredPaths: ["ignored.log"]))
        #expect(try hidden.loadChildren(of: root).map(\.name).contains("ignored.log") == false)

        let shown = FileTreeBuilder(rootPath: root, options: .init(showIgnored: true, ignoredPaths: ["ignored.log"]))
        #expect(try shown.loadChildren(of: root).map(\.name).contains("ignored.log") == true)
    }

    @Test("buildRoot loads first level")
    func buildRoot() throws {
        let (root, cleanup) = try makeTree()
        defer { cleanup() }
        let node = try FileTreeBuilder(rootPath: root).buildRoot()
        #expect(node.isDirectory)
        #expect(node.children?.isEmpty == false)
    }

    // MARK: - StatusOverlay

    @Test("overlay sets change on files and containsChanges on ancestors")
    func overlayMerges() throws {
        let (root, cleanup) = try makeTree()
        defer { cleanup() }
        let builder = FileTreeBuilder(rootPath: root)
        var tree = try builder.buildRoot()
        // Expand src so its children are present for overlay.
        if let index = tree.children?.firstIndex(where: { $0.name == "src" }) {
            let srcPath = tree.children![index].path
            let srcChildren = try builder.loadChildren(of: srcPath)
            tree.children?[index].children = srcChildren
        }

        let changes = [
            FileChange(path: "apple.txt", worktreeStatus: .modified),
            FileChange(path: "src/main.swift", indexStatus: .added),
        ]
        let overlaid = StatusOverlay.apply(changes, to: tree, rootPath: root)

        let apple = overlaid.children?.first { $0.name == "apple.txt" }
        #expect(apple?.change?.worktreeStatus == .modified)

        let src = overlaid.children?.first { $0.name == "src" }
        #expect(src?.containsChanges == true)
        let main = src?.children?.first { $0.name == "main.swift" }
        #expect(main?.change?.indexStatus == .added)

        let zebra = overlaid.children?.first { $0.name == "zebra.txt" }
        #expect(zebra?.change == nil)
    }

    @Test("overlay with no changes leaves tree clean")
    func overlayNoChanges() throws {
        let (root, cleanup) = try makeTree()
        defer { cleanup() }
        let tree = try FileTreeBuilder(rootPath: root).buildRoot()
        let overlaid = StatusOverlay.apply([], to: tree, rootPath: root)
        #expect(overlaid.containsChanges == false)
        #expect(overlaid.children?.allSatisfy { $0.change == nil } == true)
    }
}
