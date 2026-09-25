import Foundation

/// A harness adapter: reads one coding agent's own records (Claude Code session
/// logs, Codex rollouts…) and reports what its sessions are doing in a repo's
/// worktrees. Adapters are the only source of "waiting for you"; plain file and
/// process activity (any harness) is tracked separately by the app. Adding a
/// harness is one new conforming type added to `CombinedAgentActivity`.
public protocol AgentActivitySource: Sendable {
    /// States keyed by worktree path, for the given worktree paths of one repo.
    /// A worktree with nothing going on may be missing or `.idle`.
    func states(forWorktreePaths paths: [String], now: Date) -> [String: AgentActivityState]
}

extension AgentSessionScanner: AgentActivitySource {}

/// Several adapters as one. Per worktree, waiting beats working (some agent there
/// needs the user, which is the thing to show), working beats idle.
public struct CombinedAgentActivity: AgentActivitySource {
    public var sources: [any AgentActivitySource]

    public init(_ sources: [any AgentActivitySource]) {
        self.sources = sources
    }

    public func states(forWorktreePaths paths: [String], now: Date) -> [String: AgentActivityState] {
        var result: [String: AgentActivityState] = [:]
        for path in paths { result[path] = .idle }
        for source in sources {
            for (path, state) in source.states(forWorktreePaths: paths, now: now) {
                guard let current = result[path] else { continue }
                result[path] = Self.rank(state) > Self.rank(current) ? state : current
            }
        }
        return result
    }

    private static func rank(_ state: AgentActivityState) -> Int {
        switch state {
        case .idle: return 0
        case .working: return 1
        case .needsAttention: return 2
        }
    }
}

/// Which worktree a session belongs to. Besides the directory it was started in,
/// a session is attributed by what it touches: an agent launched in one checkout
/// often edits another through absolute paths, and the row that should light up
/// is the one it is editing.
///
/// Rule: of the session's recent tool targets (newest first — commands' working
/// directories, edited file paths), the newest that lies inside a known worktree
/// wins. With no target inside any known worktree, the session's own cwd decides.
/// Containment always picks the deepest worktree (a worktree nested inside the
/// primary checkout owns its own files).
public enum WorktreeAttribution {
    /// How far back from a session's newest record its targets still count, and
    /// how many of the newest targets are considered.
    public static let targetWindow: TimeInterval = 300
    public static let targetLimit = 20

    public static func owner(targets: [String], cwd: String?, among paths: [String]) -> String? {
        for target in targets.prefix(targetLimit) {
            if let owner = deepest(containing: target, among: paths) { return owner }
        }
        return cwd.flatMap { deepest(containing: $0, among: paths) }
    }

    /// The deepest known worktree containing `path`; nil when outside all of them.
    public static func deepest(containing path: String, among paths: [String]) -> String? {
        let path = normalized(path)
        return paths
            .filter { let root = normalized($0); return path == root || path.hasPrefix(root + "/") }
            .max { $0.count < $1.count }
    }

    /// Agents write paths the way they were typed: `/tmp/x` for `/private/tmp/x`,
    /// `file://` URLs, trailing slashes. Git reports the real path.
    static func normalized(_ raw: String) -> String {
        var path = raw.hasPrefix("file://") ? (URL(string: raw)?.path ?? String(raw.dropFirst(7))) : raw
        for firmlink in ["/tmp", "/var", "/etc"] where path == firmlink || path.hasPrefix(firmlink + "/") {
            path = "/private" + path
        }
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
