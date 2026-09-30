import Foundation
import Testing
import TeebeCore
@testable import Teebe

@MainActor
@Suite("Native agent signal delivery", .serialized)
struct NativeAgentSignalTests {
    @Test func realNotifyutilReachesHiddenSelectorAndStopsAfterClear() async throws {
        let channel = "dev.teebe.tests." + UUID().uuidString
        let listener = DarwinAgentPingListener(name: channel)
        let git = FakeGitClient()
        git.worktreesResult = [Worktree(path: "/repo", branch: "main", isPrimary: true)]
        let states = FakeAgentStates()
        states["/repo"] = .working
        let spy = NotificationSpy()
        let selector = SelectorModel(environment: makeTestEnvironment(git: git,
            agentStatuses: states.provider, agentProjectsRootPath: "/fake/projects",
            notify: spy.record, agentPing: listener))
        selector.agentPingSettle = 0.02
        await selector.selectRepo(Repository(path: "/repo"))
        await selector.setLowPower(true)
        states["/repo"] = .needsAttention
        try send(channel)
        for _ in 0..<100 where spy.posted.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(selector.info(for: selector.worktrees[0]).agentState == .needsAttention)
        #expect(spy.posted.count == 1)
        try send(channel)
        try await Task.sleep(for: .milliseconds(100))
        #expect(spy.posted.count == 1)
        selector.clearSelection()
        try send(channel)
        try await Task.sleep(for: .milliseconds(100))
        #expect(spy.posted.count == 1)
    }

    @Test func codexWatchEventsAreNotDiscardedByClaudeFiltering() async {
        let git = FakeGitClient()
        git.worktreesResult = [Worktree(path: "/repo", branch: "main", isPrimary: true)]
        let states = FakeAgentStates()
        states["/repo"] = .working
        let spy = NotificationSpy()
        let selector = SelectorModel(environment: makeTestEnvironment(git: git,
            agentStatuses: states.provider, agentProjectsRootPath: "/claude/projects",
            agentExtraWatchPaths: ["/codex/sessions"], notify: spy.record))
        await selector.selectRepo(Repository(path: "/repo"))
        states["/repo"] = .needsAttention
        await selector.handleAgentWatchEvent(["/codex/sessions/2026/09/29/rollout.jsonl"])
        #expect(spy.posted.count == 1)
        states["/repo"] = .working
        await selector.refreshAgentStates()
        selector.notificationsEnabled = false
        states["/repo"] = .needsAttention
        await selector.handleAgentWatchEvent(["/codex/sessions/2026/09/29/rollout.jsonl"])
        #expect(selector.info(for: selector.worktrees[0]).agentState == .needsAttention)
        #expect(spy.posted.count == 1)
    }

    private func send(_ channel: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/notifyutil")
        process.arguments = ["-p", channel]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
