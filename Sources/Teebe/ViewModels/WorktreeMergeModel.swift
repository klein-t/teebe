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

/// Row results can be reused while refreshing, keyed by repository and extra merge
/// target, so switching back and forth does not rescan every worktree. Results are
/// stale-while-revalidate: rows keep their last result until a new one completes.
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
    /// The current full refresh. Only a refresh replaces it: a row recheck has its
    /// own request, so it can never discard a refresh or leave `isChecking` on.
    private var generation = UUID()
    private struct Key: Hashable { let path: String; let extraTarget: String? }
    private struct Cached { let snapshot: CleanupSnapshot; let revision: Int? }
    private var cache: [Key: Cached] = [:]
    /// What the rows currently show, so a single-row recheck knows what to scan.
    private var currentRepo: Repository?
    private var currentExtraTarget: String?
    /// Orders requests and scans: a result answers a request only when its scan
    /// began after the request was made.
    private var clock = 0
    /// Checkouts whose HEAD moved and are being rechecked in place, with when.
    private var recheckRequests: [String: Int] = [:]
    /// When the scan behind the last full result shown began.
    private var publishedScan = 0
    /// Full-refresh scans running now, and the rechecks waiting for them to land.
    private var refreshScans = 0
    private var refreshWaiters: [CheckedContinuation<Void, Never>] = []

    init(service: WorktreeCleanupChecking) { self.service = service }

    func refresh(repo: Repository?, extraTarget: String?, enabled: Bool, revision: Int? = nil) async {
        let token = UUID()
        generation = token
        isChecking = false
        guard enabled, let repo else {
            snapshot = nil
            cache.removeAll()
            currentRepo = nil
            recheckRequests.removeAll()
            return
        }
        let sameRepository = currentRepo?.path == repo.path
        currentRepo = repo
        currentExtraTarget = extraTarget
        let key = Key(path: repo.path, extraTarget: extraTarget)
        // Keep what the rows show until a result replaces it: within one repository
        // a ✓ must not blink out while an extra target or new commits are rechecked.
        if let cached = cache[key]?.snapshot {
            snapshot = cached
        } else if !sameRepository {
            snapshot = nil
        }
        // `.task(id:)` restarts on every key change, and a commit or a `git worktree
        // add` can bump the key repeatedly within a second. Let the burst settle so
        // one scan runs instead of a queue of cancelled ones.
        try? await Task.sleep(for: scanDebounce)
        guard !Task.isCancelled, generation == token else { return }
        // The key changed for a reason that cannot move merge ancestry — an
        // extra-target switch back, or a rescan after a removal. Show the result
        // that is already in hand, don't repeat the work.
        if let revision, let cached = cache[key], cached.revision == revision,
           Date().timeIntervalSince(cached.snapshot.checkedAt) < Self.reuseWindow {
            snapshot = cached.snapshot
            return
        }
        isChecking = true
        defer { if generation == token { isChecking = false } }
        let started = tick()
        refreshScans += 1
        defer { endRefreshScan() }
        do {
            let result = try await service.scan(repoPath: repo.path, extraTarget: extraTarget)
            guard generation == token, !Task.isCancelled else { return }
            publish(result, scannedAt: started, key: key, revision: revision)
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            snapshot = nil
            cache.removeValue(forKey: key)
        }
    }

    /// A commit in one checkout moves only that checkout's ancestry. Recheck that
    /// row in place: every other row keeps the result — and the group — it already
    /// has, instead of the whole list being invalidated and regrouped mid-look.
    /// The scanner checks a whole repository at a time, so a recheck never races a
    /// refresh: it waits for one already scanning, and a refresh that began after it
    /// was asked for answers it. When a merge target moved, every row's result is
    /// stale, so the whole new result is shown.
    func recheck(path: String) async {
        guard currentRepo != nil, snapshot != nil else { return }
        let request = tick()
        recheckRequests[path] = request
        defer { if recheckRequests[path] == request { recheckRequests[path] = nil } }
        try? await Task.sleep(for: scanDebounce)
        while refreshScans > 0 { await withCheckedContinuation { refreshWaiters.append($0) } }
        guard !Task.isCancelled, recheckRequests[path] == request, let repo = currentRepo else { return }
        let extraTarget = currentExtraTarget
        let started = tick()
        guard let result = try? await service.scan(repoPath: repo.path, extraTarget: extraTarget),
              !Task.isCancelled, recheckRequests[path] == request, publishedScan < started,
              currentRepo?.path == repo.path, currentExtraTarget == extraTarget,
              let current = snapshot else { return }
        let key = Key(path: repo.path, extraTarget: extraTarget)
        guard result.mergeTargets == current.mergeTargets else {
            publish(result, scannedAt: started, key: key, revision: cache[key]?.revision)
            return
        }
        guard let fresh = result.entries.first(where: { $0.id == path }),
              let index = current.entries.firstIndex(where: { $0.id == path }) else { return }
        var entries = current.entries
        entries[index] = fresh
        let merged = CleanupSnapshot(targets: result.targets, mergeTargets: current.mergeTargets,
                                     entries: entries, checkedAt: current.checkedAt)
        snapshot = merged
        store(merged, key: key, revision: cache[key]?.revision)
    }

    private func tick() -> Int {
        clock += 1
        return clock
    }

    /// Show a whole scan's result. Rechecks asked for before it began are answered.
    private func publish(_ result: CleanupSnapshot, scannedAt started: Int, key: Key, revision: Int?) {
        snapshot = result
        publishedScan = max(publishedScan, started)
        recheckRequests = recheckRequests.filter { $0.value > started }
        store(result, key: key, revision: revision)
    }

    private func endRefreshScan() {
        refreshScans -= 1
        guard refreshScans == 0 else { return }
        let waiters = refreshWaiters
        refreshWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
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
        var isRechecking = recheckRequests[path] != nil
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
