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
    private var requestID = UUID()

    init(environment: AppEnvironment) {
        self.environment = environment
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
    @discardableResult
    func update(for node: FileNode, worktreePath: String) async -> Bool {
        guard !node.isDirectory else { return false }
        let request = UUID()
        requestID = request
        content = .loading
        currentPath = node.path
        let url = URL(fileURLWithPath: node.path)

        let resolved: Content
        switch PreviewResolver.kind(forFileName: node.name, change: node.change) {
        case .diff:
            if let change = node.change,
               let diff = try? await environment.diffService.diff(for: change, worktreePath: worktreePath) {
                resolved = PreviewLimits.canRender(diff) ? .diff(diff) : .tooLarge(url)
            } else {
                resolved = .quickLook(url)
            }
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

    func close() {
        requestID = UUID()
        isVisible = false
        content = .empty
        currentPath = nil
    }
}
