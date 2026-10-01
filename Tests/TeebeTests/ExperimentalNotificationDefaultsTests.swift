import Foundation
import Testing
import TeebeCore
@testable import Teebe

@MainActor
@Suite("Experimental notification defaults", .serialized)
struct ExperimentalNotificationDefaultsTests {
    @Test func freshProfileAndMissingSavedKeyAreOff() throws {
        let fresh = AppModel(environment: makeTestEnvironment())
        #expect(AppState().agentNotifications == nil)
        #expect(!fresh.agentNotifications)
        #expect(!fresh.selector.notificationsEnabled)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("state.json")
        try Data("{}".utf8).write(to: file)
        let store = AppStateStore(url: file)
        #expect(store.load().agentNotifications == nil)
        let legacy = AppModel(environment: makeTestEnvironment(store: store))
        #expect(!legacy.agentNotifications)
        #expect(!legacy.selector.notificationsEnabled)
    }

    @Test(arguments: [false, true])
    func explicitSavedPreferenceSurvivesLoadingAndPersistence(enabled: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStateStore(url: root.appendingPathComponent("state.json"))
        var state = AppState()
        state.agentNotifications = enabled
        try store.save(state)
        let environment = makeTestEnvironment(store: store)
        let app = AppModel(environment: environment)
        #expect(app.agentNotifications == enabled)
        #expect(app.selector.notificationsEnabled == enabled)
        app.notificationSound.toggle() // An unrelated preference persists the loaded choice.
        let reloaded = AppModel(environment: environment)
        #expect(reloaded.agentNotifications == enabled)
        #expect(store.load().agentNotifications == enabled)
    }

    @Test(arguments: [false, true])
    func defaultSelectorsAndAppProfilesSuppressBothNotificationSources(journal: Bool) async {
        let git = FakeGitClient()
        git.worktreesResult = [Worktree(path: "/repo", branch: "feature", isPrimary: true)]
        let states = FakeAgentStates()
        let spy = NotificationSpy()
        let endings = DefaultNotificationEndings()
        let environment = makeTestEnvironment(git: git, agentStatuses: states.provider,
            agentTurnEnds: endings.provider,
            notify: spy.record)
        let selector = SelectorModel(environment: environment)
        let app = AppModel(environment: environment)
        #expect(!selector.notificationsEnabled)
        #expect(!app.agentNotifications)
        for model in [selector, app.selector] {
            endings.set([])
            states["/repo"] = .idle
            await model.selectRepo(Repository(path: "/repo"))
            if journal {
                endings.set([AgentTurnEnd(id: UUID().uuidString, worktreePath: "/repo", endedAt: Date())])
            } else {
                states["/repo"] = .working
                await model.refreshAgentStates()
                states["/repo"] = .needsAttention
            }
            await model.refreshAgentStates()
            model.clearSelection()
        }
        #expect(spy.posted.isEmpty)
    }
}

private final class DefaultNotificationEndings: @unchecked Sendable {
    private let lock = NSLock()
    private var endings: [AgentTurnEnd] = []
    func set(_ values: [AgentTurnEnd]) { lock.withLock { endings = values } }
    @Sendable func provider(_ paths: [String], _ now: Date) -> [AgentTurnEnd] { lock.withLock { endings } }
}
