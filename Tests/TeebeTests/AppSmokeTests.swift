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
