import Testing
@testable import Teebe

@MainActor
@Suite("Settings tab")
struct SettingsTabTests {
    @Test("Settings opens on General until a menu picks a tab")
    func defaultsToGeneral() {
        let app = AppModel(environment: makeTestEnvironment())
        #expect(app.settingsTab == .general)
    }

    @Test("A menu selects Integrations and the choice stays")
    func integrationsSelection() {
        let app = AppModel(environment: makeTestEnvironment())
        app.settingsTab = .integrations
        #expect(app.settingsTab == .integrations)
    }
}
