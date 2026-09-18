import Foundation
import TeebeCore

/// Keeps a repository's remote refs current without anyone asking for it: a quiet
/// `git fetch origin` when the app comes forward or a repository is picked, at most
/// once every few minutes per repository.
///
/// It can never block on a prompt (the git client fetches with terminal prompts and
/// SSH interaction disabled), it gives up after `timeout`, and a failure is silent:
/// an unreachable remote is not something to interrupt anyone about, and every check
/// the app makes reads local refs either way.
@MainActor
final class RemoteRefresher {
    private let git: GitClient
    /// Shortest gap between two automatic fetches of the same repository.
    var interval: TimeInterval = 300
    /// A fetch that has not answered by then is abandoned.
    var timeout: Duration = .seconds(30)
    private var lastAttempt: [String: Date] = [:]
    private var inFlight: Set<String> = []

    init(git: GitClient) { self.git = git }

    /// Fetch `repoPath` unless it was fetched recently. `force` ignores that gap.
    /// Returns whether the fetch ran and succeeded.
    @discardableResult
    func fetch(repoPath: String, force: Bool, now: Date = Date()) async -> Bool {
        guard !inFlight.contains(repoPath) else { return false }
        if !force, let last = lastAttempt[repoPath], now.timeIntervalSince(last) < interval { return false }
        // Recorded before the attempt: a remote that is down must not be retried on
        // every activation either.
        lastAttempt[repoPath] = now
        inFlight.insert(repoPath)
        defer { inFlight.remove(repoPath) }
        return await fetchWithTimeout(repoPath)
    }

    /// The fetch races a sleep; whichever finishes first cancels the other. Fetching
    /// is a read, so cancelling it leaves nothing half-written.
    private func fetchWithTimeout(_ repoPath: String) async -> Bool {
        let git = self.git
        let timeout = self.timeout
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { (try? await git.fetchOrigin(repoPath: repoPath)) != nil }
            group.addTask {
                guard (try? await Task.sleep(for: timeout)) != nil else { return false }
                return false
            }
            let finished = await group.next() ?? false
            group.cancelAll()
            return finished
        }
    }
}
