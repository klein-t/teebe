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

    @Test("manual Refresh fetches even when automatic fetching is disabled")
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
        #expect(git.fetchedRepos.count == 3)
        // Manual refresh does not turn background fetching back on.
        let restored = AppModel(environment: makeTestEnvironment(git: git, store: app.environment.store))
        await restored.selector.selectRepo(Repository(path: "/repo"))
        #expect(!restored.fetchAutomatically)
        #expect(restored.preferences.defaults.fetchAutomatically == true)
    }

    @Test("a remote that cannot be reached is silent, and does not block the next window")
    func failureIsSilent() async {
        let git = FakeGitClient()
        git.fetchError = .commandFailed(command: ["git", "fetch"], exitCode: 128, stderr: "Host key verification failed")
        let app = await app(git)

        let revision = app.selector.mergeRevision
        await app.refreshRemotes(force: false)

        #expect(app.selector.mergeRevision == revision)
        #expect(git.fetchedRepos == ["/repo"])
        #expect(app.errorMessage == nil)
        #expect(app.selector.errorMessage == nil)
    }

    @Test("background fetches leave the SSH agent out; Refresh uses it")
    func fetchKinds() async {
        let git = FakeGitClient()
        let app = await app(git)

        await app.refreshRemotes(force: false)
        await app.refreshRemotes(force: true)

        #expect(git.fetchKinds == [.automatic, .manual])
    }

    @Test("Refresh during a background fetch waits for it, then fetches with the agent, without an error")
    func refreshJoinsBackgroundFetch() async {
        let git = FakeGitClient()
        // Only the agent's key opens this remote, so the background fetch fails.
        git.needsAgent = true
        let app = await app(git)
        let gate = Gate()
        git.fetchGate = { await gate.wait() }

        let background = Task { await app.refreshRemotes(force: false) }
        while git.fetchedRepos.isEmpty { await Task.yield() }
        let refresh = Task { await app.refreshRemotes(force: true) }
        for _ in 0..<50 { await Task.yield() }
        // Still waiting on the background fetch, not failed on the spot.
        #expect(app.isFetching)
        #expect(app.fetchError == nil)
        #expect(git.fetchKinds == [.automatic])

        await gate.open()
        await background.value
        await refresh.value
        #expect(git.fetchKinds == [.automatic, .manual])
        #expect(app.fetchError == nil)
        #expect(!app.isFetching)
    }

    @Test("overlapping Refreshes share one fetch and its result")
    func refreshesShareAFetch() async {
        let git = FakeGitClient()
        let gate = Gate()
        git.fetchGate = { await gate.wait() }
        let refresher = RemoteRefresher(git: git)

        let first = Task { await refresher.fetch(repoPath: "/repo", force: true) }
        while git.fetchedRepos.isEmpty { await Task.yield() }
        let second = Task { await refresher.fetch(repoPath: "/repo", force: true) }
        for _ in 0..<50 { await Task.yield() }
        await gate.open()

        #expect(await first.value)
        #expect(await second.value)
        #expect(git.fetchKinds == [.manual])
    }

    @Test("a background fetch is skipped while another fetch is running")
    func backgroundSkipsWhileFetching() async {
        let git = FakeGitClient()
        let gate = Gate()
        git.fetchGate = { await gate.wait() }
        let refresher = RemoteRefresher(git: git)

        let manual = Task { await refresher.fetch(repoPath: "/repo", force: true) }
        while git.fetchedRepos.isEmpty { await Task.yield() }
        #expect(await refresher.fetch(repoPath: "/repo", force: false) == false)
        await gate.open()

        #expect(await manual.value)
        #expect(git.fetchKinds == [.manual])
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

    @Test("a successful background fetch invalidates merge checks without a watcher event")
    func fetchInvalidatesMergeChecksInLowPower() async {
        let git = FakeGitClient()
        let app = await app(git)
        await app.selector.setLowPower(true)
        let revision = app.selector.mergeRevision

        await app.refreshRemotes(force: false)

        #expect(git.fetchedRepos == ["/repo"])
        #expect(app.selector.mergeRevision > revision)
    }

    @Test("a completed fetch cannot invalidate a repository selected later")
    func fetchCompletionIsRepositoryScoped() async {
        let git = FakeGitClient()
        let app = await app(git)
        let gate = Gate()
        git.fetchGate = { await gate.wait() }
        let fetch = Task { await app.refreshRemotes(force: false) }
        while git.fetchedRepos.isEmpty { await Task.yield() }
        await app.selector.selectRepo(Repository(path: "/another"))
        let revision = app.selector.mergeRevision
        await gate.open()
        await fetch.value
        #expect(app.selector.mergeRevision == revision)
    }

    @Test("a successful fetch refreshes the sync arrows and remote facts")
    func fetchRefreshesSyncFacts() async {
        let git = FakeGitClient()
        let app = await app(git)
        let primary = Worktree(path: "/repo", branch: "main", isPrimary: true)
        #expect(app.selector.info(for: primary).behind == 0)

        // The fetch brought in two commits on origin/main.
        git.statusResult = StatusResult(branch: "main", upstream: "origin/main", behind: 2)
        await app.refreshRemotes(force: true)
        #expect(app.selector.info(for: primary).behind == 2)
        #expect(app.selector.info(for: primary).remote == .sameBranch(remote: "origin", ahead: 0, behind: 2))
    }

    @Test("remote ref changes seen by the watcher refresh the sync facts too")
    func remoteRefEventsRefreshSyncFacts() async {
        let git = FakeGitClient()
        let app = await app(git)
        let primary = Worktree(path: "/repo", branch: "main", isPrimary: true)
        // A fetch run from a terminal deleted the remote branch.
        git.statusResult = StatusResult(branch: "main", upstream: "origin/main", isUpstreamGone: true)
        await app.selector.handleRepoWatchEvent(["/repo/.git/refs/remotes/origin/main"])
        #expect(app.selector.info(for: primary).remote == .remoteDeleted)
    }
}
