import Testing
@testable import Teebe

@MainActor
@Suite("App smoke")
struct AppSmokeTests {
    @Test("root view constructs")
    func rootViewConstructs() {
        let env = makeTestEnvironment()
        let app = AppModel(environment: env)
        let preview = PreviewModel(environment: env)
        _ = RootView(app: app, preview: preview)
    }
}

@MainActor
@Suite("Hook setup decision")
struct HookSetupActionTests {
    @Test("already installed does nothing regardless of the stored answer",
          arguments: [nil, "accepted", "declined"] as [String?])
    func installedIsNone(response: String?) {
        #expect(AppModel.hookSetupAction(installed: true, response: response) == .none)
    }

    @Test("never asked and missing asks once")
    func asksWhenFresh() {
        #expect(AppModel.hookSetupAction(installed: false, response: nil) == .ask)
    }

    @Test("accepted but missing repairs silently")
    func repairsWhenAccepted() {
        #expect(AppModel.hookSetupAction(installed: false, response: "accepted") == .repair)
    }

    @Test("declined never touches the settings and never re-asks")
    func declinedStaysDeclined() {
        #expect(AppModel.hookSetupAction(installed: false, response: "declined") == .none)
    }
}
