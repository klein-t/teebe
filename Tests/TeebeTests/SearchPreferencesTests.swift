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

    @Test("saved ignored-file preference survives recreation")
    func ignoredPreferencePersists() async throws {
        let env = makeTestEnvironment()
        try env.store.save(AppState(showIgnored: true))
        let app = AppModel(environment: env)
        await app.bootstrap()
        #expect(app.selector.worktree.showIgnored)
        app.selector.worktree.showIgnored = false
        let recreated = AppModel(environment: env)
        await recreated.bootstrap()
        #expect(!recreated.selector.worktree.showIgnored)
        recreated.selector.worktree.showIgnored = true
        let restored = AppModel(environment: env)
        await restored.bootstrap()
        #expect(restored.selector.worktree.showIgnored)
    }

    @Test("legacy changed-only preferences cannot hide unchanged files", arguments: ["legacy", "global", "project"])
    func legacyChangedOnlyShowsAllFiles(scope: String) async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary.appendingPathComponent("nested"), withIntermediateDirectories: true)
        let directory = URL(fileURLWithPath: PathUtil.standardized(temporary.path))
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["changed.txt", "unchanged.txt", "nested/unchanged.swift"] {
            try Data(name.utf8).write(to: directory.appendingPathComponent(name))
        }
        let git = FakeGitClient()
        git.worktreesResult = [Worktree(path: directory.path, branch: "main", isPrimary: true)]
        git.statusResult = StatusResult(changes: [FileChange(path: "changed.txt", worktreeStatus: .modified)])
        let env = makeTestEnvironment(git: git)
        var state = AppState(repositories: [PersistedRepository(path: directory.path)],
                             showChangedOnly: true, floatOnTop: true, lastSelectedRepoPath: directory.path)
        state.lastSeenVersion = "0.7.0"
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        let savedPreferences: [String: Any] = ["changedOnly": true, "showIgnored": true, "fileSort": "recent"]
        if scope == "global" { json["defaultPreferences"] = savedPreferences }
        if scope == "project" { json["projectPreferences"] = [directory.path: savedPreferences] }
        try FileManager.default.createDirectory(at: env.store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: json).write(to: env.store.url)

        let app = AppModel(environment: env)
        await app.bootstrap()
        let files = app.selector.worktree
        #expect(Set(files.visibleRows.map(\.node.name)) == ["nested", "changed.txt", "unchanged.txt"])
        #expect(files.visibleRows.first { $0.node.name == "changed.txt" }?.node.change?.worktreeStatus == .modified)
        #expect(files.visibleRows.first { $0.node.name == "unchanged.txt" }?.node.change == nil)
        #expect(files.changes.map(\.path) == ["changed.txt"])
        #expect(files.changeGroups.flatMap(\.changes).map(\.path) == ["changed.txt"])
        #expect(files.selectCurrentOrFirstChange()?.path == "changed.txt")
        #expect(files.selectionSource == .changes)
        files.searchQuery = "nested/unchanged"
        for _ in 0..<100 where files.isSearching { try await Task.sleep(for: .milliseconds(10)) }
        #expect(files.visibleRows.map(\.node.name) == ["unchanged.swift"])
        #expect(app.floatOnTop)
        if scope != "legacy" {
            #expect(files.showIgnored)
            #expect(files.sortOrder == .recent)
        }
        app.persist()
        let saved = env.store.load()
        #expect(saved.repositories == state.repositories)
        #expect(saved.lastSeenVersion == "0.7.0")
        #expect(!saved.showChangedOnly)
        #expect(saved.floatOnTop)
        let rewritten = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: env.store.url)) as? [String: Any])
        #expect((rewritten["defaultPreferences"] as? [String: Any])?["changedOnly"] == nil)
        let projects = rewritten["projectPreferences"] as? [String: [String: Any]]
        #expect(projects?[directory.path]?["changedOnly"] == nil)
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
