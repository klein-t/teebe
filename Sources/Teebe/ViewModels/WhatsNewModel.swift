import Foundation
import Observation
import TeebeCore

/// Drives the "What's New" window: the parsed changelog plus the once-per-version
/// auto-present logic. Pure enough to unit-test by injecting the version, markdown,
/// and store.
@MainActor
@Observable
final class WhatsNewModel {
    private(set) var entries: [ChangelogEntry]
    var isPresented = false
    /// User-facing app version (`CFBundleShortVersionString`), or `nil` when unknown
    /// (e.g. running via `swift run`, which has no Info.plist).
    let version: String?

    private let store: AppStateStore

    init(version: String?, changelogMarkdown: String?, store: AppStateStore) {
        self.version = version
        self.entries = changelogMarkdown.map(ChangelogParser.parse) ?? []
        self.store = store
    }

    var hasContent: Bool { !entries.isEmpty }

    /// Auto-present once after an update: when the running version is newer than the
    /// version we last showed. A fresh install (no record) is *not* greeted with the
    /// changelog — it's just recorded as seen. A dev build (no version) never
    /// auto-presents. Either way the current version is marked seen so it won't
    /// re-trigger.
    func presentIfUpdated() {
        guard let version else { return }
        let lastSeen = store.load().lastSeenVersion
        if let lastSeen, SemVer.isGreater(version, than: lastSeen) {
            isPresented = true
        }
        markSeen(version)
    }

    /// Manual open (Help → What's New).
    func present() { isPresented = true }

    func dismiss() { isPresented = false }

    private func markSeen(_ version: String) {
        var state = store.load()
        guard state.lastSeenVersion != version else { return }
        state.lastSeenVersion = version
        try? store.save(state)
    }

    /// The app version read from the bundle, formatted for display ("v0.3.0"), or a
    /// dev placeholder when unknown.
    var displayVersion: String { version.map { "v\($0)" } ?? "dev build" }
}
