import Foundation
import Observation
import AppKit
import TreebranchCore

/// Root view model: owns the added repositories, persistence, and the selector.
@MainActor
@Observable
final class AppModel {
    private(set) var repositories: [Repository] = []
    var floatOnTop: Bool { didSet { persist() } }
    var errorMessage: String?

    let environment: AppEnvironment
    let selector: SelectorModel

    init(environment: AppEnvironment) {
        self.environment = environment
        self.selector = SelectorModel(environment: environment)
        self.floatOnTop = false
        // Persist whenever the selection changes so the app reopens where it was left.
        self.selector.onSelectionChange = { [weak self] in self?.persist() }
    }

    /// Load persisted state and hydrate repositories + selection.
    func bootstrap() async {
        let state = environment.store.load()
        floatOnTop = state.floatOnTop
        repositories = state.repositories.map { Repository(path: $0.path) }
        selector.setRepositories(repositories)
        let target = state.lastSelectedRepoPath.flatMap { last in repositories.first { $0.path == last } }
            ?? repositories.first
        guard let target else { return }
        await selector.selectRepo(target)   // focuses the primary worktree
        // Restore the last selected worktree if it still exists (else keep primary).
        if let wtPath = state.lastSelectedWorktreePath,
           selector.selectedWorktree?.path != wtPath,
           let saved = selector.worktrees.first(where: { $0.path == wtPath }) {
            await selector.selectWorktree(saved)
        }
    }

    /// Add a repository after verifying it is a git repo (it must answer
    /// `worktree list`). Persists on success.
    @discardableResult
    func addRepository(path: String) async -> Bool {
        // Canonicalize (tilde + realpath) so it matches the paths git reports for
        // worktrees (firmlink /var → /private/var), avoiding duplicate/mismatched entries.
        let standardized = PathUtil.standardized((path as NSString).expandingTildeInPath)
        guard !repositories.contains(where: { $0.path == standardized }) else { return false }
        do {
            _ = try await environment.git.worktrees(repoPath: standardized)
        } catch {
            errorMessage = "Not a git repository: \(standardized)"
            return false
        }
        let repo = Repository(path: standardized)
        repositories.append(repo)
        selector.setRepositories(repositories)
        persist()
        await selector.selectRepo(repo)
        return true
    }

    func removeRepository(_ repo: Repository) {
        repositories.removeAll { $0.path == repo.path }
        selector.setRepositories(repositories)
        if selector.selectedRepo?.path == repo.path {
            selector.clearSelection()
        }
        persist()
    }

    // MARK: - File activation (double-click / context menu)

    /// Open a file in its native app (D1). Directories are ignored.
    func open(_ node: FileNode) {
        guard !node.isDirectory else { return }
        do {
            try environment.opener.open(URL(fileURLWithPath: node.path))
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't open \(node.name)"
        }
    }

    func reveal(_ node: FileNode) {
        environment.opener.reveal(URL(fileURLWithPath: node.path))
    }

    func openWith(_ node: FileNode) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = "Open With"
        guard panel.runModal() == .OK, let appURL = panel.url else { return }
        try? environment.opener.open(URL(fileURLWithPath: node.path), withApplicationAt: appURL)
    }

    func copyPath(_ node: FileNode) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.path, forType: .string)
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
            errorMessage = "File operation failed: \(WorktreeModel.describe(error))"
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

    /// Choose a directory for a new linked worktree (branch = folder name).
    func presentNewWorktreePanel() {
        guard let repo = selector.selectedRepo else { return }
        let panel = NSSavePanel()
        panel.prompt = "Create Worktree"
        panel.nameFieldStringValue = "worktree"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let branch = url.lastPathComponent
        Task {
            do {
                try await environment.worktreeService.addWorktree(in: repo, at: url.path, branch: branch, createBranch: true)
                await selector.selectRepo(repo)
            } catch {
                errorMessage = "Couldn't create worktree: \(error)"
            }
        }
    }

    func removeWorktree(_ worktree: Worktree) {
        guard let repo = selector.selectedRepo else { return }
        Task {
            do {
                try await environment.worktreeService.removeWorktree(in: repo, worktree: worktree, force: false)
                await selector.selectRepo(repo)
            } catch {
                errorMessage = "Couldn't remove worktree: \(WorktreeModel.describe(error))"
            }
        }
    }

    func revealPath(_ path: String) {
        environment.opener.reveal(URL(fileURLWithPath: path))
    }

    /// Open the worktree directory in Terminal.
    func openTerminal(at path: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal", path]
        try? process.run()
    }

    func persist() {
        var state = environment.store.load()
        state.repositories = repositories.map { PersistedRepository(path: $0.path) }
        state.floatOnTop = floatOnTop
        state.lastSelectedRepoPath = selector.selectedRepo?.path
        state.lastSelectedWorktreePath = selector.selectedWorktree?.path
        try? environment.store.save(state)
    }

    // MARK: - Per-repository accordion layout

    /// The saved accordion layout for a repository, or nil if it's never been opened.
    func layout(forRepo path: String?) -> SectionLayout? {
        guard let path else { return nil }
        return environment.store.load().layoutByRepo?[path]
    }

    /// Remember a repository's accordion layout (open sections + window height).
    func saveLayout(_ layout: SectionLayout, forRepo path: String?) {
        guard let path else { return }
        var state = environment.store.load()
        var byRepo = state.layoutByRepo ?? [:]
        byRepo[path] = layout
        state.layoutByRepo = byRepo
        try? environment.store.save(state)
    }
}
