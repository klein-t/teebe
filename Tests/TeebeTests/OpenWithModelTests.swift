import Testing
import Foundation
@testable import Teebe
import TeebeCore

/// Records every chooser request and answers from a script.
@MainActor
private final class ChooserScript {
    var answers: [URL?]
    private(set) var requests: [(file: URL?, typeKey: String, current: URL?)] = []
    init(_ answers: [URL?]) { self.answers = answers }
    var choose: @MainActor (URL?, String, URL?) -> URL? {
        { [self] file, key, current in
            requests.append((file, key, current))
            return answers.isEmpty ? nil : answers.removeFirst()
        }
    }
}

private let xcode = URL(fileURLWithPath: "/Applications/Xcode.app")
private let zed = URL(fileURLWithPath: "/Applications/Zed.app")

@MainActor
@Suite("Open with the remembered app")
struct OpenWithModelTests {
    private func makeApp(_ chooser: ChooserScript, opener: FakeFileOpener = FakeFileOpener(),
                         store: AppStateStore? = nil,
                         appExists: @escaping @Sendable (URL) -> Bool = { _ in true }) -> AppModel {
        AppModel(environment: makeTestEnvironment(opener: opener, store: store,
                                                  chooseApp: chooser.choose, appExists: appExists))
    }

    @Test("the first open of a type asks, opens with the choice, and remembers it")
    func firstOpenAsks() {
        let chooser = ChooserScript([xcode])
        let opener = FakeFileOpener()
        let app = makeApp(chooser, opener: opener)
        app.open(FileNode(path: "/r/a.swift", isDirectory: false))
        #expect(chooser.requests.count == 1)
        #expect(chooser.requests.first?.file?.path == "/r/a.swift")
        #expect(chooser.requests.first?.typeKey == ".swift")
        #expect(opener.opened.map(\.path) == ["/r/a.swift"])
        #expect(opener.apps == [xcode])
        #expect(app.openWith.apps == [".swift": xcode.path])
    }

    @Test("later opens of the same type go straight to the remembered app")
    func laterOpensSkipChooser() {
        let chooser = ChooserScript([xcode])
        let opener = FakeFileOpener()
        let app = makeApp(chooser, opener: opener)
        app.open(FileNode(path: "/r/a.swift", isDirectory: false))
        app.open(FileNode(path: "/r/sub/B.SWIFT", isDirectory: false))
        #expect(chooser.requests.count == 1)
        #expect(opener.apps == [xcode, xcode])
    }

    @Test("canceling the chooser opens nothing and remembers nothing")
    func cancelOpensNothing() {
        let chooser = ChooserScript([nil])
        let opener = FakeFileOpener()
        let app = makeApp(chooser, opener: opener)
        app.open(FileNode(path: "/r/a.md", isDirectory: false))
        #expect(opener.opened.isEmpty)
        #expect(app.openWith.apps.isEmpty)
    }

    @Test("a remembered app that no longer exists asks again")
    func missingAppAsksAgain() {
        let chooser = ChooserScript([xcode, zed])
        let opener = FakeFileOpener()
        let app = makeApp(chooser, opener: opener, appExists: { $0 != xcode })
        app.open(FileNode(path: "/r/a.swift", isDirectory: false))
        app.open(FileNode(path: "/r/b.swift", isDirectory: false))
        #expect(chooser.requests.count == 2)
        #expect(chooser.requests.last?.current == nil)
        #expect(opener.apps == [xcode, zed])
        #expect(app.openWith.apps == [".swift": zed.path])
    }

    @Test("Open With… always asks, preselects the current app, and replaces it")
    func openWithReplaces() {
        let chooser = ChooserScript([xcode, zed])
        let opener = FakeFileOpener()
        let app = makeApp(chooser, opener: opener)
        app.open(FileNode(path: "/r/a.swift", isDirectory: false))
        app.openWith(FileNode(path: "/r/a.swift", isDirectory: false))
        #expect(chooser.requests.last?.current == xcode)
        #expect(opener.apps == [xcode, zed])
        #expect(app.openWith.apps == [".swift": zed.path])
    }

    @Test("Settings: change, forget one type, forget all")
    func settingsActions() {
        let chooser = ChooserScript([xcode, zed, zed])
        let app = makeApp(chooser)
        app.open(FileNode(path: "/r/a.swift", isDirectory: false))
        app.open(FileNode(path: "/r/Makefile", isDirectory: false))
        #expect(app.openWith.entries.map(\.typeName) == [".swift", "Makefile"])

        app.openWith.changeApp(forType: ".swift")
        #expect(chooser.requests.last?.file == nil)
        #expect(chooser.requests.last?.current == xcode)
        #expect(app.openWith.apps[".swift"] == zed.path)

        app.openWith.forget(type: ".swift")
        #expect(app.openWith.entries.map(\.typeKey) == ["makefile"])
        app.openWith.forgetAll()
        #expect(app.openWith.entries.isEmpty)
    }

    @Test("canceling Change… keeps the current app")
    func changeCancelKeeps() {
        let chooser = ChooserScript([xcode, nil])
        let app = makeApp(chooser)
        app.open(FileNode(path: "/r/a.swift", isDirectory: false))
        app.openWith.changeApp(forType: ".swift")
        #expect(app.openWith.apps[".swift"] == xcode.path)
    }

    @Test("remembered apps survive a relaunch")
    func persists() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tb-openwith-\(UUID().uuidString)").appendingPathComponent("state.json")
        let first = makeApp(ChooserScript([xcode]), store: AppStateStore(url: url))
        first.open(FileNode(path: "/r/a.swift", isDirectory: false))

        let chooser = ChooserScript([])
        let opener = FakeFileOpener()
        let second = makeApp(chooser, opener: opener, store: AppStateStore(url: url))
        second.open(FileNode(path: "/r/b.swift", isDirectory: false))
        #expect(chooser.requests.isEmpty)
        #expect(opener.apps == [xcode])

        second.openWith.forgetAll()
        #expect(AppStateStore(url: url).load().openWithApps == nil)
    }
}
