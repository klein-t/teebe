import Foundation
import Testing
import TeebeCore
@testable import Teebe

@MainActor
@Suite("Global defaults and project overrides")
struct ProjectPreferencesTests {
    @Test func fieldOverridesSurviveDefaultChangesAndReset() {
        let prefs = PreferencesModel(state: AppState(showIgnored: true))
        prefs.repositoryPath = "/a"
        prefs.set(\.showIgnored, false)
        prefs.defaults.fileSort = "recent"
        #expect(prefs.effective.showIgnored == false)
        #expect(prefs.effective.fileSort == "recent")
        prefs.repositoryPath = "/b"
        #expect(prefs.effective.showIgnored == true)
        #expect(prefs.effective.fileSort == "recent")
        prefs.repositoryPath = "/a"
        prefs.reset()
        #expect(prefs.effective.showIgnored == true)
        #expect(!prefs.hasOverrides)
    }

    @Test func switchingProjectsRestoresFiltersWithoutChangingDefaults() async throws {
        let env = makeTestEnvironment()
        let app = AppModel(environment: env)
        await app.selector.selectRepo(Repository(path: "/a"))
        app.selector.worktree.showIgnored = true
        app.selector.worktree.sortOrder = .recent
        app.groupWorktreesByMergeStatus = true
        #expect(app.preferences.defaults.showIgnored == false)
        await app.selector.selectRepo(Repository(path: "/b"))
        #expect(!app.selector.worktree.showIgnored)
        #expect(app.selector.worktree.sortOrder == .name)
        #expect(!app.groupWorktreesByMergeStatus)
        app.preferences.defaults.changedOnly = true
        let restored = AppModel(environment: env)
        await restored.selector.selectRepo(Repository(path: "/a"))
        #expect(restored.selector.worktree.showIgnored)
        #expect(restored.selector.worktree.sortOrder == .recent)
        #expect(restored.groupWorktreesByMergeStatus)
        #expect(restored.selector.worktree.filter == .changed)
        restored.preferences.reset()
        #expect(!restored.selector.worktree.showIgnored)
        #expect(restored.selector.worktree.filter == .changed)
    }

    @Test func explicitNoComparisonOverridesDefaultAndLegacyMigrates() {
        var state = AppState(cleanupTargetByRepo: ["/a": "refs/heads/release"], worktreeParentByRepo: ["/a": "/work"])
        state.defaultPreferences = ProjectPreferences(comparisonRef: "refs/heads/dev")
        let prefs = PreferencesModel(state: state)
        prefs.repositoryPath = "/a"
        #expect(prefs.effective.comparisonRef == "refs/heads/release")
        #expect(prefs.effective.worktreeParent == "/work")
        prefs.setComparison(nil, for: "/a")
        #expect(prefs.effective.comparisonRef == "")
        prefs.reset()
        #expect(prefs.effective.comparisonRef == "refs/heads/dev")
    }

    @Test func openingUsesSystemThenGlobalTypeThenProjectOverride() throws {
        let opener = FakeFileOpener()
        let env = makeTestEnvironment(opener: opener, chooseApp: { _, _, _ in URL(fileURLWithPath: "/Project.app") })
        let model = OpenWithModel(environment: env, apps: [".md": "/Global.app"])
        model.repositoryPath = "/a"
        try model.open(URL(fileURLWithPath: "/a/picture.png"))
        #expect(opener.apps.last == .some(nil))
        let file = URL(fileURLWithPath: "/a/readme.md")
        try model.open(file)
        #expect(opener.apps.last??.path == "/Global.app")
        try model.chooseAndOpen(file)
        try model.open(file)
        #expect(opener.apps.last??.path == "/Project.app")
        #expect(model.apps[".md"] == "/Global.app")
        model.repositoryPath = "/b"
        try model.open(file)
        #expect(opener.apps.last??.path == "/Global.app")
    }

    @Test func terminalPathsAreLiteralArguments() {
        let path = "/tmp/project with spaces; echo test"
        #expect(TerminalChoice.cmux.arguments(at: path) == ["new-workspace", "--cwd", path, "--focus", "true"])
        #expect(TerminalChoice.terminal.arguments(at: path) == ["-a", "Terminal", path])
    }

    @Test func manualFetchFailureCanBeRetried() async {
        let git = FakeGitClient()
        git.worktreesResult = [Worktree(path: "/a", branch: "main", isPrimary: true)]
        let app = AppModel(environment: makeTestEnvironment(git: git))
        await app.selector.selectRepo(Repository(path: "/a"))
        git.fetchError = .executableNotFound
        await app.refreshRemotes(force: true)
        #expect(app.fetchError != nil)
        #expect(!app.isFetching)
        git.fetchError = nil
        await app.refreshRemotes(force: true)
        #expect(app.fetchError == nil)
    }
}
