import Foundation
import Observation
import AppKit
import TeebeCore

/// Shared wording for the checked menu items and Settings.
enum WorktreePreferences {
    static let groupingTitle = "Group by status"
    static let groupingHelp = "Group worktrees into Uncommitted changes, Not merged and Safe to delete. "
        + "When off, keep a flat list; each row still shows its status."
    static let fetchTitle = "Fetch automatically"
    static let fetchHelp = "Fetch origin when you return to the app or select a project, at most once every five minutes. Refresh always works."
    static let extraTargetTitle = "Also check merges against"
    static let extraTargetHelp = "Merges are checked against up to four branches: the default branch, the one chosen "
        + "here, then dev, develop, main and master when they exist. "
        + "Choose one for this repository, such as a release branch."
}

/// Root view model: owns the added repositories, persistence, and the selector.
@MainActor
@Observable
final class AppModel {
    private(set) var repositories: [Repository] = []
    let preferences: PreferencesModel
    var groupWorktreesByMergeStatus: Bool {
        get { preferences.effective.groupByStatus ?? false }
        set { preferences.set(\.groupByStatus, newValue) }
    }
    /// How the worktree list is ordered, within each group when grouped.
    var worktreeSortOrder: WorktreeSortOrder {
        get { WorktreeSortOrder(rawValue: preferences.effective.worktreeSort ?? "") ?? .folder }
        set { preferences.set(\.worktreeSort, newValue.rawValue) }
    }
    /// Fetch remote refs in the background, so merge results reflect what was
    /// pushed rather than what was last pulled by hand.
    var fetchAutomatically: Bool {
        get { preferences.effective.fetchAutomatically ?? true }
        set { preferences.set(\.fetchAutomatically, newValue) }
    }
    /// Bumped when a repository's extra merge target changes, so the scan reruns.
    private(set) var mergeTargetRevision = 0
    /// "Also delete the branch" in the removal confirmation; the last choice sticks.
    var deleteBranchOnRemove: Bool { didSet { persist() } }
    var floatOnTop: Bool { didSet { persist() } }
    /// Light / dark override, or follow the system. Applied app-wide via `NSApp.appearance`.
    var appearance: AppearanceMode { didSet { appearance.apply(); persist() } }
    var terminal: TerminalChoice { didSet { persist() } }
    var agentNotifications: Bool { didSet { selector.notificationsEnabled = agentNotifications; persist() } }
    var notificationSound: Bool { didSet { AgentNotifier.soundEnabled = notificationSound; persist() } }
    private(set) var hookInstalled = false
    private(set) var hooksDisabled = false
    private(set) var hookMessage: String?
    private(set) var notificationTestMessage: String?
    private(set) var isFetching = false
    private(set) var fetchError: String?
    private(set) var errorMessage: String?
    /// The New Worktree sheet's form while it is up; nil when it is closed.
    var newWorktree: NewWorktreeModel?
    /// A worktree row's card asked for from the keyboard: the row, and a count
    /// that changes on every request so asking again shows it again.
    private(set) var worktreeCardReveal: (path: String, count: Int)?

    /// Show this row's status card now, as hovering its mark would.
    func revealWorktreeCard(for path: String) {
        worktreeCardReveal = (path, (worktreeCardReveal?.count ?? 0) + 1)
    }

    /// Which section the keyboard currently drives — arrows, Enter and Space act on
    /// it, and its header shows the active accent. Moved by ⌘1/⌘2/⌘3, Tab/⇧Tab, or by
    /// clicking into a section.
    enum FocusSection: Equatable { case worktrees, changes, files }
    var activeSection: FocusSection = .files

    /// Auto-dismiss timer for the current error banner, so a transient failure
    /// (e.g. "Not a git repository") never sticks around indefinitely.
    @ObservationIgnored private var errorClearTask: Task<Void, Never>?

    let environment: AppEnvironment
    let selector: SelectorModel
    let mergeStatus: WorktreeMergeModel
    let remoteRefresher: RemoteRefresher
    /// The app each file type opens with (asked on first open, then remembered).
    let openWith: OpenWithModel

    /// The group-header actions. Built on first use because they need the finished
    /// model back; one instance, so a removal in flight is visible everywhere.
    @ObservationIgnored private var groupActionsStorage: WorktreeGroupActions?
    var groupActions: WorktreeGroupActions {
        if let groupActionsStorage { return groupActionsStorage }
        let actions = WorktreeGroupActions(app: self)
        groupActionsStorage = actions
        return actions
    }

