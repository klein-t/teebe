import Foundation

/// A persisted repository entry (just its path). No secrets.
public struct PersistedRepository: Codable, Equatable, Sendable {
    public var path: String

    public init(path: String) {
        self.path = path
    }
}

/// Per-repository accordion layout: which sections are open and the window height
/// to restore. Remembered so reopening a project looks the way you left it.
public struct SectionLayout: Codable, Equatable, Sendable {
    public var worktreesOpen: Bool
    public var changesOpen: Bool
    public var filesOpen: Bool
    public var windowHeight: Double

    public init(
        worktreesOpen: Bool = true,
        changesOpen: Bool = true,
        filesOpen: Bool = true,
        windowHeight: Double = 640
    ) {
        self.worktreesOpen = worktreesOpen
        self.changesOpen = changesOpen
        self.filesOpen = filesOpen
        self.windowHeight = windowHeight
    }
}

/// The app's persisted state: added repos, view preferences, last selection
/// (TECH_SPEC §10). Serialized to JSON; nothing sensitive.
public struct AppState: Codable, Equatable, Sendable {
    public var repositories: [PersistedRepository]
    public var showChangedOnly: Bool
    public var showIgnored: Bool
    public var floatOnTop: Bool
    public var lastSelectedRepoPath: String?
    public var lastSelectedWorktreePath: String?
    /// Accordion layout keyed by repository path. Optional so older state files
    /// (without this key) still decode instead of resetting everything.
    public var layoutByRepo: [String: SectionLayout]?
    /// The app version we last showed the "What's New" window for. Optional so older
    /// state files decode; `nil` means "never shown" (treated as a fresh install).
    public var lastSeenVersion: String?

    public init(
        repositories: [PersistedRepository] = [],
        showChangedOnly: Bool = false,
        showIgnored: Bool = false,
        floatOnTop: Bool = false,
        lastSelectedRepoPath: String? = nil,
        lastSelectedWorktreePath: String? = nil,
        layoutByRepo: [String: SectionLayout]? = nil,
        lastSeenVersion: String? = nil
    ) {
        self.repositories = repositories
        self.showChangedOnly = showChangedOnly
        self.showIgnored = showIgnored
        self.floatOnTop = floatOnTop
        self.lastSelectedRepoPath = lastSelectedRepoPath
        self.lastSelectedWorktreePath = lastSelectedWorktreePath
        self.layoutByRepo = layoutByRepo
        self.lastSeenVersion = lastSeenVersion
    }
}

/// Reads/writes `AppState` as JSON. Defaults to
/// `~/Library/Application Support/teebe/state.json`; the location is
/// injectable for tests.
public final class AppStateStore: @unchecked Sendable {
    public let url: URL

    public init(url: URL? = nil) {
        self.url = url ?? Self.defaultURL
    }

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("teebe", isDirectory: true)
            .appendingPathComponent("state.json")
    }

    /// Load persisted state, returning a default `AppState` when the file is
    /// missing or unreadable (graceful first-run / corruption handling).
    public func load() -> AppState {
        guard let data = try? Data(contentsOf: url) else { return AppState() }
        return (try? JSONDecoder().decode(AppState.self, from: data)) ?? AppState()
    }

    public func save(_ state: AppState) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
    }
}
