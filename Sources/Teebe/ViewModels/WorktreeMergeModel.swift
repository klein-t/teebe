import Foundation
import Observation
import TeebeCore

/// Row results can be reused while refreshing; cleanup always scans independently.
@MainActor
@Observable
final class WorktreeMergeModel {
    private(set) var snapshot: CleanupSnapshot?
    private(set) var isChecking = false
    private let service: WorktreeCleanupChecking
    private var generation = UUID()
    private struct Key: Hashable { let path: String; let target: String? }
    private struct Cached { let snapshot: CleanupSnapshot; let revision: Int? }
    private var cache: [Key: Cached] = [:]

    init(service: WorktreeCleanupChecking) { self.service = service }

    func refresh(repo: Repository?, targetOverride: String?, enabled: Bool, revision: Int? = nil) async {
        let token = UUID()
        generation = token
        isChecking = false
        guard enabled, let repo else { snapshot = nil; cache.removeAll(); return }
        let key = Key(path: repo.path, target: targetOverride)
        snapshot = cache[key]?.snapshot
        if let revision, let cached = cache[key], cached.revision == revision,
           Date().timeIntervalSince(cached.snapshot.checkedAt) < 30 { return }
        isChecking = true
        defer { if generation == token { isChecking = false } }
        do {
            let result = try await service.scan(repoPath: repo.path, targetOverride: targetOverride)
            guard generation == token, !Task.isCancelled else { return }
            snapshot = result
            cache[key] = Cached(snapshot: result, revision: revision)
            if cache.count > 8, let oldest = cache.min(by: { $0.value.snapshot.checkedAt < $1.value.snapshot.checkedAt })?.key {
                cache.removeValue(forKey: oldest)
            }
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            snapshot = nil
            cache.removeValue(forKey: key)
        }
    }

    /// Active-file edits affect only this row, not the merge results for every worktree.
    func entry(for path: String, localStatus: StatusResult? = nil) -> CleanupEntry? {
        guard var entry = snapshot?.entries.first(where: { $0.id == path }) else { return nil }
        if let localStatus, !entry.isBroken {
            entry.hasLocalChanges = localStatus.changes.contains { $0.worktreeStatus != .ignored }
            if let head = localStatus.oid, !head.isEmpty, head != entry.worktree.head {
                entry.mergeStatus = .unknown
                entry.problem = "New commits are being checked"
            }
        }
        return entry
    }
}
