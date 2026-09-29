import Foundation
import Observation
import TeebeCore

/// A guarded mutation awaiting user confirmation (PRD §9, D3). Carries the exact
/// affected paths and whether the worktree is "busy" (recently written by an agent).
struct PendingMutation: Equatable {
    enum Kind: Equatable {
        case discard
        case discardUntracked
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
    /// The checkout `status` was read from. `worktreePath` moves the instant another
    /// worktree is clicked, while the read itself lands a moment later, so anything
    /// folding the live status into a row must key off this instead — otherwise the
    /// row just clicked is briefly described by the previous checkout's status, which
    /// drops it into the wrong group and jumps it back when the read arrives.
    private(set) var statusPath: String?
    private(set) var changes: [FileChange] = []
    var filter: ChangeFilter = .all { didSet { if filter != oldValue { scheduleSearch(); onFilePreferencesChange?() } } }
    var showIgnored = false {
        didSet {
            guard showIgnored != oldValue else { return }
            childrenCache.removeAll()
            rebuildTree()
            scheduleSearch()
            onFilePreferencesChange?()
        }
    }
    /// Saves the existing file-filter preferences when their menu controls change.
    var onFilePreferencesChange: (() -> Void)?
    var sortOrder: FileSortOrder = .name { didSet { if sortOrder != oldValue { onFilePreferencesChange?() } } }
    /// Live search query (filters the FILES tree by name).
    var searchQuery: String = "" { didSet { if searchQuery != oldValue { scheduleSearch() } } }
    private(set) var isSearching = false
    private(set) var isLoading = false
    private var searchResults: [FileNode]?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    private var searchGeneration = 0
    /// Currently selected row path (drives the spacebar preview).
    var selectedPath: String?
    /// Which list the current selection came from — decides what space previews:
    /// native Quick Look for a FILES row, the in-app diff for a CHANGES row.
    enum SelectionSource { case files, changes }
    var selectionSource: SelectionSource = .files
    /// Expanded directory paths in the FILES tree.
    var expandedPaths: Set<String> = []
    /// Multi-selection set for the FILES tree (absolute paths). `selectedPath` is the
    /// active cursor and is always a member while a file selection exists; batch ops
    /// (trash, copy-as-refs) act on this set.
    var selectedPaths: Set<String> = []
    /// Anchor row for range (⇧) selection; the fixed end as the cursor moves.
    private var selectionAnchor: String?
    private(set) var worktreePath: String?
    private(set) var errorMessage: String?
    /// The selected worktree's folder is gone (deleted, still registered with
    /// Git): nothing is read from it and the lists show a placeholder instead.
    private(set) var isFolderMissing = false
    private(set) var pendingMutation: PendingMutation?

    /// Window (seconds) used to flag a worktree as "busy" before a guarded op.
    var busyWindow: TimeInterval = 5
    /// Window (seconds) after one of teebe's OWN writes during which file-watch
    /// events are attributed to us and NOT recorded as worktree activity — so the
    /// user's own stage/commit/discard/trash/new/rename never reads as "an agent is
    /// active" (the live dot / busy warning are for *external* writers).
    var selfWriteIgnoreWindow: TimeInterval = 1.5
    private(set) var lastSelfWriteAt: Date?
    /// Called (with the worktree path) when an *external* write is observed, so the
    /// owner can refresh the live/activity indicators.
    var onActivity: ((String) -> Void)?

    private let environment: AppEnvironment
    private var repo: Repository?
    private var queue: RepoGitQueue?
    private var watcher: FileSystemWatcher?
    private var ignoredPaths: Set<String> = []
    /// Overlaid children of expanded directories (path → children).
    private var childrenCache: [String: [FileNode]] = [:]
    /// Coalesces watcher-driven refreshes: while one is running, further events
    /// collapse into a single queued follow-up, so a burst of file-watch events
    /// can't stack a backlog of `git status` calls behind one slow refresh.
    private var isRefreshing = false
    private var refreshQueued = false
    private var loadGeneration = 0

    init(environment: AppEnvironment) {
        self.environment = environment
    }

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
        // Stage every path with working-tree changes so the commit captures the full
        // change set — including the unstaged half of a partially-staged file and
        // untracked files. Purely-staged paths (worktreeStatus == .unmodified) need
        // no `add`.
        let toStage = changes.filter { $0.worktreeStatus != .unmodified }.map(\.path)
        if let worktreePath {
            await perform {
                if !toStage.isEmpty {
                    try await self.queue?.stage(worktreePath: worktreePath, paths: toStage)
                }
            }
        }
        await commit(message: message)
        commitMessage = ""
    }

