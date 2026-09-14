import Foundation
import Observation
import TeebeCore

/// Read-only row indicators. They describe commit ancestry, never deletion eligibility.
@MainActor
@Observable
final class WorktreeMergeModel {
    private(set) var snapshot: CleanupSnapshot?
    private(set) var isChecking = false
    private let service: WorktreeCleanupChecking
    private var generation = UUID()

    init(service: WorktreeCleanupChecking) { self.service = service }

    func refresh(repo: Repository?, targetOverride: String?, enabled: Bool) async {
        let token = UUID()
        generation = token
        snapshot = nil
        isChecking = false
        guard enabled, let repo else { return }
        isChecking = true
        defer { if generation == token { isChecking = false } }
        do {
            let result = try await service.scan(repoPath: repo.path, targetOverride: targetOverride)
            guard generation == token, !Task.isCancelled else { return }
            snapshot = result
        } catch {
            // Unavailable history stays unknown; it must never look merged.
        }
    }

    func entry(for path: String) -> CleanupEntry? { snapshot?.entries.first { $0.id == path } }
}
