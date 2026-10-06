import Testing
import Foundation
@testable import Teebe
import TeebeCore

@MainActor
@Suite("Arrow keys while peeking")
struct PeekNavigationTests {
    /// a.txt, src/ (with b.txt), z.txt
    private func tempTree() -> (String, () -> Void) {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("tb-peek-\(UUID().uuidString)")
        try? fm.createDirectory(at: dir.appendingPathComponent("src"), withIntermediateDirectories: true)
        try? "a".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try? "b".write(to: dir.appendingPathComponent("src/b.txt"), atomically: true, encoding: .utf8)
        try? "z".write(to: dir.appendingPathComponent("z.txt"), atomically: true, encoding: .utf8)
        return (dir.path, { try? fm.removeItem(at: dir) })
    }

    @Test("key codes map to arrows; other keys don't")
    func keyCodes() {
        #expect(PeekArrow(keyCode: 125) == .down)
        #expect(PeekArrow(keyCode: 126) == .up)
        #expect(PeekArrow(keyCode: 123) == .left)
        #expect(PeekArrow(keyCode: 124) == .right)
        #expect(PeekArrow(keyCode: 49) == nil)   // space
    }

    @Test("FILES: ↓/↑ step through visible rows, folders included, and stop at the ends")
    func filesUpDown() async throws {
        let (dir, cleanup) = tempTree(); defer { cleanup() }
        let model = WorktreeModel(environment: makeTestEnvironment())
        await model.load(worktreePath: dir, repo: Repository(path: dir))
        let names = model.visibleRows.map(\.node.name)
        model.select(try #require(model.visibleRows.first).node.path)

        var visited = [model.selectedNode?.name]
        for _ in 0..<names.count + 1 { visited.append(model.stepPeek(.down, in: .files)?.name) }
        #expect(Array(visited.prefix(names.count)).compactMap { $0 } == names)
        #expect(visited.last == names.last)   // no wrap
        #expect(names.contains("src"))

        for _ in 0..<names.count + 1 { _ = model.stepPeek(.up, in: .files) }
        #expect(model.selectedNode?.name == names.first)
        #expect(model.selectionSource == .files)
    }

    @Test("FILES: → expands a folder and ← collapses it, the peek staying on it")
    func filesLeftRight() async throws {
        let (dir, cleanup) = tempTree(); defer { cleanup() }
        let model = WorktreeModel(environment: makeTestEnvironment())
        await model.load(worktreePath: dir, repo: Repository(path: dir))
        let src = try #require(model.visibleRows.first { $0.node.name == "src" }).node
        model.select(src.path)

        #expect(model.stepPeek(.right, in: .files)?.name == "src")
        #expect(model.isExpanded(src))
        #expect(model.stepPeek(.down, in: .files)?.name == "b.txt")
        #expect(model.stepPeek(.left, in: .files)?.name == "src")
        #expect(model.stepPeek(.left, in: .files)?.name == "src")
        #expect(!model.isExpanded(src))
    }

    @Test("CHANGES: ↓/↑ step through changes and stop at the ends; ←/→ do nothing")
    func changes() async throws {
        let (dir, cleanup) = tempTree(); defer { cleanup() }
        let git = FakeGitClient()
        git.statusResult = StatusResult(changes: [
            FileChange(path: "a.txt", worktreeStatus: .modified),
            FileChange(path: "src/b.txt", worktreeStatus: .modified)
        ])
        let model = WorktreeModel(environment: makeTestEnvironment(git: git))
        await model.load(worktreePath: dir, repo: Repository(path: dir))
        model.selectCurrentOrFirstChange()
        let paths = model.changes.map { dir + "/" + $0.path }

        let next = try #require(model.stepPeek(.down, in: .changes))
        #expect(next.path == paths[1])
        #expect(next.change != nil)
        #expect(model.stepPeek(.down, in: .changes)?.path == paths[1])   // no wrap
        #expect(model.selectedPath == paths[1])
        #expect(model.stepPeek(.right, in: .changes) == nil)
        #expect(model.selectedPath == paths[1])
        #expect(model.stepPeek(.up, in: .changes)?.path == paths[0])
        #expect(model.stepPeek(.up, in: .changes)?.path == paths[0])
    }
}
