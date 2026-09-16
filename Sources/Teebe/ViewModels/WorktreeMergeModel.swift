import Foundation
import Observation
import TeebeCore

/// One worktree's merge result as the list shows it: the last scan for that
/// checkout, plus what the live status read says about it since.
struct WorktreeMergeEntry: Equatable {
    var entry: CleanupEntry
    /// The checkout has committed since the scan, so the result shown is the
    /// previous one while a recheck runs. The row keeps its group: dropping it into
    /// the catch-all makes it jump groups, resize the window, and jump back.
    var isRechecking = false
    /// Uncommitted files counted by the live status read (0 when unknown).
    var localChangeCount = 0
}

/// Row results can be reused while refreshing; cleanup always scans independently.
@MainActor
@Observable
final class WorktreeMergeModel {
    private(set) var snapshot: CleanupSnapshot?
    private(set) var isChecking = false
    /// How long a burst of refresh keys is allowed to settle before scanning.
    /// A var so tests don't have to wait it out.
    var scanDebounce: Duration = .milliseconds(400)
    /// How long a scan stays reusable for an unchanged revision.
    static let reuseWindow: TimeInterval = 30
    private let service: WorktreeCleanupChecking
    private var generation = UUID()
    private struct Key: Hashable { let path: String; let target: String? }
    private struct Cached { let snapshot: CleanupSnapshot; let revision: Int? }
    private var cache: [Key: Cached] = [:]
    /// What the rows currently show, so a single-row recheck knows what to scan.
    private var currentRepo: Repository?
    private var currentTarget: String?
    /// Checkouts whose HEAD moved and are being rechecked in place.
    private var recheckPaths: Set<String> = []

    init(service: WorktreeCleanupChecking) { self.service = service }

    func refresh(repo: Repository?, targetOverride: String?, enabled: Bool, revision: Int? = nil) async {
        let token = UUID()
        generation = token
        isChecking = false
        guard enabled, let repo else {
            snapshot = nil
            cache.removeAll()
            currentRepo = nil
            return
        }
        currentRepo = repo
        currentTarget = targetOverride
        let key = Key(path: repo.path, target: targetOverride)
        snapshot = cache[key]?.snapshot
        // The key changed for a reason that cannot move merge ancestry — a
        // comparison-branch switch, or the cleanup sheet sharing the scan it just
        // ran. Same revision, recent result: show it rather than scanning again.
        if let revision, let cached = cache[key], cached.revision == revision,
           Date().timeIntervalSince(cached.snapshot.checkedAt) < Self.reuseWindow { return }
        // `.task(id:)` restarts on every key change, and a commit or a `git worktree
        // add` can bump the key repeatedly within a second. Let the burst settle so
        // one scan runs instead of a queue of cancelled ones.
        try? await Task.sleep(for: scanDebounce)
        guard !Task.isCancelled, generation == token else { return }
        isChecking = true
        defer { if generation == token { isChecking = false } }
        do {
            let result = try await service.scan(repoPath: repo.path, targetOverride: targetOverride)
            guard generation == token, !Task.isCancelled else { return }
            snapshot = result
            recheckPaths.removeAll()
            store(result, key: key, revision: revision)
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            snapshot = nil
            cache.removeValue(forKey: key)
        }
    }

    /// A commit in one checkout moves only that checkout's ancestry. Recheck that
    /// row in place: every other row keeps the result — and the group — it already
    /// has, instead of the whole list being invalidated and regrouped mid-look.
    func recheck(path: String) async {
        guard let repo = currentRepo, let previous = snapshot else { return }
        let target = currentTarget
        let key = Key(path: repo.path, target: target)
        let token = UUID()
        generation = token
        recheckPaths.insert(path)
        try? await Task.sleep(for: scanDebounce)
        guard !Task.isCancelled, generation == token else { return }
        defer { if generation == token { recheckPaths.remove(path) } }
        guard let result = try? await service.scan(repoPath: repo.path, targetOverride: target),
              generation == token, !Task.isCancelled,
              let fresh = result.entries.first(where: { $0.id == path }) else { return }
        var entries = previous.entries
        guard let index = entries.firstIndex(where: { $0.id == path }) else { return }
        entries[index] = fresh
        let merged = CleanupSnapshot(targets: previous.targets, target: previous.target,
                                     entries: entries, checkedAt: previous.checkedAt)
        snapshot = merged
        store(merged, key: key, revision: cache[key]?.revision)
    }

    /// The most recent scan for exactly this repository and comparison branch, while
    /// it is still fresh. The cleanup sheet opens on it instead of scanning again.
    func cachedSnapshot(repoPath: String, target: String?) -> CleanupSnapshot? {
        guard let cached = cache[Key(path: repoPath, target: target)],
              Date().timeIntervalSince(cached.snapshot.checkedAt) < Self.reuseWindow else { return nil }
        return cached.snapshot
    }

    /// Take over a scan someone else already ran for this repository — the cleanup
    /// sheet's — so the rows show it without repeating the work.
    func adopt(_ snapshot: CleanupSnapshot, repoPath: String, target: String?, revision: Int?) {
        let key = Key(path: repoPath, target: target)
        store(snapshot, key: key, revision: revision)
        guard currentRepo?.path == repoPath, currentTarget == target else { return }
        self.snapshot = snapshot
        recheckPaths.removeAll()
    }

    private func store(_ snapshot: CleanupSnapshot, key: Key, revision: Int?) {
        cache[key] = Cached(snapshot: snapshot, revision: revision)
        if cache.count > 8, let oldest = cache.min(by: { $0.value.snapshot.checkedAt < $1.value.snapshot.checkedAt })?.key {
            cache.removeValue(forKey: oldest)
        }
    }

    /// Active-file edits affect only this row, not the merge results for every worktree.
    func entry(for path: String, localStatus: StatusResult? = nil, localChangeCount: Int = 0) -> WorktreeMergeEntry? {
        guard var entry = snapshot?.entries.first(where: { $0.id == path }) else { return nil }
        var isRechecking = recheckPaths.contains(path)
        var count = localChangeCount
        if let localStatus, !entry.isBroken {
            let changes = localStatus.changes.filter { $0.worktreeStatus != .ignored }
            entry.hasLocalChanges = !changes.isEmpty
            count = changes.count
            // A commit here does not make the previous merge result meaningless —
            // it makes it stale. Keep it, and say the row is being rechecked.
            if let head = localStatus.oid, !head.isEmpty, head != entry.worktree.head { isRechecking = true }
        }
        return WorktreeMergeEntry(entry: entry, isRechecking: isRechecking, localChangeCount: count)
    }
}
