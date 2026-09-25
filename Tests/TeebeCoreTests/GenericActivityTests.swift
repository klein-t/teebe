import Foundation
import Testing
@testable import TeebeCore

@Suite("Harness-agnostic activity")
struct GenericActivityTests {
    let primary = "/Users/k/katast"
    let nested = "/Users/k/katast/.claude/worktrees/avm-v1"
    let lens = "/private/tmp/katast-housing-affordability"
    var worktrees: [String] { [primary, nested, lens] }

    @Test("file events count for their deepest worktree, except Git bookkeeping, build output and caches")
    func routing() {
        #expect(WorktreeActivityRouter.changedWorktrees(
            eventPaths: [lens + "/web/lib/housing-affordability.test.ts"], among: worktrees) == [lens])
        #expect(WorktreeActivityRouter.changedWorktrees(
            eventPaths: [nested + "/src/a.py", primary + "/README.md"], among: worktrees) == [nested, primary])
        #expect(WorktreeActivityRouter.changedWorktrees(eventPaths: [
            primary + "/.git/index", primary + "/web/node_modules/.vite/deps/x.js", lens + "/web/.next/cache/a",
            lens + "/src/katast/__pycache__/maps.cpython-313.pyc", lens + "/.DS_Store", "/elsewhere/file.txt"
        ], among: worktrees).isEmpty)
        // Only components below the worktree root are checked: a checkout that
        // itself lives under a folder called build still reports its edits.
        #expect(WorktreeActivityRouter.changedWorktrees(
            eventPaths: ["/Users/k/build/app/src/main.swift"], among: ["/Users/k/build/app"]) == ["/Users/k/build/app"])
    }

    @Test("a process counts when it burns CPU in the worktree; shells, agent UIs, editors and Teebe don't")
    func processRule() {
        func sample(_ pid: Int32, _ name: String, cwd: String, cpu: Double, parent: Int32 = 1,
                    parentName: String = "zsh") -> ProcessSample {
            ProcessSample(pid: pid, parentPID: parent, name: name, parentName: parentName, cwd: cwd, cpuSeconds: cpu)
        }
        let samples = [
            sample(10, "python3.13", cwd: lens + "/web", cpu: 12.0),            // pytest: busy
            sample(11, "zsh", cwd: primary, cpu: 90.0),                         // a shell
            sample(12, "2.1.281", cwd: primary, cpu: 900.0),                     // Claude Code's UI
            sample(13, "codex", cwd: primary, cpu: 3_000.0),                     // Codex's UI
            sample(14, "git", cwd: nested, cpu: 1.0, parent: 50, parentName: "Code Helper (Plugin)"),
            sample(15, "git", cwd: nested, cpu: 1.0, parent: 999),                // Teebe's own git
            sample(16, "node", cwd: primary + "/web", cpu: 128.401),              // an idle dev server
            sample(17, "cargo", cwd: nested, cpu: 0.9)                            // new since last sample
        ]
        let previous: [Int32: Double] = [10: 11.0, 11: 80.0, 12: 800.0, 13: 2_000.0, 14: 0, 15: 0, 16: 128.4]
        let active = ProcessActivityProbe.active(samples: samples, previous: previous, elapsed: 3,
                                                 among: worktrees, selfPID: 999)
        #expect(active == [lens, nested])
    }

    @Test("the probe sees a real busy process whose cwd is a worktree, and not after it exits")
    func realProcess() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("teebe-tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let worktree = PathUtil.standardized(dir.path)
        // The test runner stands in for the agent that launched the command.
        let probe = ProcessActivityProbe(selfPID: -1)
        _ = probe.activeWorktrees(among: [worktree])
        let busy = Process()
        busy.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
        busy.currentDirectoryURL = dir
        busy.standardOutput = FileHandle.nullDevice
        try busy.run()
        Thread.sleep(forTimeInterval: 1.0)
        #expect(probe.activeWorktrees(among: [worktree]) == [worktree])
        busy.terminate()
        busy.waitUntilExit()
        Thread.sleep(forTimeInterval: 0.3)
        #expect(probe.activeWorktrees(among: [worktree]).isEmpty)
    }
}