    /// In-memory copy of the persisted state, loaded once at init and written back
    /// on change. Avoids a disk read-modify-write on every persist/layout update,
    /// and lets `persist()` and `saveLayout()` mutate disjoint fields of one value
    /// without reloading to avoid clobbering each other.
    @ObservationIgnored private var state: AppState
    /// True only while `bootstrap()` hydrates the model from `state`; suppresses the
    /// `persist()` that property assignments would otherwise trigger during load.
    @ObservationIgnored private var isHydrating = false
    @ObservationIgnored private var isApplyingPreferences = false

    /// `mergeService` is the scanner behind the worktree groups; tests hand in a
    /// scripted one instead of a real repository.
    init(environment: AppEnvironment, mergeService: WorktreeCleanupChecking? = nil) {
        self.environment = environment
        self.state = environment.store.load()
        self.preferences = PreferencesModel(state: self.state)
        self.selector = SelectorModel(environment: environment)
        self.mergeStatus = WorktreeMergeModel(service: mergeService ?? WorktreeCleanupService(git: environment.git))
        self.remoteRefresher = RemoteRefresher(git: environment.git)
        self.openWith = OpenWithModel(environment: environment, apps: self.state.openWithApps ?? [:],
            projectApps: self.state.openWithAppsByRepo ?? [:],
            policy: OpenWithModel.Policy(rawValue: self.state.openWithPolicy ?? "") ?? .system,
            defaultApp: self.state.defaultFileApp)
        self.deleteBranchOnRemove = self.state.deleteBranchOnRemove ?? false
        self.floatOnTop = false
        self.appearance = .system
        self.terminal = TerminalChoice(rawValue: self.state.terminalApp ?? "") ?? .terminal
        self.agentNotifications = self.state.agentNotifications ?? true
        self.notificationSound = self.state.notificationSound ?? true
        self.selector.notificationsEnabled = self.agentNotifications
        AgentNotifier.soundEnabled = self.notificationSound
        // Persist whenever the selection changes, and clear any stale global error —
        // navigating to a different repo/worktree should dismiss the banner.
        self.selector.onSelectionChange = { [weak self] in
            self?.rememberSelectedRepository()
            self?.persist()
            self?.setError(nil)
        }
        // Deleted worktrees are never forgotten while a removal is running.
        self.selector.isRemovalRunning = { [weak self] in self?.groupActionsStorage?.isWorking == true }
        self.openWith.onChange = { [weak self] in self?.persist() }
        self.preferences.onChange = { [weak self] in
            guard let self else { return }
            self.applyFilePreferences()
            self.mergeTargetRevision += 1
            self.persist()
        }
        self.selector.onRepositoryChange = { [weak self] in
            guard let self else { return }
            self.preferences.repositoryPath = self.selector.selectedRepo?.path
            self.openWith.repositoryPath = self.selector.selectedRepo?.path
            self.applyFilePreferences()
        }
        self.applyFilePreferences()
        self.selector.worktree.onFilePreferencesChange = { [weak self] in self?.saveFileOverrides() }
    }

    private func applyFilePreferences() {
        guard !isApplyingPreferences else { return }
        isApplyingPreferences = true
        defer { isApplyingPreferences = false }
        let values = preferences.effective
        selector.worktree.showIgnored = values.showIgnored ?? false
        selector.worktree.sortOrder = FileSortOrder(rawValue: values.fileSort ?? "") ?? .name
    }

    private func saveFileOverrides() {
        guard !isApplyingPreferences else { return }
        isApplyingPreferences = true
        defer { isApplyingPreferences = false }
        let values = preferences.effective
        let files = selector.worktree
        if files.showIgnored != (values.showIgnored ?? false) { preferences.set(\.showIgnored, files.showIgnored) }
        if files.sortOrder.rawValue != (values.fileSort ?? "name") { preferences.set(\.fileSort, files.sortOrder.rawValue) }
    }

