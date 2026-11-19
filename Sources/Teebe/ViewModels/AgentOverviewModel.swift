import AppKit
import Foundation
import Observation
import TeebeCore

/// Every agent working or waiting across all added repositories, for the menu
/// bar. The selected repository is read from the worktree list itself, so the
/// two never disagree; every repository is also scanned here on a slow poll, in
/// one agent scan, with each worktree list re-read now and then.
@MainActor
@Observable
final class AgentOverviewModel {
    struct Entry: Identifiable, Equatable {
        let repoPath: String
        let repoTitle: String
        let worktreePath: String
        let name: String
        let state: AgentActivityState
        let context: AgentContext?
        var id: String { worktreePath }
    }

    /// The menu's two groups, each ordered by project, then name.
    struct Summary: Equatable {
        var waiting: [Entry] = []
        var working: [Entry] = []
    }

    /// Pure: who is waiting and who is working. Idle entries count for nothing.
    static func summarize(_ entries: [Entry]) -> Summary {
        func ordered(_ rows: [Entry]) -> [Entry] { rows.sorted(by: orderedBefore) }
        return Summary(waiting: ordered(entries.filter { $0.state == .needsAttention }),
                       working: ordered(entries.filter { $0.state == .working }))
    }

    private static func orderedBefore(_ lhs: Entry, _ rhs: Entry) -> Bool {
        let repo = lhs.repoTitle.localizedStandardCompare(rhs.repoTitle)
        if repo != .orderedSame { return repo == .orderedAscending }
        let name = lhs.name.localizedStandardCompare(rhs.name)
        if name != .orderedSame { return name == .orderedAscending }
        return lhs.worktreePath < rhs.worktreePath
    }

    /// The status item's title: "1 waiting · 2 working", zero parts left out;
    /// nil when nothing is going on (the icon alone).
    static func title(_ summary: Summary) -> String? {
        let parts = [summary.waiting.isEmpty ? nil : "\(summary.waiting.count) waiting",
                     summary.working.isEmpty ? nil : "\(summary.working.count) working"].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// What VoiceOver reads for the status item.
    static func accessibilityLabel(_ summary: Summary) -> String {
        "Teebe: \(summary.waiting.count) waiting for you, \(summary.working.count) working"
    }

    let app: AppModel
    /// Agents in every added repository, from the last poll; only those outside
    /// the selected repository are shown from here.
    private(set) var others: [Entry] = []
    @ObservationIgnored private var worktreesByRepo: [String: (listedAt: Date, paths: [(path: String, name: String)])] = [:]
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    var pollInterval: TimeInterval = 15
    /// How long a repository's worktree list is reused before it is read again.
    var worktreeListInterval: TimeInterval = 120

    init(app: AppModel) {
        self.app = app
    }

    var entries: [Entry] {
        let selected = app.selector.selectedRepo
        let added = Set(app.repositories.map(\.path))
        var result = others.filter { $0.repoPath != selected?.path && added.contains($0.repoPath) }
        if let selected {
            let title = app.repositoryTitle(selected)
            for worktree in app.selector.worktrees {
                let info = app.selector.info(for: worktree)
                guard info.agentState != .idle else { continue }
                result.append(Entry(repoPath: selected.path, repoTitle: title, worktreePath: worktree.path,
                                    name: worktree.branch ?? worktree.name, state: info.agentState,
                                    context: info.agentContext))
            }
        }
        return result
    }

    var summary: Summary { Self.summarize(entries) }

    /// Poll the other repositories while the menu bar icon is shown.
    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.app.agentDisplay.showsMenuBarIcon { await self.refreshOthers() }
                try? await Task.sleep(for: .seconds(self.pollInterval))
            }
        }
    }

    func refreshOthers(now: Date = Date()) async {
        // The selected repository is scanned too, so its agents are already known
        // here the moment another one is picked.
        let repos = app.repositories
        guard repos.count > 1 else { others = []; return }
        let environment = app.environment
        for repo in repos where worktreesByRepo[repo.path].map({ now.timeIntervalSince($0.listedAt) >= worktreeListInterval }) ?? true {
            let listed = (try? await environment.worktreeService.worktrees(for: repo)) ?? []
            worktreesByRepo[repo.path] = (now, listed.map { ($0.path, $0.branch ?? $0.name) })
        }
        let owners = Dictionary(repos.flatMap { repo in (worktreesByRepo[repo.path]?.paths ?? []).map { ($0.path, (repo, $0.name)) } },
                                uniquingKeysWith: { first, _ in first })
        let paths = Array(owners.keys)
        let snapshot = environment.agentSnapshot
        let statuses = environment.agentStatuses
        let agents = await Task.detached {
            AppEnvironment.readAgents(paths, now, snapshot: snapshot, statuses: statuses)
        }.value
        others = agents.states.compactMap { path, state in
            guard state != .idle, let (repo, name) = owners[path] else { return nil }
            return Entry(repoPath: repo.path, repoTitle: app.repositoryTitle(repo), worktreePath: path, name: name,
                         state: state, context: agents.contexts[path])
        }
    }

    /// Bring teebe forward on this worktree, switching project if needed.
    func open(_ entry: Entry) async {
        Self.bringMainWindowForward()
        app.activeSection = .worktrees
        if app.selector.selectedRepo?.path == entry.repoPath {
            if let worktree = app.selector.worktrees.first(where: { $0.path == entry.worktreePath }) {
                await app.selector.selectWorktree(worktree)
            }
        } else if let repo = app.repositories.first(where: { $0.path == entry.repoPath }) {
            await app.selector.selectRepo(repo, preferredWorktreePath: entry.worktreePath)
        }
    }

    static func bringMainWindowForward() {
        NSApp.activate(ignoringOtherApps: true)
        let candidates = NSApp.windows.filter { $0.canBecomeMain && !($0 is NSPanel) }
        guard let window = candidates.first(where: { $0.title == Brand.name }) ?? candidates.first else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }
}
