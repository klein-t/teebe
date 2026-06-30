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

    /// Decide whether to greet with the changelog on the first launch after an update,
    /// and record the running version as seen. Returns `true` only when the running
    /// version is newer than the one we last greeted for; a fresh install (no record)
    /// or a dev build (no version) is recorded/ignored but never greeted. The caller
    /// opens the What's New window — this model stays presentation-agnostic.
    @discardableResult
    func presentIfUpdated() -> Bool {
        guard let version else { return false }
        let lastSeen = store.load().lastSeenVersion
        let shouldGreet = lastSeen.map { SemVer.isGreater(version, than: $0) } ?? false
        markSeen(version)
        return shouldGreet
    }

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