    func clear() {
        searchTask?.cancel()
        searchGeneration += 1
        searchResults = nil
        isSearching = false
        isLoading = false
        loadGeneration += 1
        watcher?.stop()
        watcher = nil
        root = nil
        status = nil
        statusPath = nil
        changes = []
        worktreePath = nil
        errorMessage = nil
        isFolderMissing = false
        pendingMutation = nil
        expandedPaths.removeAll()
        childrenCache.removeAll()
    }

    // MARK: - Loading

    func load(worktreePath: String, repo: Repository?) async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        searchTask?.cancel()
        searchGeneration += 1
        searchResults = nil
        defer { if generation == loadGeneration { isLoading = false; scheduleSearch() } }
        watcher?.stop()
        watcher = nil
        self.worktreePath = worktreePath
        self.repo = repo
        self.queue = repo.map { environment.makeQueue(repoPath: $0.path) }
        self.expandedPaths.removeAll()
        self.childrenCache.removeAll()
        // The previous contents stay up until this read replaces them: clearing them
        // first left an empty CHANGES list for the length of the read, and the window
        // wrapped to it and grew back. A failed read still replaces them (`refresh`).
        errorMessage = nil
        isFolderMissing = false
        guard environment.folderExists(worktreePath) else { return markFolderMissing() }
        // Ignored-file discovery can be slow in large checkouts. Publish changes
        // as soon as status is ready; the Files tree follows with its ignore rules.
        let service = environment.statusService
        async let ignored = try? service.ignoredPaths(worktreePath: worktreePath)
        await refresh(rebuildFiles: false)
        let paths = await ignored
        guard generation == loadGeneration, !isFolderMissing else { return }
        ignoredPaths = Set(paths ?? [])
        rebuildTree()
        startWatching(worktreePath)
    }

    private func resetContents() {
        root = nil
        status = nil
        statusPath = nil
        changes = []
        ignoredPaths = []
    }

    /// The folder is gone: show the placeholder, not an error, and stop reading it.
    private func markFolderMissing() {
        watcher?.stop()
        watcher = nil
        resetContents()
        childrenCache.removeAll()
        errorMessage = nil
        isFolderMissing = true
    }

    // MARK: - Live file watching (FSEvents → status refresh + activity)

    private func startWatching(_ path: String) {
        watcher?.stop()
        let watcher = environment.makeWatcher()
        watcher.start(paths: [path], debounce: 0.25) { [weak self] paths in
            Task { @MainActor in await self?.handleFileSystemEvent(paths) }
        }
        self.watcher = watcher
    }

    /// Low power: drop the worktree's FSEvents stream (the busiest watcher — it
    /// spans the whole tree). `resumeWatching` restores it and refreshes to catch
    /// anything written while paused.
    func pauseWatching() {
        watcher?.stop()
        watcher = nil
    }

    func resumeWatching() async {
        guard let worktreePath, watcher == nil else { return }
        startWatching(worktreePath)
        await refresh()
    }

    /// Handle a file-watch event for the active worktree: record *external* activity
    /// (skipping our own recent writes, and changes that are only Git bookkeeping or
    /// build output), notify the owner, then refresh. Synchronous and parameterized
    /// so it is unit-testable without real FSEvents; nil paths means unknown.
    func handleFileSystemEvent(_ paths: [String]? = nil, now: Date = Date()) async {
        guard let worktreePath else { return }
        let counts = paths.map { !WorktreeActivityRouter.changedWorktrees(eventPaths: $0, among: [worktreePath]).isEmpty }
        if !recentSelfWrite(now: now), counts ?? true {
            environment.activityMonitor.recordActivity(worktreePath: worktreePath, at: now)
            onActivity?(worktreePath)
        }
        await coalescedRefresh()
    }

    /// Run `refresh()`, collapsing concurrent watcher events into at most one
    /// queued follow-up rather than one `git status` per event. Safe because the
    /// model is `@MainActor`-isolated: the flag checks never interleave.
    private func coalescedRefresh() async {
        if isRefreshing { refreshQueued = true; return }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            refreshQueued = false
            await refresh()
        } while refreshQueued
    }

    /// Mark that teebe just wrote into the worktree, so the imminent file-watch
    /// event is not misattributed to an external agent.
    func noteSelfWrite(at date: Date = Date()) { lastSelfWriteAt = date }

    /// Whether teebe wrote into the worktree within `selfWriteIgnoreWindow` of `now`.
    func recentSelfWrite(now: Date = Date()) -> Bool {
        guard let lastSelfWriteAt else { return false }
        return now.timeIntervalSince(lastSelfWriteAt) < selfWriteIgnoreWindow
    }

    /// Re-query status and rebuild the tree (called on watcher events).
    func refresh(rebuildFiles: Bool = true) async {
        guard let worktreePath else { return }
        let generation = loadGeneration
        guard environment.folderExists(worktreePath) else { return markFolderMissing() }
        do {
            let result = try await environment.statusService.status(worktreePath: worktreePath)
            // A newer selection may have landed while this read was in flight.
            guard generation == loadGeneration, worktreePath == self.worktreePath else { return }
            status = result
            statusPath = worktreePath
            changes = result.changes
            errorMessage = nil
            isFolderMissing = false
        } catch GitError.workingDirectoryMissing {
            guard generation == loadGeneration, worktreePath == self.worktreePath else { return }
            return markFolderMissing()
        } catch {
            guard generation == loadGeneration, worktreePath == self.worktreePath else { return }
            // The first read of a new selection failed: never leave the previous
            // worktree's changes standing in for this one's.
            if statusPath != worktreePath {
                status = nil
                statusPath = nil
                changes = []
            }
            errorMessage = Self.describe(error)
        }
        if rebuildFiles {
            // Ignore rules and ignored files can change while this checkout stays
            // selected. Refresh their listing before rebuilding the visible tree.
            let paths = try? await environment.statusService.ignoredPaths(worktreePath: worktreePath)
            guard generation == loadGeneration, worktreePath == self.worktreePath, !isFolderMissing else { return }
            ignoredPaths = Set(paths ?? [])
            rebuildTree()
            reloadExpandedChildren()
            scheduleSearch()
        }
    }

    private func rebuildTree() {
        guard let worktreePath else { return }
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

    /// A nested expansion under a closed parent is remembered, but cannot be
    /// collapsed in the displayed tree. Search results are flat as well.
    var hasExpandedFolders: Bool {
        guard searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return displayRoot?.children?.contains { $0.isDirectory && isExpanded($0) } == true
    }

    func collapseAll() {
        expandedPaths.removeAll()
        // Keep the cursor on a visible ancestor after its child disappears.
        guard searchQuery.isEmpty, let selectedPath, let worktreePath else { return }
        let rootPath = PathUtil.standardized(worktreePath)
        let first = PathUtil.relativePath(of: selectedPath, under: rootPath).split(separator: "/").first
        if let first { select(rootPath + "/" + first) }
    }

    func relativePath(of node: FileNode) -> String {
        worktreePath.map { PathUtil.relativePath(of: node.path, under: PathUtil.standardized($0)) } ?? node.path
    }

    /// The task owns a cancellable background scan, not a growing chain of scans
    /// for every keystroke. Query and worktree generations reject stale results.
    private func scheduleSearch() {
        searchTask?.cancel()
        searchGeneration += 1
        searchResults = nil
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard filter == .all, !query.isEmpty, let path = worktreePath, !isLoading else { isSearching = false; return }
        isSearching = true
        let generation = searchGeneration
        let builder = makeBuilder(rootPath: path)
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(120))
                let scan = Task.detached(priority: .userInitiated) { try builder.search(query) }
                let nodes = try await withTaskCancellationHandler { try await scan.value } onCancel: { scan.cancel() }
                guard let self, !Task.isCancelled, generation == self.searchGeneration else { return }
                self.searchResults = nodes
                self.isSearching = false
            } catch {
                guard let self, generation == self.searchGeneration else { return }
                self.isSearching = false
            }
        }
    }

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
        guard let worktreePath else { return }
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
        if !query.isEmpty, filter == .all, let searchResults, let worktreePath {
            let byPath = Dictionary(changes.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
            return sortNodes(searchResults).map { node in
                var node = node
                node.change = byPath[PathUtil.relativePath(of: node.path, under: PathUtil.standardized(worktreePath))]
                return TreeRow(node: node, depth: 0)
            }
        }

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
                    if !child.isDirectory, relativePath(of: child).lowercased().contains(query) {
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

    /// Search activation must never act on a cursor hidden by the current query.
    @discardableResult
    func selectCurrentOrFirstVisibleFile() -> FileNode? {
        let rows = visibleRows
        guard let node = rows.first(where: { $0.node.path == selectedPath })?.node ?? rows.first?.node else { return nil }
        selectionSource = .files
        select(node.path)
        return node
    }

    func selectNext() { moveSelection(by: 1) }
    func selectPrevious() { moveSelection(by: -1) }

    private func moveSelection(by delta: Int) {
        let rows = visibleRows
        guard !rows.isEmpty else { return }
        guard let current = selectedPath, let index = rows.firstIndex(where: { $0.node.path == current }) else {
            select(rows[0].node.path)
            return
        }
        let next = max(0, min(rows.count - 1, index + delta))
        select(rows[next].node.path)
    }

    // MARK: - Multi-selection (FILES)

    /// Single-select `path` (plain click / plain arrow): collapses any multi-selection
    /// to just this row and re-anchors range selection here.
    func select(_ path: String) {
        selectionSource = .files
        selectedPath = path
        selectedPaths = [path]
        selectionAnchor = path
    }

    /// ⌘-click: toggle `path` in/out of the selection, leaving the rest intact.
    func toggleSelection(_ path: String) {
        selectionSource = .files
        if selectedPaths.contains(path) {
            selectedPaths.remove(path)
            if selectedPath == path { selectedPath = selectedPaths.first }
        } else {
            selectedPaths.insert(path)
            selectedPath = path
        }
        selectionAnchor = path
    }

    /// ⇧-click / range select: select the contiguous visible run from the anchor to
    /// `path` inclusive, moving the cursor to `path` (the anchor stays put).
    func extendSelection(to path: String) {
        let order = visibleRows.map(\.node.path)
        guard let anchor = selectionAnchor ?? selectedPath,
              let a = order.firstIndex(of: anchor),
              let b = order.firstIndex(of: path) else { select(path); return }
        selectionSource = .files
        selectedPaths = Set(order[min(a, b)...max(a, b)])
        selectedPath = path
    }

    /// ⇧↑ / ⇧↓: move the cursor one row and extend the range selection to it.
    func extendSelection(by delta: Int) {
        let rows = visibleRows
        guard !rows.isEmpty else { return }
        guard let current = selectedPath, let index = rows.firstIndex(where: { $0.node.path == current }) else {
            select(rows[0].node.path); return
        }
        if selectionAnchor == nil { selectionAnchor = current }
        let next = max(0, min(rows.count - 1, index + delta))
        extendSelection(to: rows[next].node.path)
    }

    /// ⌘A: select every visible row.
    func selectAllVisible() {
        let order = visibleRows.map(\.node.path)
        guard !order.isEmpty else { return }
        selectionSource = .files
        selectedPaths = Set(order)
        if selectedPath == nil || !selectedPaths.contains(selectedPath!) { selectedPath = order.last }
    }

    /// Selected paths in visible (top-to-bottom) order.
    func orderedSelection() -> [String] {
        visibleRows.map(\.node.path).filter { selectedPaths.contains($0) }
    }

    /// Selected file nodes (directories excluded), in visible order — used to "open all".
    func selectedFileNodes() -> [FileNode] {
        orderedSelection().compactMap { node(atPath: $0) }.filter { !$0.isDirectory }
    }

    // MARK: - CHANGES list navigation

    /// Move the CHANGES selection by `delta` through the change list (in display
    /// order), clamping at the ends. Returns the newly selected change so the caller
    /// can refresh an open diff peek.
    @discardableResult
    func moveChangeSelection(by delta: Int) -> FileChange? {
        guard let worktreePath, !changes.isEmpty else { return nil }
        selectionSource = .changes
        let absolute = changes.map { worktreePath + "/" + $0.path }
        let index = selectedPath.flatMap { absolute.firstIndex(of: $0) }
        let next = index.map { max(0, min(absolute.count - 1, $0 + delta)) } ?? 0
        selectedPath = absolute[next]
        return changes[next]
    }

    /// Keep the current change selected if it's still valid, else select the first —
    /// used when the CHANGES section becomes active. Returns the resulting change.
    @discardableResult
    func selectCurrentOrFirstChange() -> FileChange? {
        guard let worktreePath, !changes.isEmpty else { return nil }
        selectionSource = .changes
        let absolute = changes.map { worktreePath + "/" + $0.path }
        if let selectedPath, let index = absolute.firstIndex(of: selectedPath) { return changes[index] }
        selectedPath = absolute[0]
        return changes[0]
    }

    // MARK: - Left/Right arrow tree navigation (VSCode-style)

    /// →: expand a collapsed folder; on an already-expanded folder, step into its
    /// first child. No-op on a file.
    func selectExpandOrDescend() {
        guard let node = selectedNode else {
            if let first = visibleRows.first { select(first.node.path) }
            return
        }
        guard node.isDirectory else { return }
        if isExpanded(node) {
            let rows = visibleRows
            guard let i = rows.firstIndex(where: { $0.node.path == node.path }) else { return }
            if i + 1 < rows.count, rows[i + 1].depth > rows[i].depth {
                select(rows[i + 1].node.path)
            }
        } else {
            toggleExpand(node)
        }
    }

    /// ←: collapse an expanded folder; on a collapsed folder or a file, jump up to the
    /// parent folder.
    func selectCollapseOrAscend() {
        guard let node = selectedNode else { return }
        if node.isDirectory, isExpanded(node) {
            toggleExpand(node)
            return
        }
        let rows = visibleRows
        guard let i = rows.firstIndex(where: { $0.node.path == node.path }) else { return }
        let depth = rows[i].depth
        guard depth > 0 else { return }
        for j in stride(from: i - 1, through: 0, by: -1) where rows[j].depth == depth - 1 {
            select(rows[j].node.path)
            return
        }
    }

    // MARK: - Selection as Claude-ready @-refs (clipboard)

    /// The current FILES selection as a single clipboard string of `@`-prefixed paths
    /// relative to the worktree root, in visible order, space-joined (each token quoted
    /// when it contains spaces). Empty when nothing is selected or no worktree is open.
    func selectionRefs() -> String {
        guard let worktreePath else { return "" }
        let root = PathUtil.standardized(worktreePath)
        let tokens = orderedSelection().map { absolute -> String in
            let rel = PathUtil.relativePath(of: absolute, under: root)
            return rel.contains(" ") ? "@\"\(rel)\"" : "@\(rel)"
        }
        return tokens.joined(separator: " ")
    }

    /// Move the current multi-selection to the Trash (guarded; shows the confirm
    /// dialog). No-op when the selection is empty.
    func requestTrashSelected(now: Date = Date()) {
        let paths = orderedSelection()
        guard !paths.isEmpty else { return }
        pendingMutation = PendingMutation(kind: .trash, paths: paths, worktreeBusy: isBusy(now))
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

    /// The tree to display given the current filter. `Changed` derives the tree
    /// directly from the change list so changed files always appear.
    var displayRoot: FileNode? {
        switch filter {
        case .all:
            return root
        case .changed:
            guard let worktreePath else { return root }
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

    func requestTrash(path: String, now: Date = Date()) {
        pendingMutation = PendingMutation(kind: .trash, paths: [path], worktreeBusy: isBusy(now))
    }

    func cancelPendingMutation() {
        pendingMutation = nil
    }

    func confirmPendingMutation() async {
        guard let mutation = pendingMutation else { return }
        await confirm(mutation)
    }

    /// Execute a specific guarded mutation. Callers pass the mutation explicitly
    /// (captured synchronously) rather than reading `pendingMutation` here: the
    /// confirmation dialog clears `pendingMutation` as it dismisses, so a confirm
    /// deferred into a `Task` would otherwise find it already nil and silently no-op.
    func confirm(_ mutation: PendingMutation) async {
        guard let worktreePath else { return }
        pendingMutation = nil
        await perform {
            switch mutation.kind {
            case .discard:
                try await self.queue?.discardWorking(worktreePath: worktreePath, paths: mutation.paths)
            case .discardUntracked:
                try await self.queue?.discardUntracked(worktreePath: worktreePath, paths: mutation.paths)
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
        noteSelfWrite()
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
            case .worktreeBusy(let path): return "Worktree busy: \(path)"
            case .executableNotFound: return "git executable not found."
            case .workingDirectoryMissing(let path): return "The worktree folder is missing: \(path)"
            case .decodingFailed(let message): return message
            }
        }
        return "\(error)"
    }
}
