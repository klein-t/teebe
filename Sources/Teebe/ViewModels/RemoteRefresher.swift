import Foundation
import TeebeCore

/// Keeps a repository's remote refs current without anyone asking for it: a quiet
/// `git fetch origin` when the app comes forward or a repository is picked, at most
/// once every few minutes per repository.
///
/// It can never block on a prompt (the git client fetches with terminal prompts and
/// SSH interaction disabled, and leaves the SSH agent out of automatic fetches), it
/// gives up after `timeout`, and a failure is silent: an unreachable remote is not
/// something to interrupt anyone about, and every check the app makes reads local
/// refs either way.
@MainActor
final class RemoteRefresher {
    private let git: GitClient
    /// Shortest gap between two automatic fetches of the same repository.
    var interval: TimeInterval = 300
    /// A fetch that has not answered by then is abandoned.
    var timeout: Duration = .seconds(30)
    private var lastAttempt: [String: Date] = [:]
    private var inFlight: [String: (kind: FetchKind, task: Task<Bool, Never>)] = [:]

    init(git: GitClient) { self.git = git }

    /// Fetch `repoPath` unless it was fetched recently. `force` is the user's
    /// Refresh: it ignores that gap and goes through the SSH agent.
    /// Returns whether the fetch ran and succeeded.
    ///
    /// With a fetch for the repository already running, an automatic one is
    /// skipped. A Refresh waits for it instead of failing: it takes another
    /// Refresh's result, and after an automatic fetch, which had no agent, it
    /// runs its own.
    @discardableResult
    func fetch(repoPath: String, force: Bool, now: Date = Date()) async -> Bool {
        if let running = inFlight[repoPath] {
            guard force else { return false }
            let succeeded = await running.task.value
            if running.kind == .manual { return succeeded }
            return await fetch(repoPath: repoPath, force: true, now: now)
        }
        if !force, let last = lastAttempt[repoPath], now.timeIntervalSince(last) < interval { return false }
        // Recorded before the attempt: a remote that is down must not be retried on
        // every activation either.
        lastAttempt[repoPath] = now
        let kind: FetchKind = force ? .manual : .automatic
        // Cleared by the task itself, so whoever waits on it finds it gone.
        let task = Task {
            let succeeded = await fetchWithTimeout(repoPath, kind: kind)
            inFlight[repoPath] = nil
            return succeeded
        }
        inFlight[repoPath] = (kind, task)
        return await task.value
    }

    /// The fetch races a sleep; whichever finishes first cancels the other. Fetching
    /// is a read, so cancelling it leaves nothing half-written.
    private func fetchWithTimeout(_ repoPath: String, kind: FetchKind) async -> Bool {
        let git = self.git
        let timeout = self.timeout
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { (try? await git.fetchOrigin(repoPath: repoPath, kind: kind)) != nil }
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
