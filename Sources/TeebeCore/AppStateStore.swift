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
    public var worktreesHeight: Double?
    /// Height the CHANGES list was dragged to, unclamped. Optional so older state
    /// files (written before the divider existed) still decode.
    public var changesHeight: Double?
    public var collapsedWorktreeGroups: [String]?

    public init(
        worktreesOpen: Bool = true,
        changesOpen: Bool = true,
        filesOpen: Bool = true,
        windowHeight: Double = 640,
        worktreesHeight: Double? = nil,
        changesHeight: Double? = nil,
        collapsedWorktreeGroups: [String]? = nil
    ) {
        self.worktreesOpen = worktreesOpen
        self.changesOpen = changesOpen
        self.filesOpen = filesOpen
        self.windowHeight = windowHeight
        self.worktreesHeight = worktreesHeight
        self.changesHeight = changesHeight
        self.collapsedWorktreeGroups = collapsedWorktreeGroups
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
    /// The user's answer to the one-time Claude Code hook offer: "accepted" (keep
    /// the hook repaired silently), "declined" (never ask again, never touch the
    /// settings), nil (not asked yet). Optional so older state files decode.
    public var hookOfferResponse: String?
    /// Appearance override: "light", "dark", or nil to follow the system. Optional so
    /// older state files decode.
    public var appearance: String?
    /// An extra merge target per repository (a full ref), checked in addition to
    /// the automatic default and integration branches. Missing entries add none.
    public var cleanupTargetByRepo: [String: String]?
    public var showMergeStatus: Bool?
    /// Fetch each repository's remote refs in the background. Optional so older
    /// state files decode; nil means the default (on).
    public var fetchAutomatically: Bool?
    /// The removal confirmation's "Also delete the branch" choice, remembered
    /// across sessions. Optional so older state files decode; nil means off.
    public var deleteBranchOnRemove: Bool?
    /// The folder last chosen for new worktrees, keyed by repository path.
    /// Optional so older state files decode; a missing entry means no choice yet.
    public var worktreeParentByRepo: [String: String]?
    /// The app chosen to open each file type (a `FileTypeKey`), as the app's path.
    /// Optional so older state files decode; a missing entry means ask on open.
    public var openWithApps: [String: String]?
    /// How the worktree list is ordered ("status", "name"). Optional so older state
    /// files decode; nil means the default (by folder).
    public var worktreeSortOrder: String?
    public var defaultPreferences: ProjectPreferences?
    public var projectPreferences: [String: ProjectPreferences]?
    public var openWithPolicy: String?
    public var defaultFileApp: String?
    public var openWithAppsByRepo: [String: [String: String]]?
    public var terminalApp: String?
    public var agentNotifications: Bool?
    public var notificationSound: Bool?

    public init(
        repositories: [PersistedRepository] = [],
        showChangedOnly: Bool = false,
        showIgnored: Bool = false,
        floatOnTop: Bool = false,
        lastSelectedRepoPath: String? = nil,
        lastSelectedWorktreePath: String? = nil,
        layoutByRepo: [String: SectionLayout]? = nil,
        lastSeenVersion: String? = nil,
        hookOfferResponse: String? = nil,
        appearance: String? = nil,
        cleanupTargetByRepo: [String: String]? = nil,
        showMergeStatus: Bool? = nil,
        fetchAutomatically: Bool? = nil,
        deleteBranchOnRemove: Bool? = nil,
        worktreeParentByRepo: [String: String]? = nil,
        openWithApps: [String: String]? = nil,
        worktreeSortOrder: String? = nil
    ) {
        self.repositories = repositories
        self.showChangedOnly = showChangedOnly
        self.showIgnored = showIgnored
        self.floatOnTop = floatOnTop
        self.lastSelectedRepoPath = lastSelectedRepoPath
        self.lastSelectedWorktreePath = lastSelectedWorktreePath
        self.layoutByRepo = layoutByRepo
        self.lastSeenVersion = lastSeenVersion
        self.hookOfferResponse = hookOfferResponse
        self.appearance = appearance
        self.cleanupTargetByRepo = cleanupTargetByRepo
        self.showMergeStatus = showMergeStatus
        self.fetchAutomatically = fetchAutomatically
        self.deleteBranchOnRemove = deleteBranchOnRemove
        self.worktreeParentByRepo = worktreeParentByRepo
        self.openWithApps = openWithApps
        self.worktreeSortOrder = worktreeSortOrder
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
    /// A file that exists but cannot be decoded is moved aside first: the app
    /// saves again soon after loading, which would otherwise destroy the only
    /// copy of a recoverable list of repositories.
    public func load() -> AppState {
        guard let data = try? Data(contentsOf: url) else { return AppState() }
        if let state = try? JSONDecoder().decode(AppState.self, from: data) { return state }
        setAside()
        return AppState()
    }

    private func setAside() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withTimeZone]
        let name = url.lastPathComponent + ".corrupt-" + formatter.string(from: Date())
        try? FileManager.default.moveItem(at: url, to: url.deletingLastPathComponent()
            .appendingPathComponent(name))
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
