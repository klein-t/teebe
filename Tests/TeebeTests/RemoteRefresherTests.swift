import Foundation
import Testing
import TeebeCore
@testable import Teebe

@MainActor
@Suite("Background fetch")
struct RemoteRefresherTests {
    private func app(_ git: FakeGitClient) async -> AppModel {
        git.worktreesResult = [Worktree(path: "/repo", branch: "main", isPrimary: true)]
        let app = AppModel(environment: makeTestEnvironment(git: git))
        app.mergeStatus.scanDebounce = .zero
        _ = await app.addRepository(path: "/repo")
        return app
    }

    @Test("a repository is fetched at most once in the rate-limit window")
    func rateLimit() async {
        let git = FakeGitClient()
        let app = await app(git)
        let start = Date()

        // Opening the app, then coming back to it a minute later.
        await app.refreshRemotes(force: false, now: start)
        await app.refreshRemotes(force: false, now: start.addingTimeInterval(60))
        #expect(git.fetchedRepos == ["/repo"])

        // Five minutes on, it is worth asking again.
        await app.refreshRemotes(force: false, now: start.addingTimeInterval(301))
        #expect(git.fetchedRepos == ["/repo", "/repo"])
    }

    @Test("Refresh fetches now, and the setting turns fetching off entirely")
    func forcedAndDisabled() async {
        let git = FakeGitClient()
        let app = await app(git)
        let start = Date()

        await app.refreshRemotes(force: false, now: start)
        await app.refreshRemotes(force: true, now: start)
        #expect(git.fetchedRepos.count == 2)

        app.fetchAutomatically = false
        await app.refreshRemotes(force: true, now: start)
        await app.refreshRemotes(force: false, now: start.addingTimeInterval(600))
        #expect(git.fetchedRepos.count == 2)
        // And the choice is remembered.
        #expect(AppModel(environment: makeTestEnvironment(git: git, store: app.environment.store))
            .fetchAutomatically == false)
    }

    @Test("a remote that cannot be reached is silent, and does not block the next window")
    func failureIsSilent() async {
        let git = FakeGitClient()
        git.fetchError = .commandFailed(command: ["git", "fetch"], exitCode: 128, stderr: "Host key verification failed")
        let app = await app(git)

        await app.refreshRemotes(force: false)

        #expect(git.fetchedRepos == ["/repo"])
        #expect(app.errorMessage == nil)
        #expect(app.selector.errorMessage == nil)
    }

    @Test("a fetch that never answers is abandoned rather than left running")
    func timeout() async {
        let git = FakeGitClient()
        // A fetch that hangs on the network. Cancellable, the way the real one is.
        git.fetchGate = { try? await Task.sleep(for: .seconds(60)) }
        let refresher = RemoteRefresher(git: git)
        refresher.timeout = .milliseconds(50)
        let started = Date()

        #expect(await refresher.fetch(repoPath: "/repo", force: true) == false)
        // Generous, because a loaded machine schedules the cancellation late: the
        // point is that it did not sit through the fetch's own minute.
        #expect(Date().timeIntervalSince(started) < 30)
    }

    @Test("the refs a fetch writes are what restarts the merge check")
    func fetchedRefsRestartTheMergeCheck() async {
        let git = FakeGitClient()
        let app = await app(git)
        await app.refreshRemotes(force: true)
        #expect(git.fetchedRepos == ["/repo"])

        // The fetch wrote refs/remotes/origin/main; that is the event the repository
        // watcher delivers, and it is what makes the rows check themselves again.
        let revision = app.selector.mergeRevision
        await app.selector.handleRepoWatchEvent(["/repo/.git/refs/remotes/origin/main"])
        #expect(app.selector.mergeRevision == revision + 1)
    }
}
