import Testing
import Foundation
@testable import Teebe
import TeebeCore

@MainActor
@Suite("WhatsNewModel")
struct WhatsNewModelTests {
    private let changelog = """
    # Changelog

    ## [0.3.0] - 2026-06-24

    ### Added
    - A new thing.
    """

    private func makeStore() -> AppStateStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tb-wn-\(UUID().uuidString)")
            .appendingPathComponent("state.json")
        return AppStateStore(url: url)
    }

    @Test("parses the changelog into entries")
    func parses() {
        let model = WhatsNewModel(version: "0.3.0", changelogMarkdown: changelog, store: makeStore())
        #expect(model.entries.map(\.version) == ["0.3.0"])
        #expect(model.hasContent)
        #expect(model.displayVersion == "v0.3.0")
    }

    @Test("a fresh install is recorded as seen but not greeted with the changelog")
    func freshInstall() {
        let store = makeStore()
        let model = WhatsNewModel(version: "0.3.0", changelogMarkdown: changelog, store: store)
        model.presentIfUpdated()
        #expect(model.isPresented == false)
        #expect(store.load().lastSeenVersion == "0.3.0")
    }

    @Test("auto-presents once after an update, then records the new version")
    func presentsOnUpdate() {
        let store = makeStore()
        try? store.save(AppState(lastSeenVersion: "0.2.2"))
        let model = WhatsNewModel(version: "0.3.0", changelogMarkdown: changelog, store: store)
        model.presentIfUpdated()
        #expect(model.isPresented == true)
        #expect(store.load().lastSeenVersion == "0.3.0")
    }

    @Test("does not re-present for the same version")
    func sameVersion() {
        let store = makeStore()
        try? store.save(AppState(lastSeenVersion: "0.3.0"))
        let model = WhatsNewModel(version: "0.3.0", changelogMarkdown: changelog, store: store)
        model.presentIfUpdated()
        #expect(model.isPresented == false)
    }

    @Test("a dev build with no version never auto-presents and doesn't crash")
    func devBuild() {
        let store = makeStore()
        let model = WhatsNewModel(version: nil, changelogMarkdown: changelog, store: store)
        model.presentIfUpdated()
        #expect(model.isPresented == false)
        #expect(store.load().lastSeenVersion == nil)
        #expect(model.displayVersion == "dev build")
    }

    @Test("manual present opens it regardless of seen state")
    func manualPresent() {
        let store = makeStore()
        try? store.save(AppState(lastSeenVersion: "0.3.0"))
        let model = WhatsNewModel(version: "0.3.0", changelogMarkdown: changelog, store: store)
        model.present()
        #expect(model.isPresented == true)
    }
}
