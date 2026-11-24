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

    @Test("claims distinguish local, foreign and unknown worktrees before cwd fallback")
    func claimAcrossKnownWorktrees() {
        let paths = ["/a"]
        let known = ["/a", "/b"]
        #expect(WorktreeAttribution.claim(targets: ["/a/file"], cwd: "/b", among: paths, knownPaths: known) == .here("/a"))
        #expect(WorktreeAttribution.claim(targets: ["/b/file", "/a/old"], cwd: "/a", among: paths, knownPaths: known) == .elsewhere)
        #expect(WorktreeAttribution.claim(targets: [], cwd: "/b/src", among: paths, knownPaths: known) == .elsewhere)
        #expect(WorktreeAttribution.claim(targets: ["/outside"], cwd: "/a", among: paths, knownPaths: known) == .here("/a"))
        #expect(WorktreeAttribution.claim(targets: ["/outside"], cwd: nil, among: paths, knownPaths: known) == .nowhere)
    }

    @Test("nested worktrees win across scan boundaries and aliases keep the local path")
    func claimPrefersDeepestKnownWorktree() {
        let known = ["/a", "/a/nested"]
        #expect(WorktreeAttribution.claim(targets: ["/a/nested/file"], cwd: "/a", among: ["/a"], knownPaths: known) == .elsewhere)
        #expect(WorktreeAttribution.claim(targets: [], cwd: "/a/nested", among: ["/a"], knownPaths: known) == .elsewhere)
        #expect(WorktreeAttribution.claim(targets: ["/a/nested/file"], cwd: "/a", among: known, knownPaths: known) == .here("/a/nested"))
        #expect(WorktreeAttribution.claim(targets: ["file:///tmp/w/file"], cwd: nil,
                                          among: ["/tmp/w"], knownPaths: ["/private/tmp/w/"]) == .here("/tmp/w"))
    }

    @Test("an empty known set preserves the old owner rule")
    func emptyKnownPathsPreserveOwner() {
        let paths = ["/a", "/a/nested", "/private/tmp/w"]
        for targets in [[], ["/outside"], ["/a/nested/file", "/a/file"], ["/tmp/w/file"], Array(repeating: "/outside", count: 20) + ["/a"]] {
            for cwd: String? in [nil, "/outside", "/a", "/a/nested", "/tmp/w"] {
                let expected = WorktreeAttribution.owner(targets: targets, cwd: cwd, among: paths)
                    .map { WorktreeAttribution.Claim.here($0) } ?? .nowhere
                #expect(WorktreeAttribution.claim(targets: targets, cwd: cwd, among: paths, knownPaths: []) == expected)
            }
        }
    }

    @Test("known worktrees report set changes including removals")
    func knownWorktreesTrackSetChanges() {
        let known = KnownWorktrees()
        #expect(known.paths.isEmpty)
        #expect(!known.update([]))
        #expect(known.update(["/a", "/b"]))
        #expect(!known.update(["/b", "/a", "/a"]))
        #expect(Set(known.paths) == ["/a", "/b"])
        #expect(known.update(["/b"]))
        #expect(known.paths == ["/b"])
        #expect(known.update([]))
    }
}
