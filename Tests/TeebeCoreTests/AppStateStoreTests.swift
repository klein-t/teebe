import Testing
import Foundation
@testable import TeebeCore

@Suite("AppStateStore")
struct AppStateStoreTests {
    private func tempURL() -> (URL, () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tb-state-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("state.json")
        return (url, { try? FileManager.default.removeItem(at: dir) })
    }

    @Test("save then load round-trips")
    func roundTrip() throws {
        let (url, cleanup) = tempURL(); defer { cleanup() }
        let store = AppStateStore(url: url)
        let state = AppState(
            repositories: [PersistedRepository(path: "/a"),
                           PersistedRepository(path: "/b")],
            showChangedOnly: true,
            floatOnTop: true,
            lastSelectedRepoPath: "/a",
            appearance: "dark",
            cleanupTargetByRepo: ["/a": "refs/remotes/origin/dev"],
            showMergeStatus: false
        )
        try store.save(state)
        #expect(store.load() == state)
    }

    @Test("state without an appearance key decodes as follow-system")
    func appearanceDefaultsToNil() throws {
        let (url, cleanup) = tempURL(); defer { cleanup() }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let legacy = try JSONEncoder().encode(AppState(floatOnTop: true))
        var json = try #require(JSONSerialization.jsonObject(with: legacy) as? [String: Any])
        json.removeValue(forKey: "appearance")
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let loaded = AppStateStore(url: url).load()
        #expect(loaded.appearance == nil)
        #expect(loaded.floatOnTop == true)
    }

    @Test("older state defaults cleanup to automatic without losing repositories")
    func cleanupDefault() throws {
        let data = Data(#"{"repositories":[{"path":"/repo"}],"showChangedOnly":false,"showIgnored":false,"floatOnTop":true}"#.utf8)
        let decoded = try JSONDecoder().decode(AppState.self, from: data)
        #expect(decoded.cleanupTargetByRepo == nil)
        #expect(decoded.showMergeStatus == nil)
        #expect(decoded.repositories.first?.path == "/repo")
        #expect(decoded.floatOnTop)
    }

    @Test("missing file loads default state")
    func missingDefaults() {
        let (url, cleanup) = tempURL(); defer { cleanup() }
        #expect(AppStateStore(url: url).load() == AppState())
    }

    @Test("corrupt file loads default state and is kept aside instead of overwritten")
    func corruptDefaults() throws {
        let (url, cleanup) = tempURL(); defer { cleanup() }
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: url)
        let store = AppStateStore(url: url)
        #expect(store.load() == AppState())
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let kept = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix("state.json.corrupt-") }
        #expect(kept.count == 1)
        let saved = try #require(kept.first)
        #expect(try String(contentsOf: folder.appendingPathComponent(saved), encoding: .utf8) == "{ not json")
        try store.save(AppState(floatOnTop: true))
        #expect(store.load().floatOnTop)
    }
}

@Suite("PreviewResolver")
struct PreviewResolverTests {
    @Test("tracked change resolves to diff")
    func trackedDiff() {
        let change = FileChange(path: "a.swift", worktreeStatus: .modified)
        #expect(PreviewResolver.kind(forFileName: "a.swift", change: change) == .diff)
    }

    @Test("untracked text file resolves to text preview")
    func untrackedText() {
        let change = FileChange(path: "new.md", worktreeStatus: .untracked)
        #expect(PreviewResolver.kind(forFileName: "new.md", change: change) == .text)
    }

    @Test("unchanged text file resolves to text")
    func unchangedText() {
        #expect(PreviewResolver.kind(forFileName: "README.md", change: nil) == .text)
        #expect(PreviewResolver.kind(forFileName: "main.swift", change: nil) == .text)
    }

    @Test("unchanged binary file resolves to quick look")
    func binaryQuickLook() {
        #expect(PreviewResolver.kind(forFileName: "image.png", change: nil) == .quickLook)
        #expect(PreviewResolver.kind(forFileName: "movie.mov", change: nil) == .quickLook)
    }

    @Test("dotfiles and well-known names are text")
    func dotfiles() {
        #expect(PreviewResolver.isTextFile(".gitignore"))
        #expect(PreviewResolver.isTextFile("Makefile"))
        #expect(PreviewResolver.isTextFile("Package.swift"))
    }
}