    /// Single entry point for the global error banner. Replaces any existing
    /// message and (re)arms a timer that clears it, so it can't get stuck.
    func setError(_ message: String?) {
        errorMessage = message
        errorClearTask?.cancel()
        guard message != nil else { return }
        errorClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.errorMessage = nil
        }
    }

    /// Load persisted state and hydrate repositories + selection.
    func bootstrap() async {
        // Hydrate from the in-memory state without letting the assignments below
        // persist a half-built state back over what we just loaded.
        isHydrating = true
        floatOnTop = state.floatOnTop
        appearance = AppearanceMode(rawValue: state.appearance ?? "") ?? .system
        repositories = RepositoryHistory.unique(state.repositories.map(\.path))
        selector.setRepositories(repositories)
        // Snapshot the restore targets before selecting anything: selection triggers
        // persist(), which overwrites these fields of the shared `state`.
        let lastRepoPath = state.lastSelectedRepoPath.map { PathUtil.standardized(($0 as NSString).standardizingPath) }
        let lastWorktreePath = state.lastSelectedWorktreePath
        let target = lastRepoPath.flatMap { last in repositories.first { $0.path == last } }
            ?? repositories.first
        isHydrating = false
        guard let target else { persist(); return }
        // One shot: the saved worktree (when it still exists) is selected directly,
        // never primary-then-saved — the double load crashed the first layout pass.
        await selector.selectRepo(target, preferredWorktreePath: lastWorktreePath)
    }

    // MARK: - Low-power mode + Claude Code hook

    /// Mirror window occlusion into the selector's low-power mode: covered window
    /// → stop all FSEvents streams and ride on the hook ping.
    func setBackgrounded(_ backgrounded: Bool) {
        Task { await selector.setLowPower(backgrounded) }
    }

    /// What to do about the Claude Code ping hook at launch.
    enum HookSetupAction: Equatable { case ask, repair, none }

    static func hookSetupAction(installed: Bool, response: String?) -> HookSetupAction {
        if installed { return .none }
        switch response {
        case "accepted": return .repair   // user opted in once — restore silently
        case "declined": return .none     // user said no — never touch, never re-ask
        default: return .ask
        }
    }

    func refreshHookStatus() {
        hookInstalled = ClaudeHookInstaller.isInstalled()
        hooksDisabled = ClaudeHookInstaller.hooksDisabled()
    }

    func installClaudeHook() {
        do {
            _ = try ClaudeHookInstaller.install()
            state.hookOfferResponse = "accepted"
            refreshHookStatus()
            hookMessage = hooksDisabled
                ? "Installed, but Claude Code has all hooks disabled. Enable hooks there to receive instant updates."
                : "Installed. Restart existing Claude Code sessions to load the hook."
            persist()
        } catch { hookMessage = "Couldn’t update Claude Code settings. Existing settings were kept." }
        refreshHookStatus()
    }

    func testNotification() {
        notificationTestMessage = "Sending…"
        AgentNotifier.post(title: "Teebe test", body: "Agent notifications can reach this Mac.") { [weak self] result in
            self?.notificationTestMessage = result
        }
    }

    /// Launch-time hook setup: offer once, then keep the user's choice. An
    /// accepted hook that later disappears (settings rewritten by another tool)
    /// is repaired without asking again.
    func setUpHookIfNeeded() {
        let action = Self.hookSetupAction(
            installed: ClaudeHookInstaller.isInstalled(),
            response: state.hookOfferResponse)
        switch action {
        case .none:
            return
        case .repair:
            installClaudeHook()
        case .ask:
            let alert = NSAlert()
            alert.messageText = "Notify instantly, use less battery?"
            alert.informativeText = """
            Add a local signal to Claude Code so Teebe checks its status promptly, \
            even while hidden. This optional hook is for Claude Code only. Codex \
            activity is also detected, with checks up to two minutes apart while hidden. \
            No session content is sent anywhere. You can install or repair the hook later in Settings.
            """
            alert.addButton(withTitle: "Add Hook")
            alert.addButton(withTitle: "No Thanks")
            let accepted = alert.runModal() == .alertFirstButtonReturn
            state.hookOfferResponse = accepted ? "accepted" : "declined"
            saveState()
            if accepted {
                do { try ClaudeHookInstaller.install() } catch { setError("Couldn't update ~/.claude/settings.json — hook not added.") }
            }
        }
    }

    /// Add a repository after verifying it is a git repo (it must answer
    /// `worktree list`). Persists on success.
    @discardableResult
    func addRepository(path: String) async -> Bool {
        // Canonicalize (tilde + realpath) so it matches the paths git reports for
        // worktrees (firmlink /var → /private/var), avoiding duplicate/mismatched entries.
        let standardized = PathUtil.standardized((path as NSString).expandingTildeInPath)
        setError(nil)   // a fresh attempt clears any stale banner
        // Re-adding a tracked repo isn't an error — the user picked it expecting to
        // see it, so switch to it instead of silently doing nothing.
        if let existing = repositories.first(where: { $0.path == standardized }) {
            await selector.selectRepo(existing)
            return false
        }
        do {
            _ = try await environment.git.worktrees(repoPath: standardized)
        } catch {
            setError("Not a git repository: \(standardized)")
            return false
        }
        // Validation suspends; another add may have completed while it ran.
        if let existing = repositories.first(where: { $0.path == standardized }) {
            await selector.selectRepo(existing)
            return false
        }
        let repo = Repository(path: standardized)
        repositories.append(repo)
        selector.setRepositories(repositories)
        persist()
        await selector.selectRepo(repo)
        return true
    }

    private func rememberSelectedRepository() {
        guard let selected = selector.selectedRepo,
              let index = repositories.firstIndex(where: { $0.path == selected.path }),
              index != repositories.count - 1 else { return }
        repositories.append(repositories.remove(at: index))
        selector.setRepositories(repositories)
    }

    var recentRepositories: [Repository] { Array(repositories.reversed()) }

    func repositoryTitle(_ repo: Repository) -> String {
        RepositoryHistory.title(for: repo, among: repositories)
    }

    func removeRepository(_ repo: Repository) {
        repositories.removeAll { $0.path == repo.path }
        selector.setRepositories(repositories)
        if selector.selectedRepo?.path == repo.path {
            selector.clearSelection()
        }
        // Drop everything else keyed by this repository, or the saved state grows a
        // tail of entries for projects the user removed long ago.
        state.cleanupTargetByRepo?[repo.path] = nil
        state.layoutByRepo?[repo.path] = nil
        state.worktreeParentByRepo?[repo.path] = nil
        preferences.remove(repo.path)
        openWith.removeProject(repo.path)
        persist()
    }

    // MARK: - File activation (double-click / context menu)

    /// Open a file in its native app (D1): the app remembered for its type, asking
    /// which one the first time. Directories are ignored.
    func open(_ node: FileNode) {
        guard !node.isDirectory else { return }
        do {
            try openWith.open(URL(fileURLWithPath: node.path))
            setError(nil)
        } catch {
            setError("Couldn't open \(node.name)")
        }
    }

    func reveal(_ node: FileNode) {
        environment.opener.reveal(URL(fileURLWithPath: node.path))
    }

    /// Open With…: pick the app, open the file with it, and remember it for the type.
    func openWith(_ node: FileNode) {
        guard !node.isDirectory else { return }
        do {
            try openWith.chooseAndOpen(URL(fileURLWithPath: node.path))
            setError(nil)
        } catch {
            setError("Couldn't open \(node.name)")
        }
    }

    private(set) var quickLookRequest: (path: String, count: Int)?

    func requestQuickLook(_ node: FileNode) {
        guard !node.isDirectory else { return }
        quickLookRequest = (node.path, (quickLookRequest?.count ?? 0) + 1)
    }

    func copyPath(_ node: FileNode, relative: Bool = false) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(relative ? selector.worktree.relativePath(of: node) : node.path, forType: .string)
    }

    func copySelectedPaths() {
        let paths = selector.worktree.orderedSelection()
        guard activeSection == .files, !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    /// ⌘⇧C: copy the FILES selection to the clipboard as Claude-ready `@`-refs, ready
    /// to paste into whatever terminal/agent is open. No-op unless files are selected.
    func copySelectedRefs() {
        let refs = selector.worktree.selectionRefs()
        guard !refs.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(refs, forType: .string)
    }

    /// ⌘F: ask the FILES search field to take focus. The view observes this counter
    /// and focuses on change (a token rather than a bool so repeat presses re-fire).
    private(set) var searchFocusRequest = 0
    func focusSearch() {
        focusFiles()
        searchFocusRequest += 1
    }

    /// Clicking search and invoking its shortcut share the same keyboard owner.
    func focusFiles() {
        activeSection = .files
        selector.worktree.selectionSource = .files
    }

    @discardableResult
    func focusFileResults() -> FileNode? {
        focusFiles()
        return selector.worktree.selectCurrentOrFirstVisibleFile()
    }

    /// Return in search opens only a visible result, or does nothing with no matches.
    func activateSearchResult() {
        guard let node = focusFileResults() else { return }
        if node.isDirectory { selector.worktree.toggleExpand(node) } else { open(node) }
    }

    func rename(_ node: FileNode) {
        guard let newName = promptForName(title: "Rename", initial: node.name), newName != node.name else { return }
        runFileOp { _ = try self.environment.ops.rename(at: URL(fileURLWithPath: node.path), to: newName) }
    }

    func duplicate(_ node: FileNode) {
        runFileOp { _ = try self.environment.ops.duplicate(at: URL(fileURLWithPath: node.path)) }
    }

    func newFile(in node: FileNode) {
        guard let name = promptForName(title: "New File", initial: "Untitled.txt") else { return }
        let dir = directoryURL(for: node)
        runFileOp { _ = try self.environment.ops.createFile(in: dir, named: name) }
    }

    func newFolder(in node: FileNode) {
        guard let name = promptForName(title: "New Folder", initial: "untitled folder") else { return }
        let dir = directoryURL(for: node)
        runFileOp { _ = try self.environment.ops.createDirectory(in: dir, named: name) }
    }

    private func directoryURL(for node: FileNode) -> URL {
        node.isDirectory
            ? URL(fileURLWithPath: node.path)
            : URL(fileURLWithPath: (node.path as NSString).deletingLastPathComponent)
    }

    private func runFileOp(_ operation: @escaping () throws -> Void) {
        do {
            try operation()
            // This was teebe's own write — don't let the resulting file-watch event
            // read as external agent activity.
            selector.worktree.noteSelfWrite()
            Task { await selector.worktree.refresh() }
        } catch {
            setError("File operation failed: \(WorktreeModel.describe(error))")
        }
    }

    private func promptForName(title: String, initial: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    /// Show an open panel to add a repository (Repo ▾ → Add Repository).
    func presentAddRepositoryPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Repository"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await addRepository(path: url.path) }
    }

    /// Open the New Worktree sheet for the selected repository. The sheet's form
    /// state lives in `newWorktree` for as long as it is up.
    func presentNewWorktree() {
        guard let repo = selector.selectedRepo else { return }
        let comparison = mergeStatus.snapshot?.targets.automatic?.name
        let primaryBranch = selector.worktrees.first(where: \.isPrimary)?.branch
        let parent = WorktreeLocation.parentFolder(
            repoPath: repo.path, remembered: preferences.effective(for: repo.path).worktreeParent,
            worktrees: selector.worktrees)
        newWorktree = NewWorktreeModel(repo: repo, branches: selector.branches,
                                       comparisonBranch: comparison, primaryBranch: primaryBranch,
                                       parentFolder: parent,
                                       registeredPaths: Set(selector.worktrees.map(\.path)))
    }

    /// Pick the folder new worktrees go in. Directories only, and new ones can be
    /// made from inside the panel.
    func chooseWorktreeLocation(for form: NewWorktreeModel) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: form.parentFolder)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setWorktreeParent(url.path, for: form)
    }

    /// Use `path` as the folder for this worktree and remember it for the repository.
    func setWorktreeParent(_ path: String, for form: NewWorktreeModel) {
        form.setParentFolder(path)
        var byRepo = state.worktreeParentByRepo ?? [:]
        byRepo[form.repo.path] = path
        state.worktreeParentByRepo = byRepo
        preferences.setWorktreeParent(path, for: form.repo.path)
        persist()
    }

    /// Create the worktree the sheet describes. On success the repository is
    /// re-read and the new worktree selected; on failure the message goes back to
    /// the form so the sheet can stay open.
    func createWorktree(_ form: NewWorktreeModel) async {
        let repo = form.repo
        let path = form.location
        form.isCreating = true
        form.errorMessage = nil
        defer { form.isCreating = false }
        do {
            try await environment.worktreeService.addWorktree(
                in: repo, at: path, branch: form.trimmedBranch,
                createBranch: form.isCreatingBranch, startPoint: form.resolvedStartPoint)
        } catch {
            form.errorMessage = "Couldn't create worktree: \(WorktreeModel.describe(error))"
            return
        }
        newWorktree = nil
        // The folder exists now, so standardizing matches the form `git worktree
        // list` reports (firmlinks resolved) and the new row gets selected.
        await selector.selectRepo(repo, preferredWorktreePath: PathUtil.standardized(path))
    }

    /// Bring the selected repository's remote refs up to date. The setting gates
    /// background fetches only; explicit Refresh also bypasses the rate limit. Writing
    /// refs is what makes the merge check re-run, through the repository watcher. The
    /// rows' sync facts are re-read here too: the watcher is off in low power.
    func refreshRemotes(force: Bool, now: Date = Date()) async {
        guard force || fetchAutomatically, let repo = selector.selectedRepo else { return }
        if force {
            guard !isFetching else { return }
            isFetching = true
            fetchError = nil
        }
        defer { if force { isFetching = false } }
        let succeeded = await remoteRefresher.fetch(repoPath: repo.path, force: force, now: now)
        guard selector.selectedRepo?.path == repo.path else { return }
        if succeeded { await selector.refreshWorktreeInfo() } else if force { fetchError = "Couldn’t fetch origin. Check your connection and repository access." }
    }

    /// The branch (full ref, e.g. `refs/heads/release/2`) this repository's
    /// worktrees are also checked against, beyond the automatic default and the
    /// integration branches. nil when none is set.
    func extraMergeTarget(for repoPath: String) -> String? {
        let ref = preferences.effective(for: repoPath).comparisonRef
        return ref?.isEmpty == false ? ref : nil
    }

    /// Set or clear (nil) the extra merge target; the merge check reruns.
    func setExtraMergeTarget(_ ref: String?, for repoPath: String) {
        preferences.setComparison(ref, for: repoPath)
    }

    func revealPath(_ path: String) {
        environment.opener.reveal(URL(fileURLWithPath: path))
    }

    func chooseWorktreeParentDefault(forProject: Bool = false) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if forProject { preferences.set(\.worktreeParent, url.path) } else { preferences.defaults.worktreeParent = url.path }
    }

    func openTerminal(at path: String) {
        let choice = terminal
        Task {
            let succeeded = await Task.detached { choice.launch(at: path) }.value
            if !succeeded { setError("Couldn’t open \(choice.title). Check that it is installed.") }
        }
    }

    func persist() {
        guard !isHydrating else { return }
        state.repositories = repositories.map { PersistedRepository(path: $0.path) }
        state.defaultPreferences = preferences.defaults
        state.projectPreferences = preferences.projects
        state.showChangedOnly = false
        state.showIgnored = preferences.defaults.showIgnored ?? false
        state.floatOnTop = floatOnTop
        state.showMergeStatus = preferences.defaults.groupByStatus
        state.worktreeSortOrder = preferences.defaults.worktreeSort == "folder" ? nil : preferences.defaults.worktreeSort
        state.fetchAutomatically = preferences.defaults.fetchAutomatically
        state.deleteBranchOnRemove = deleteBranchOnRemove
        state.appearance = appearance == .system ? nil : appearance.rawValue
        state.terminalApp = terminal.rawValue
        state.agentNotifications = agentNotifications
        state.notificationSound = notificationSound
        state.openWithApps = openWith.apps.isEmpty ? nil : openWith.apps
        state.openWithAppsByRepo = openWith.projectApps
        state.openWithPolicy = openWith.policy.rawValue
        state.defaultFileApp = openWith.defaultApp
        state.lastSelectedRepoPath = selector.selectedRepo?.path
        state.lastSelectedWorktreePath = selector.selectedWorktree?.path
        saveState()
    }

    private func saveState() {
        // WhatsNewModel owns this marker and may have advanced it since we
        // loaded our in-memory preferences. Never restore the previous version.
        state.lastSeenVersion = environment.store.load().lastSeenVersion
        try? environment.store.save(state)
    }

    // MARK: - Per-repository accordion layout

    /// The saved accordion layout for a repository, or nil if it's never been opened.
    func layout(forRepo path: String?) -> SectionLayout? {
        guard let path else { return nil }
        return state.layoutByRepo?[path]
    }

    /// Remember a repository's accordion layout (open sections + window height).
    func saveLayout(_ layout: SectionLayout, forRepo path: String?) {
        guard let path else { return }
        var byRepo = state.layoutByRepo ?? [:]
        byRepo[path] = layout
        state.layoutByRepo = byRepo
        saveState()
    }
}
