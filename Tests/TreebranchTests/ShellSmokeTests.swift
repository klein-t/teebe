import Testing
import SwiftUI
import Foundation
@testable import Treebranch
import TreebranchCore

@MainActor
@Suite("Shell smoke")
struct ShellSmokeTests {
    @Test("double-click action opens the file via the opener (D1)")
    func openCallsOpener() {
        let opener = FakeFileOpener()
        let app = AppModel(environment: makeTestEnvironment(opener: opener))
        let node = FileNode(path: "/repo/a.swift", isDirectory: false)
        app.open(node)
        #expect(opener.opened.map(\.path) == ["/repo/a.swift"])
    }

    @Test("opening a directory is a no-op")
    func openDirectoryNoop() {
        let opener = FakeFileOpener()
        let app = AppModel(environment: makeTestEnvironment(opener: opener))
        app.open(FileNode(path: "/repo/src", isDirectory: true))
        #expect(opener.opened.isEmpty)
    }

    @Test("reveal calls the opener's reveal")
    func revealCallsOpener() {
        let opener = FakeFileOpener()
        let app = AppModel(environment: makeTestEnvironment(opener: opener))
        app.reveal(FileNode(path: "/repo/a.swift", isDirectory: false))
        #expect(opener.revealed.map(\.path) == ["/repo/a.swift"])
    }

    @Test("main + panel views construct without crashing")
    func viewsConstruct() {
        let env = makeTestEnvironment()
        let app = AppModel(environment: env)
        let preview = PreviewModel(environment: env)
        _ = RootView(app: app, preview: preview)
        _ = PreviewPanel(preview: preview, app: app)
        _ = DiffContentView(file: DiffFile(newPath: "a.txt"))
        _ = FileRowsView(app: app, preview: preview)
    }
}
