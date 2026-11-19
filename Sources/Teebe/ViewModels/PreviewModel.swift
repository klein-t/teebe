import Foundation
import Observation
import TeebeCore

/// The floating Quick Look preview (spacebar). Resolves a selection to a diff, a
/// read-only text preview, or a hand-off to the system Quick Look (D1, PRD §5.2).
@MainActor
@Observable
final class PreviewModel {
    enum Content: Equatable {
        case empty
        case loading
        case tooLarge(URL)
        case diff(DiffFile)
        case text(String)
        case quickLook(URL)
    }

    private(set) var isVisible = false
    private(set) var content: Content = .empty
    private(set) var currentPath: String?

    private let environment: AppEnvironment
    private let defaults: UserDefaults
    private var requestID = UUID()
    /// What is showing, so a changed diff option can ask for it again.
    private var shown: (node: FileNode, worktreePath: String)?

    init(environment: AppEnvironment, defaults: UserDefaults = .standard) {
        self.environment = environment
        self.defaults = defaults
    }

    /// Spacebar: toggle the panel. Opening resolves content for `node`.
    @discardableResult
    func toggle(for node: FileNode?, worktreePath: String) async -> Bool {
        if isVisible {
            close()
            return false
        }
        guard let node, !node.isDirectory else { return false }
        isVisible = true
        return await update(for: node, worktreePath: worktreePath)
    }

    /// Arrow keys while open: live-update the preview to a new selection.
    /// `keepingContent` leaves the current preview up until the new one is ready.
    @discardableResult
    func update(for node: FileNode, worktreePath: String, keepingContent: Bool = false) async -> Bool {
        guard !node.isDirectory else { return false }
        let request = UUID()
        requestID = request
        if !keepingContent { content = .loading }
        currentPath = node.path
        shown = (node, worktreePath)
        let url = URL(fileURLWithPath: node.path)
        let ignoringWhitespace = defaults.bool(forKey: DiffDisplayOptions.ignoreWhitespaceKey)

        let resolved: Content
        switch PreviewResolver.kind(forFileName: node.name, change: node.change) {
        case .diff:
            resolved = await diffContent(node.change, worktreePath: worktreePath, url: url,
                                         ignoringWhitespace: ignoringWhitespace)
        case .text:
            switch await Task.detached(priority: .userInitiated, operation: {
                PreviewTextLoader.load(url)
            }).value {
            case .text(let text): resolved = .text(text)
            case .tooLarge: resolved = .tooLarge(url)
            case .unreadable: resolved = .quickLook(url)
            }
        case .quickLook:
            resolved = .quickLook(url)
        }
        guard requestID == request else { return false }
        guard !Task.isCancelled else { close(); return false }
        content = resolved
        return true
    }

    private func diffContent(_ change: FileChange?, worktreePath: String, url: URL,
                             ignoringWhitespace: Bool) async -> Content {
        guard let change,
              let diff = try? await environment.diffService.diff(for: change, worktreePath: worktreePath,
                                                                 ignoringWhitespace: ignoringWhitespace) else {
            return .quickLook(url)
        }
        return PreviewLimits.canRender(diff) ? .diff(diff) : .tooLarge(url)
    }

    /// Ask again for what is showing, after a diff option changed.
    func reload() async {
        guard isVisible, let shown else { return }
        await update(for: shown.node, worktreePath: shown.worktreePath, keepingContent: true)
    }

    func close() {
        requestID = UUID()
        shown = nil
        isVisible = false
        content = .empty
        currentPath = nil
    }
}
