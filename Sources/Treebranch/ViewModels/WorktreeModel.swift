import Foundation
import Observation
import TreebranchCore

/// A guarded mutation awaiting user confirmation (PRD §9, D3). Carries the exact
/// affected paths and whether the worktree is "busy" (recently written by an agent).
struct PendingMutation: Equatable {
    enum Kind: Equatable {
        case discard
        case discardUntracked
        case checkout(branch: String)
        case trash
    }
    var kind: Kind
    var paths: [String]
    var worktreeBusy: Bool
}

/// The file tree + git status for the selected worktree, plus its mutations.
@MainActor
@Observable
final class WorktreeModel {
    private(set) var root: FileNode?
    private(set) var status: StatusResult?
    private(set) var changes: [FileChange] = []
    var filter: ChangeFilter = .all
    var showIgnored = false { didSet { childrenCache.removeAll(); rebuildTree() } }
    var sortOrder: FileSortOrder = .name
    /// Live search query (filters the FILES tree by name).
    var searchQuery: String = ""
    /// Currently selected row path (drives the spacebar preview).
    var selectedPath: String?
    /// Which list the current selection came from — decides what space previews:
    /// native Quick Look for a FILES row, the in-app diff for a CHANGES row.
    enum SelectionSource { case files, changes }
    var selectionSource: SelectionSource = .files
    /// Expanded directory paths in the FILES tree.
    var expandedPaths: Set<String> = []
    private(set) var worktreePath: String?
    private(set) var isBrowsingSnapshot = false
    /// The branch ref currently being browsed read-only (snapshot mode).
    private(set) var browseRef: String?
    private(set) var errorMessage: String?
    private(set) var pendingMutation: PendingMutation?

    /// Window (seconds) used to flag a worktree as "busy" before a guarded op.
    var busyWindow: TimeInterval = 5

    private let environment: AppEnvironment
    private var repo: Repository?
    private var queue: RepoGitQueue?
    private var watcher: FileSystemWatcher?
    private var ignoredPaths: Set<String> = []
    /// Overlaid children of expanded directories (path → children).
    private var childrenCache: [String: [FileNode]] = [:]

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    /// Repo path when browsing a read-only snapshot (else nil).
    var snapshotRepoPath: String? { isBrowsingSnapshot ? worktreePath : nil }

    var changeCount: Int { changes.count }

    /// Pending commit message (CHANGES section).
    var commitMessage: String = ""

    /// Changes grouped by parent folder for the CHANGES list.
    struct ChangeGroup: Identifiable, Equatable {
        let folder: String
        let changes: [FileChange]
        var id: String { folder }
    }

    var changeGroups: [ChangeGroup] {
        let grouped = Dictionary(grouping: changes) { change in
            (change.path as NSString).deletingLastPathComponent
        }
        return grouped
            .map { ChangeGroup(folder: $0.key, changes: $0.value.sorted { $0.path < $1.path }) }
            .sorted { $0.folder < $1.folder }
    }

    /// Commit the staged/working changes with the pending message, then clear it.
    func commitPending() async {
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        // Stage everything not yet staged so the commit captures the change set.
        let unstaged = changes.filter { !$0.isStaged && !$0.isUntracked }.map(\.path)
        let untracked = changes.filter { $0.isUntracked }.map(\.path)
        if let worktreePath {
            await perform {
                if !(unstaged + untracked).isEmpty {
                    try await self.queue?.stage(worktreePath: worktreePath, paths: unstaged + untracked)
                }
            }
        }
        await commit(message: message)
        commitMessage = ""
    }

    func clear() {
        watcher?.stop()
        watcher = nil
        root = nil
        status = nil
        changes = []
        worktreePath = nil
        isBrowsingSnapshot = false
        browseRef = nil
        errorMessage = nil
        pendingMutation = nil
        expandedPaths.removeAll()
        childrenCache.removeAll()
    }

    // MARK: - Loading

    func load(worktreePath: String, repo: Repository?) async {
        self.worktreePath = worktreePath
        self.repo = repo
        self.isBrowsingSnapshot = false
        self.browseRef = nil
        self.queue = repo.map { environment.makeQueue(repoPath: $0.path) }
        self.expandedPaths.removeAll()
        self.childrenCache.removeAll()
        self.ignoredPaths = Set((try? await environment.statusService.ignoredPaths(worktreePath: worktreePath)) ?? [])
        startWatching(worktreePath)
        await refresh()
    }

    // MARK: - Live file watching (FSEvents → status refresh + activity)

