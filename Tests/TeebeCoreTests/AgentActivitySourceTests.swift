import Foundation
import Testing
@testable import TeebeCore

private struct Scripted: AgentActivitySource {
    let states: [String: AgentActivityState]
    func states(forWorktreePaths paths: [String], now: Date) -> [String: AgentActivityState] { states }
}

@Suite("Harness adapters combined")
struct AgentActivitySourceTests {
    @Test("per worktree, waiting beats working beats idle, and unknown paths are dropped")
    func combine() {
        let combined = CombinedAgentActivity([
            Scripted(states: ["/a": .working, "/b": .needsAttention, "/c": .working, "/elsewhere": .working]),
            Scripted(states: ["/a": .needsAttention, "/b": .working, "/c": .idle])
        ])
        let states = combined.states(forWorktreePaths: ["/a", "/b", "/c", "/d"], now: Date())
        #expect(states == ["/a": .needsAttention, "/b": .needsAttention, "/c": .working, "/d": .idle])
    }

    @Test("an agent working is still known when another one there waits")
    func workingIsNotMasked() {
        let combined = CombinedAgentActivity([
            Scripted(states: ["/a": .working, "/b": .needsAttention]),
            Scripted(states: ["/a": .needsAttention, "/c": .idle, "/elsewhere": .working])
        ])
        let paths = ["/a", "/b", "/c"]
        #expect(combined.states(forWorktreePaths: paths, now: Date())["/a"] == .needsAttention)
        #expect(combined.workingPaths(forWorktreePaths: paths, now: Date()) == ["/a"])
    }

    @Test("the deepest containing worktree owns a path; firmlinks and file URLs are normalised")
    func deepest() {
        let paths = ["/r", "/r/.claude/worktrees/x", "/private/tmp/w"]
        #expect(WorktreeAttribution.deepest(containing: "/r/.claude/worktrees/x/src/a.swift", among: paths)
            == "/r/.claude/worktrees/x")
        #expect(WorktreeAttribution.deepest(containing: "/r/src", among: paths) == "/r")
        #expect(WorktreeAttribution.deepest(containing: "/rx/src", among: paths) == nil)
        #expect(WorktreeAttribution.deepest(containing: "/tmp/w/a", among: paths) == "/private/tmp/w")
        #expect(WorktreeAttribution.deepest(containing: "file:///private/tmp/w", among: paths) == "/private/tmp/w")
    }
}
