import Foundation
import Testing
import TeebeCore
@testable import Teebe

@MainActor
@Suite("File search and preferences")
struct SearchPreferencesTests {
    @Test("search takes keyboard ownership from any previous section", arguments: [AppModel.FocusSection.worktrees, .changes])
    func searchOwnsKeyboard(from section: AppModel.FocusSection) {
        let app = AppModel(environment: makeTestEnvironment())
        app.activeSection = section
        app.selector.worktree.selectionSource = .changes
        app.focusSearch()
        #expect(app.activeSection == .files)
        #expect(app.selector.worktree.selectionSource == .files)
        #expect(app.searchFocusRequest == 1)
        app.focusSearch()
        #expect(app.searchFocusRequest == 2)
    }

    @Test("saved file filters are restored and changes survive recreation")
    func fileFiltersPersist() async throws {
        let env = makeTestEnvironment()
        try env.store.save(AppState(showChangedOnly: true, showIgnored: true))
        let app = AppModel(environment: env)
        await app.bootstrap()
        #expect(app.selector.worktree.filter == .changed)
        #expect(app.selector.worktree.showIgnored)
        app.selector.worktree.filter = .all
        app.selector.worktree.showIgnored = false
        let recreated = AppModel(environment: env)
        await recreated.bootstrap()
        #expect(recreated.selector.worktree.filter == .all)
        #expect(!recreated.selector.worktree.showIgnored)
        recreated.selector.worktree.filter = .changed
        recreated.selector.worktree.showIgnored = true
        let restored = AppModel(environment: env)
        await restored.bootstrap()
        #expect(restored.selector.worktree.filter == .changed)
        #expect(restored.selector.worktree.showIgnored)
    }
    @Test("Return opens the matching result instead of a hidden previous selection")
    func returnOpensVisibleResult() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["old.txt", "result.txt"] {
            try Data(name.utf8).write(to: directory.appendingPathComponent(name))
        }
        let opener = FakeFileOpener()
        let app = AppModel(environment: makeTestEnvironment(opener: opener,
            chooseApp: { _, _, _ in URL(fileURLWithPath: "/Applications/TextEdit.app") }))
        let worktree = app.selector.worktree
        await worktree.load(worktreePath: directory.path, repo: Repository(path: directory.path))
        worktree.select(try #require(worktree.visibleRows.first { $0.node.name == "old.txt" }).node.path)
        worktree.searchQuery = "result"
        app.activateSearchResult()
        #expect(opener.opened.map(\.lastPathComponent) == ["result.txt"])
        #expect(worktree.selectedNode?.name == "result.txt")
        worktree.searchQuery = "no matches"
        app.activateSearchResult()
        #expect(opener.opened.count == 1)
    }

    @Test("entering results keeps a visible cursor and replaces a hidden one")
    func enterResults() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["first.txt", "second.txt"] {
            try Data().write(to: directory.appendingPathComponent(name))
        }
        let app = AppModel(environment: makeTestEnvironment())
        let worktree = app.selector.worktree
        await worktree.load(worktreePath: directory.path, repo: Repository(path: directory.path))
        worktree.select(try #require(worktree.visibleRows.first { $0.node.name == "second.txt" }).node.path)
        app.activeSection = .worktrees
        #expect(app.focusFileResults()?.name == "second.txt")
        #expect(app.activeSection == .files)
        worktree.searchQuery = "first"
        #expect(app.focusFileResults()?.name == "first.txt")
        worktree.searchQuery = "missing"
        #expect(app.focusFileResults() == nil)
    }

}
