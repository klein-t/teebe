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
            lastSelectedRepoPath: "/a"
        )
        try store.save(state)
        #expect(store.load() == state)
    }

    @Test("missing file loads default state")
    func missingDefaults() {
        let (url, cleanup) = tempURL(); defer { cleanup() }
        #expect(AppStateStore(url: url).load() == AppState())
    }

    @Test("corrupt file loads default state")
    func corruptDefaults() throws {
        let (url, cleanup) = tempURL(); defer { cleanup() }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{ not json".data(using: .utf8)!.write(to: url)
        #expect(AppStateStore(url: url).load() == AppState())
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
