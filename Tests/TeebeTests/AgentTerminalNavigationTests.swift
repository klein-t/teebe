import Foundation
import Testing
import TeebeCore
@testable import Teebe

@MainActor
@Suite("Agent click destination")
struct AgentTerminalNavigationTests {
    @Test("old state and unknown values default to its terminal; both choices round-trip")
    func persistence() throws {
        let old = Data(#"{"repositories":[],"showChangedOnly":false,"showIgnored":false,"floatOnTop":false}"#.utf8)
        var state = try JSONDecoder().decode(AppState.self, from: old)
        #expect(AgentDisplayPreferences(state: state).clickDestination == .terminal)
        state.agentClickDestination = "future-value"
        #expect(AgentDisplayPreferences(state: state).clickDestination == .terminal)
        let prefs = AgentDisplayPreferences(state: state)
        var changes = 0
        prefs.onChange = { changes += 1 }
        for destination in [AgentClickDestination.teebe, .terminal] {
            prefs.clickDestination = destination
            prefs.write(to: &state)
            let decoded = try JSONDecoder().decode(AppState.self, from: JSONEncoder().encode(state))
            #expect(AgentDisplayPreferences(state: decoded).clickDestination == destination)
        }
        #expect(changes == 2)
    }

    @Test("a verified terminal keeps teebe's selection; all fallback paths select the clicked worktree", arguments: 0..<5)
    func click(kind: Int) async {
        let git = FakeGitClient()
        git.worktreesResult = [Worktree(path: "/repo", branch: "main", isPrimary: true),
                              Worktree(path: "/repo-feature", branch: "feature")]
        let app = AppModel(environment: makeTestEnvironment(git: git))
        await app.selector.selectRepo(Repository(path: "/repo"))
        let overview = AgentOverviewModel(app: app)
        let session = AgentTerminalSession(provider: .codex, id: "one-exact-session", transcriptPath: "/logs/one.jsonl")
        var context = AgentContext(state: .needsAttention, terminalSession: session)
        if kind == 2 { app.agentDisplay.clickDestination = .teebe }
        if kind == 3 { context.terminalSession = nil }
        let entry = AgentOverviewModel.Entry(repoPath: "/repo", repoTitle: "Repo", worktreePath: "/repo-feature",
            name: "feature", state: kind == 4 ? .idle : .needsAttention, context: context)
        var terminalCalls: [AgentTerminalSession] = []
        var windowCalls = 0
        overview.openMainWindow = { windowCalls += 1 }
        overview.openTerminalSession = { terminalCalls.append($0); return kind == 0 }
        await overview.open(entry)
        #expect(terminalCalls == (kind <= 1 ? [session] : []))
        #expect(windowCalls == (kind == 0 ? 0 : 1))
        #expect(app.selector.selectedWorktree?.path == (kind == 0 ? "/repo" : "/repo-feature"))
        app.selector.clearSelection()
    }

    @Test("fallback switches to the row's repository, even when another project is open")
    func switchesRepository() async {
        let git = FakeGitClient()
        let environment = makeTestEnvironment(git: git)
        let app = AppModel(environment: environment)
        _ = await app.addRepository(path: "/second")
        await app.selector.selectRepo(Repository(path: "/first"))
        git.worktreesResult = [Worktree(path: "/second", branch: "main", isPrimary: true),
                              Worktree(path: "/second-feature", branch: "feature")]
        let overview = AgentOverviewModel(app: app)
        overview.openMainWindow = {}
        await overview.open(AgentOverviewModel.Entry(repoPath: "/second", repoTitle: "Second", worktreePath: "/second-feature",
                                                     name: "feature", state: .working, context: nil))
        #expect(app.selector.selectedRepo?.path == "/second")
        #expect(app.selector.selectedWorktree?.path == "/second-feature")
        app.selector.clearSelection()
    }
}