    private func startWatching(_ path: String) {
        watcher?.stop()
        let watcher = environment.makeWatcher()
        watcher.start(paths: [path], debounce: 0.25) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.worktreePath == path, !self.isBrowsingSnapshot else { return }
                self.environment.activityMonitor.recordActivity(worktreePath: path, at: Date())
                await self.refresh()
            }
        }
        self.watcher = watcher
    }

    /// Re-query status and rebuild the tree (called on watcher events).
    func refresh() async {
        guard let worktreePath, !isBrowsingSnapshot else { return }
        do {
            let result = try await environment.statusService.status(worktreePath: worktreePath)
            status = result
            changes = result.changes
            errorMessage = nil
        } catch {
            errorMessage = Self.describe(error)
        }
        rebuildTree()
        reloadExpandedChildren()
    }

    /// Browse another branch's committed tree read-only (D2): files come from git,
    /// the working directory is untouched.
    func loadSnapshot(repo: Repository, ref: String) async {
        watcher?.stop()
        watcher = nil
        isBrowsingSnapshot = true
        browseRef = ref
        worktreePath = repo.path
        self.repo = repo
        do {
            let files = try await environment.branchService.snapshotFiles(for: repo, ref: ref)
            changes = []
            status = nil
            root = FileTreeBuilder.tree(fromRelativePaths: files, rootPath: repo.path)
            errorMessage = nil
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    private func rebuildTree() {
        guard let worktreePath, !isBrowsingSnapshot else { return }
        let builder = makeBuilder(rootPath: worktreePath)
        guard let built = try? builder.buildRoot() else { root = nil; return }
        root = StatusOverlay.apply(changes, to: built, rootPath: worktreePath)
    }

    /// A flattened, displayable tree row (node + indent depth).
    struct TreeRow: Identifiable, Equatable {
        let node: FileNode
        let depth: Int
        var id: String { node.path }
    }

    func isExpanded(_ node: FileNode) -> Bool { expandedPaths.contains(node.path) }

    /// Toggle a directory's expansion, loading its children on first expand.
    func toggleExpand(_ node: FileNode) {
        guard node.isDirectory else { return }
        if expandedPaths.contains(node.path) {
            expandedPaths.remove(node.path)
        } else {
            expandedPaths.insert(node.path)
            loadChildrenIntoCache(node.path)
        }
    }

    /// One level of children for `node`, overlaid with status (lazy expansion).
    func children(of node: FileNode) -> [FileNode] {
        if let preloaded = node.children { return preloaded }
        if let cached = childrenCache[node.path] { return cached }
        loadChildrenIntoCache(node.path)
        return childrenCache[node.path] ?? []
    }

    private func loadChildrenIntoCache(_ path: String) {
        guard let worktreePath, !isBrowsingSnapshot else { return }
        let kids = (try? makeBuilder(rootPath: worktreePath).loadChildren(of: path)) ?? []
        childrenCache[path] = kids.map { StatusOverlay.apply(changes, to: $0, rootPath: worktreePath) }
    }

    private func reloadExpandedChildren() {
        let paths = Array(childrenCache.keys)
        for path in paths where expandedPaths.contains(path) { loadChildrenIntoCache(path) }
    }

    /// The flattened, visible rows of the FILES tree, honoring expansion, sort and
    /// search. Search yields a flat list of matching files across the loaded tree.
    var visibleRows: [TreeRow] {
        guard let root = displayRoot else { return [] }
        let query = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        var rows: [TreeRow] = []

        func childrenSorted(_ node: FileNode) -> [FileNode] {
            let kids = node.children ?? childrenCache[node.path] ?? []
            return sortNodes(kids)
        }

        if query.isEmpty {
            func walk(_ node: FileNode, depth: Int) {
                for child in childrenSorted(node) {
                    rows.append(TreeRow(node: child, depth: depth))
                    if child.isDirectory, expandedPaths.contains(child.path) {
                        walk(child, depth: depth + 1)
                    }
                }
            }
            walk(root, depth: 0)
        } else {
            func collect(_ node: FileNode) {
                for child in childrenSorted(node) {
                    if !child.isDirectory, child.name.lowercased().contains(query) {
                        rows.append(TreeRow(node: child, depth: 0))
                    }
                    if child.isDirectory { collect(child) }
                }
            }
            collect(root)
        }
        return rows
    }

    private func sortNodes(_ nodes: [FileNode]) -> [FileNode] {
        switch sortOrder {
        case .name:
            return nodes // builder already sorts dirs-first by name
        case .recent:
            return nodes.sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return (lhs.modifiedAt ?? .distantPast) > (rhs.modifiedAt ?? .distantPast)
            }
        }
    }

    // MARK: - Keyboard selection

    var selectedNode: FileNode? {
        guard let selectedPath else { return nil }
        return node(atPath: selectedPath)
    }

    func selectNext() { moveSelection(by: 1) }
    func selectPrevious() { moveSelection(by: -1) }

    private func moveSelection(by delta: Int) {
        let rows = visibleRows
        guard !rows.isEmpty else { return }
        guard let current = selectedPath, let index = rows.firstIndex(where: { $0.node.path == current }) else {
            selectedPath = rows.first?.node.path
            return
        }
        let next = max(0, min(rows.count - 1, index + delta))
        selectedPath = rows[next].node.path
    }

    /// Find a node by absolute path within the currently displayed (and expanded)
    /// tree, including lazily-loaded children.
    func node(atPath path: String) -> FileNode? {
        if let row = visibleRows.first(where: { $0.node.path == path }) { return row.node }
        guard let root = displayRoot else { return nil }
        return Self.find(path, in: root)
    }

    private static func find(_ path: String, in node: FileNode) -> FileNode? {
        if node.path == path { return node }
        for child in node.children ?? [] {
            if let found = find(path, in: child) { return found }
        }
        return nil
    }

    private func makeBuilder(rootPath: String) -> FileTreeBuilder {
        FileTreeBuilder(
            rootPath: rootPath,
            options: .init(showHidden: true, showIgnored: showIgnored, ignoredPaths: ignoredPaths)
        )
    }

    /// Read-only content of a file at the browsed ref via `git show` (D2). Used by
    /// the preview while browsing a branch snapshot, instead of reading disk.
    func snapshotContent(forNodePath nodePath: String) async -> String? {
        guard let repo, let ref = browseRef else { return nil }
        let relative = PathUtil.relativePath(of: nodePath, under: PathUtil.standardized(repo.path))
        guard let data = try? await environment.branchService.snapshotFileContents(for: repo, ref: ref, path: relative) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// The tree to display given the current filter. `Changed` derives the tree
    /// directly from the change list so changed files always appear.
    var displayRoot: FileNode? {
        switch filter {
        case .all:
            return root
        case .changed:
            guard let worktreePath, !isBrowsingSnapshot else { return root }
            let tree = FileTreeBuilder.tree(fromRelativePaths: changes.map(\.path), rootPath: worktreePath)
            return StatusOverlay.apply(changes, to: tree, rootPath: worktreePath)
        }
    }

    // MARK: - Non-destructive git (no confirmation)

    func stage(_ change: FileChange) async {
        guard let worktreePath else { return }
        await perform { try await self.queue?.stage(worktreePath: worktreePath, paths: [change.path]) }
        await refresh()
    }

    func unstage(_ change: FileChange) async {
        guard let worktreePath else { return }
        await perform { try await self.queue?.unstage(worktreePath: worktreePath, paths: [change.path]) }
        await refresh()
    }

    // MARK: - Guarded mutations (require confirmation, D3)

    func requestDiscard(_ change: FileChange, now: Date = Date()) {
        let kind: PendingMutation.Kind = change.isUntracked ? .discardUntracked : .discard
        pendingMutation = PendingMutation(kind: kind, paths: [change.path], worktreeBusy: isBusy(now))
    }

    func requestCheckout(branch: String, now: Date = Date()) {
        pendingMutation = PendingMutation(kind: .checkout(branch: branch), paths: [], worktreeBusy: isBusy(now))
    }

    func requestTrash(path: String, now: Date = Date()) {
        pendingMutation = PendingMutation(kind: .trash, paths: [path], worktreeBusy: isBusy(now))
    }

    func cancelPendingMutation() {
        pendingMutation = nil
    }

    func confirmPendingMutation() async {
        guard let mutation = pendingMutation, let worktreePath else { return }
        pendingMutation = nil
        await perform {
            switch mutation.kind {
            case .discard:
                try await self.queue?.discardWorking(worktreePath: worktreePath, paths: mutation.paths)
            case .discardUntracked:
                try await self.queue?.discardUntracked(worktreePath: worktreePath, paths: mutation.paths)
            case .checkout(let branch):
                try await self.queue?.checkout(worktreePath: worktreePath, branch: branch)
            case .trash:
                for path in mutation.paths {
                    _ = try self.environment.ops.moveToTrash(URL(fileURLWithPath: path))
                }
            }
        }
        await refresh()
    }

    func commit(message: String) async {
        guard let worktreePath, !message.isEmpty else { return }
        await perform { try await self.queue?.commit(worktreePath: worktreePath, message: message) }
        await refresh()
    }

    private func isBusy(_ now: Date) -> Bool {
        guard let worktreePath else { return false }
        return environment.activityMonitor.isBusy(worktreePath: worktreePath, within: busyWindow, now: now)
    }

    private func perform(_ operation: @escaping () async throws -> Void) async {
        do {
            try await operation()
            errorMessage = nil
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    static func describe(_ error: Error) -> String {
        if let gitError = error as? GitError {
            switch gitError {
            case .commandFailed(_, _, let stderr): return stderr.isEmpty ? "git command failed" : stderr
            case .notAGitRepository(let path): return "Not a git repository: \(path)"
            case .lockedIndex: return "The git index is locked; try again."
            case .missingBaseBranch: return "No base branch found."
            case .worktreeBusy(let path): return "Worktree busy: \(path)"
            case .executableNotFound: return "git executable not found."
            case .decodingFailed(let message): return message
            }
        }
        return "\(error)"
    }
}
