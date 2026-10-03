import Foundation
import Testing
import TeebeCore
@testable import Teebe

@MainActor
@Suite("Experimental notification defaults", .serialized)
struct ExperimentalNotificationDefaultsTests {
    @Test func freshProfileIsOffAndStaysOffOnRelaunch() throws {
        let environment = makeTestEnvironment()
        let fresh = AppModel(environment: environment)
        #expect(AppState().agentNotifications == nil)
        #expect(!fresh.agentNotifications)
        #expect(!fresh.selector.notificationsEnabled)
        #expect(environment.store.load().agentNotifications == nil)
        // The first launch records the running version; relaunching changes nothing.
        WhatsNewModel(version: "0.8.0", changelogMarkdown: nil, store: environment.store).presentIfUpdated()
        #expect(!AppModel(environment: environment).agentNotifications)
        #expect(environment.store.load().agentNotifications == nil)
    }

    @Test func legacyStateWithoutSavedKeyKeepsNotificationsOn() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("state.json")
        let data = Data("""
        {"repositories":[{"path":"/legacy"}],"showChangedOnly":false,
         "showIgnored":false,"floatOnTop":false,"lastSelectedRepoPath":"/legacy","terminalApp":"cmux"}
        """.utf8)
        let decoded = try JSONDecoder().decode(AppState.self, from: data)
        #expect(decoded.agentNotifications == nil)
        #expect(decoded.repositories == [PersistedRepository(path: "/legacy")])
        #expect(decoded.lastSelectedRepoPath == "/legacy")
        try data.write(to: file)
        let store = AppStateStore(url: file)
        #expect(store.load().agentNotifications == nil)
        #expect(store.load().repositories == decoded.repositories)
        #expect(store.load().lastSelectedRepoPath == "/legacy")
        let legacy = AppModel(environment: makeTestEnvironment(store: store))
        #expect(legacy.terminal == .cmux)
        #expect(legacy.agentNotifications)
        #expect(legacy.notificationSound)
        #expect(legacy.selector.notificationsEnabled)
        #expect(store.load().agentNotifications == true)
        #expect(store.load().repositories == decoded.repositories)
    }

    /// 0.7.0 and earlier always posted notifications and never saved a choice.
    @Test(arguments: ["0.7.0", "0.4.0"])
    func upgradeFromAlwaysOnVersionKeepsNotificationsOn(lastSeen: String) throws {
        let store = Self.store(lastSeenVersion: lastSeen, notifications: nil)
        let environment = makeTestEnvironment(store: store)
        let app = AppModel(environment: environment)
        #expect(app.agentNotifications)
        #expect(app.notificationSound)
        #expect(app.selector.notificationsEnabled)
        #expect(store.load().agentNotifications == true)
        #expect(store.load().notificationSound == true)
        #expect(store.load().lastSeenVersion == lastSeen)
        // Once migrated, the user's later choice is never flipped back on.
        WhatsNewModel(version: "0.8.0", changelogMarkdown: nil, store: store).presentIfUpdated()
        app.agentNotifications = false
        #expect(!AppModel(environment: environment).agentNotifications)
        #expect(store.load().agentNotifications == false)
    }

    @Test(arguments: [false, true])
    func upgradeNeverOverridesSavedChoice(enabled: Bool) throws {
        let store = Self.store(lastSeenVersion: "0.7.0", notifications: enabled, repositories: ["/repo"])
        let app = AppModel(environment: makeTestEnvironment(store: store))
        #expect(app.agentNotifications == enabled)
        #expect(store.load().agentNotifications == enabled)
    }

    @Test func profileThatAlreadyRanTheNewVersionIsNotMigrated() throws {
        let store = Self.store(lastSeenVersion: "0.8.0", notifications: nil, repositories: ["/repo"])
        let app = AppModel(environment: makeTestEnvironment(store: store))
        #expect(!app.agentNotifications)
        #expect(store.load().agentNotifications == nil)
    }

    private static func store(lastSeenVersion: String?, notifications: Bool?,
                              repositories: [String] = []) -> AppStateStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = AppStateStore(url: root.appendingPathComponent("state.json"))
        var state = AppState(repositories: repositories.map(PersistedRepository.init(path:)),
                             lastSeenVersion: lastSeenVersion)
        state.agentNotifications = notifications
        try? store.save(state)
        return store
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
