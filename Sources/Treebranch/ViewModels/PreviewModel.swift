import Foundation
import Observation
import TreebranchCore

/// The floating Quick Look preview (spacebar). Resolves a selection to a diff, a
/// read-only text preview, or a hand-off to the system Quick Look (D1, PRD §5.2).
@MainActor
@Observable
final class PreviewModel {
    enum Content: Equatable {
        case empty
        case diff(DiffFile)
        case text(String)
        case quickLook(URL)
    }

    private(set) var isVisible = false
    private(set) var content: Content = .empty
    private(set) var currentPath: String?

    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    /// Spacebar: toggle the panel. Opening resolves content for `node`.
    func toggle(for node: FileNode?, worktreePath: String) async {
        if isVisible {
            close()
            return
        }
        guard let node, !node.isDirectory else { return }
        await update(for: node, worktreePath: worktreePath)
        isVisible = true
    }

    /// Arrow keys while open: live-update the preview to a new selection.
    func update(for node: FileNode, worktreePath: String) async {
        guard !node.isDirectory else { return }
        currentPath = node.path
        let url = URL(fileURLWithPath: node.path)

        switch PreviewResolver.kind(forFileName: node.name, change: node.change) {
        case .diff:
            if let change = node.change,
               let diff = try? await environment.diffService.diff(for: change, worktreePath: worktreePath) {
                content = .diff(diff)
            } else {
                content = .quickLook(url)
            }
        case .text:
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                content = .text(text)
            } else {
                content = .quickLook(url)
            }
        case .quickLook:
            content = .quickLook(url)
        }
    }

    func close() {
        isVisible = false
        content = .empty
        currentPath = nil
    }
}
