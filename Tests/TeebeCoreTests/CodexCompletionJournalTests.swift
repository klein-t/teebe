import Foundation
import Testing
@testable import TeebeCore

@Suite("Codex completion journal")
struct CodexCompletionJournalTests {
    private let epoch = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func readsEveryCompletionBeyondTheStatusTailAndAcrossPartialLines() throws {
        let rig = try Fixture(); defer { rig.cleanUp() }
        let scanner = CodexRolloutScanner(sessionsRoot: rig.root, tailBytes: 512)
        #expect(scanner.turnEnds(forWorktreePaths: ["/repo"], now: epoch).isEmpty)
        let end = line("task_complete", turn: "one", at: epoch.addingTimeInterval(1))
        try rig.append(String(end.prefix(end.count / 2)))
        #expect(scanner.turnEnds(forWorktreePaths: ["/repo"], now: epoch.addingTimeInterval(2)).isEmpty)
        try rig.append(String(end.suffix(end.count - end.count / 2)) + "\n")
        try rig.append(String(repeating: line("token_count", at: epoch.addingTimeInterval(3)) + "\n", count: 3_000))
        try rig.append(line("task_complete", turn: "two", at: epoch.addingTimeInterval(4)) + "\n")
        let ends = scanner.turnEnds(forWorktreePaths: ["/repo"], now: epoch.addingTimeInterval(5))
        #expect(Set(ends.map(\.id)) == ["codex:session:one", "codex:session:two"])
        #expect(scanner.turnEnds(forWorktreePaths: ["/repo"], now: epoch.addingTimeInterval(6)).count == 2)
    }

    @Test func startupDuringAPartialMetadataWriteStillFindsTheNextTurn() throws {
        let rig = try Fixture(); defer { rig.cleanUp() }
        let midpoint = rig.meta.count / 2
        try String(rig.meta.prefix(midpoint)).write(to: rig.file, atomically: true, encoding: .utf8)
        let scanner = CodexRolloutScanner(sessionsRoot: rig.root)
        #expect(scanner.turnEnds(forWorktreePaths: ["/repo"], now: epoch).isEmpty)
        try rig.append(String(rig.meta.suffix(rig.meta.count - midpoint)))
        try rig.append(line("task_complete", turn: "one", at: epoch.addingTimeInterval(1)) + "\n")
        let ends = scanner.turnEnds(forWorktreePaths: ["/repo"], now: epoch.addingTimeInterval(2))
        #expect(ends.map(\.id) == ["codex:session:one"])
    }

    @Test func newlyDiscoveredFilesAndReplacementsKeepStableTurnIdentity() throws {
        let rig = try Fixture(); defer { rig.cleanUp() }
        let scanner = CodexRolloutScanner(sessionsRoot: rig.root)
        _ = scanner.turnEnds(forWorktreePaths: ["/repo"], now: epoch)
        let end = line("task_complete", turn: "one", at: epoch.addingTimeInterval(1)) + "\n"
        try rig.append(end)
        let first = scanner.turnEnds(forWorktreePaths: ["/repo"], now: epoch.addingTimeInterval(2))
        try (rig.meta + end).write(to: rig.file, atomically: true, encoding: .utf8)
        #expect(scanner.turnEnds(forWorktreePaths: ["/repo"], now: epoch.addingTimeInterval(3)) == first)
        let newFile = rig.file.deletingLastPathComponent().appendingPathComponent("rollout-new.jsonl")
        let newContent = rig.meta.replacingOccurrences(of: #""id":"session""#, with: #""id":"new-session""#)
            + line("task_complete", turn: "old", at: epoch.addingTimeInterval(-1)) + "\n"
            + line("task_complete", turn: "new", at: epoch.addingTimeInterval(4)) + "\n"
        try newContent.write(to: newFile, atomically: true, encoding: .utf8)
        #expect(scanner.turnEnds(forWorktreePaths: ["/repo"], now: epoch.addingTimeInterval(5)).count == 2)
    }

    @Test(arguments: [#"{"subagent":{"thread_spawn":{"parent_thread_id":"parent"}}}"#,
                      #"{"subagent":{"other":"guardian"}}"#])
    func ignoresSubagentAndGuardianCompletions(source: String) throws {
        let rig = try Fixture(source: source); defer { rig.cleanUp() }
        let scanner = CodexRolloutScanner(sessionsRoot: rig.root)
        _ = scanner.turnEnds(forWorktreePaths: ["/repo"], now: epoch)
        try rig.append(line("task_complete", turn: "one", at: epoch.addingTimeInterval(1)) + "\n")
        #expect(scanner.turnEnds(forWorktreePaths: ["/repo"], now: epoch.addingTimeInterval(2)).isEmpty)
    }

    @Test func attributesEachTurnToItsOwnWorktreeAndDoesNotReplayOnRestart() throws {
        let rig = try Fixture(); defer { rig.cleanUp() }
        let scanner = CodexRolloutScanner(sessionsRoot: rig.root)
        let paths = ["/repo", "/sibling"]
        _ = scanner.turnEnds(forWorktreePaths: paths, now: epoch)
        try rig.append(line("task_started", turn: "one", at: epoch.addingTimeInterval(1)) + "\n")
        let command: [String: Any] = ["timestamp": stamp(epoch.addingTimeInterval(2)), "type": "response_item",
                                      "payload": ["type": "function_call", "call_id": "c1", "name": "exec_command",
                                                  "arguments": #"{"workdir":"/sibling","cmd":"true"}"#]]
        let commandData = try JSONSerialization.data(withJSONObject: command)
        let commandLine = try #require(String(data: commandData, encoding: .utf8))
        try rig.append(commandLine + "\n")
        try rig.append(line("task_complete", turn: "one", at: epoch.addingTimeInterval(3)) + "\n")
        try rig.append(line("task_started", turn: "two", at: epoch.addingTimeInterval(4)) + "\n")
        try rig.append(line("turn_aborted", turn: "two", at: epoch.addingTimeInterval(5)) + "\n")
        let ends = scanner.turnEnds(forWorktreePaths: paths, now: epoch.addingTimeInterval(6))
        #expect(ends.first { $0.id == "codex:session:one" }?.worktreePath == "/sibling")
        #expect(ends.first { $0.id == "codex:session:two" }?.worktreePath == "/repo")
        #expect(ends.first { $0.id == "codex:session:two" }?.completed == false)
        let restarted = CodexRolloutScanner(sessionsRoot: rig.root)
        #expect(restarted.turnEnds(forWorktreePaths: paths, now: epoch.addingTimeInterval(7)).isEmpty)
    }

    @Test func launchDoesNotReadOldRolloutsButStillFindsTheirLaterTurns() throws {
        let rig = try Fixture(); defer { rig.cleanUp() }
        let now = Date()
        let end = line("task_complete", turn: "one", at: now.addingTimeInterval(1))
        try rig.append(String(end.prefix(end.count / 2)))
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3_600)],
                                              ofItemAtPath: rig.file.path)
        let recent = rig.file.deletingLastPathComponent().appendingPathComponent("rollout-recent.jsonl")
        try rig.meta.replacingOccurrences(of: #""id":"session""#, with: #""id":"recent""#)
            .write(to: recent, atomically: true, encoding: .utf8)
        var opened: [String] = []
        var summarized: [String] = []
        let journal = CodexCompletionJournal { url in
            opened.append(url.lastPathComponent)
            return try? FileHandle(forReadingFrom: url)
        }
        let scanner = CodexRolloutScanner(sessionsRoot: rig.root)
        func read(at date: Date) -> [AgentTurnEnd] {
            journal.read(files: [rig.file, recent], paths: ["/repo"], now: date) { url in
                summarized.append(url.lastPathComponent)
                return scanner.summary(of: url, id: CodexRolloutScanner.threadID(of: url))
            }
        }
        #expect(read(at: now).isEmpty)
        #expect(opened.isEmpty)
        #expect(summarized == ["rollout-recent.jsonl"])
        try rig.append(String(end.suffix(end.count - end.count / 2)) + "\n")
        let ends = read(at: now.addingTimeInterval(2))
        #expect(ends.map(\.id) == ["codex:session:one"])
        #expect(ends.first?.worktreePath == "/repo")
    }

    @Test func aPollListsRolloutsOnceAndTheNextPollReadsFilesAddedMeanwhile() throws {
        let rig = try Fixture(); defer { rig.cleanUp() }
        let scanner = CodexRolloutScanner(sessionsRoot: rig.root)
        _ = scanner.turnEnds(forWorktreePaths: ["/repo"], now: epoch)
        func addRollout(_ id: String, endingAt date: Date) throws {
            let url = rig.file.deletingLastPathComponent().appendingPathComponent("rollout-\(id).jsonl")
            let text = rig.meta.replacingOccurrences(of: #""id":"session""#, with: #""id":"\#(id)""#)
                + line("task_complete", turn: "one", at: date) + "\n"
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        // Written between two polls: the next poll reads it.
        _ = scanner.states(forWorktreePaths: ["/repo"], now: epoch.addingTimeInterval(1))
        try addRollout("between", endingAt: epoch.addingTimeInterval(2))
        let next = scanner.turnEnds(forWorktreePaths: ["/repo"], now: epoch.addingTimeInterval(3))
        #expect(next.map(\.id) == ["codex:between:one"])
        // Written during a poll, after its listing: the following poll reads it.
        _ = scanner.states(forWorktreePaths: ["/repo"], now: epoch.addingTimeInterval(4))
        try addRollout("during", endingAt: epoch.addingTimeInterval(5))
        _ = scanner.turnEnds(forWorktreePaths: ["/repo"], now: epoch.addingTimeInterval(4))
        _ = scanner.states(forWorktreePaths: ["/repo"], now: epoch.addingTimeInterval(6))
        let later = scanner.turnEnds(forWorktreePaths: ["/repo"], now: epoch.addingTimeInterval(6))
        #expect(Set(later.map(\.id)) == ["codex:between:one", "codex:during:one"])
    }

    @Test func deliveryRejectsHistoryDeduplicatesAndResetsProjectBoundary() {
        var delivery = AgentTurnDelivery()
        delivery.watch(["/repo"], now: epoch)
        let old = AgentTurnEnd(id: "old", worktreePath: "/repo", endedAt: epoch.addingTimeInterval(-1))
        let fresh = AgentTurnEnd(id: "fresh", worktreePath: "/repo", endedAt: epoch.addingTimeInterval(1))
        #expect(delivery.consume([old, fresh, fresh], now: epoch.addingTimeInterval(2)) == [fresh])
        #expect(delivery.consume([fresh], now: epoch.addingTimeInterval(3)).isEmpty)
        delivery.watch([], now: epoch.addingTimeInterval(4))
        delivery.watch(["/repo"], now: epoch.addingTimeInterval(6))
        let away = AgentTurnEnd(id: "away", worktreePath: "/repo", endedAt: epoch.addingTimeInterval(5))
        #expect(delivery.consume([away], now: epoch.addingTimeInterval(7)).isEmpty)
    }

    @Test func resumingDiscardsMutedBacklogAndPreservesNewTurnsAndDeduplication() {
        var delivery = AgentTurnDelivery()
        delivery.watch(["/repo"], now: epoch)
        let delivered = AgentTurnEnd(id: "delivered", worktreePath: "/repo", endedAt: epoch.addingTimeInterval(1))
        #expect(delivery.consume([delivered], now: epoch.addingTimeInterval(2)) == [delivered])
        let muted = AgentTurnEnd(id: "muted", worktreePath: "/repo", endedAt: epoch.addingTimeInterval(3))
        delivery.resumeObservation(now: epoch.addingTimeInterval(4))
        let fresh = AgentTurnEnd(id: "fresh", worktreePath: "/repo", endedAt: epoch.addingTimeInterval(5))
        #expect(delivery.consume([delivered, muted, fresh], now: epoch.addingTimeInterval(6)) == [fresh])
        #expect(delivery.consume([fresh], now: epoch.addingTimeInterval(7)).isEmpty)
    }

    @Test(arguments: [0.0001, 0.0006])
    func resumingDiscardsTheIndistinguishableTimestampBoundary(fraction: TimeInterval) throws {
        var delivery = AgentTurnDelivery()
        delivery.watch(["/repo"], now: epoch.addingTimeInterval(-1))
        let enabledAt = epoch.addingTimeInterval(fraction)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let encodedBoundary = try #require(formatter.date(from: stamp(enabledAt)))
        delivery.resumeObservation(now: enabledAt)
        let ambiguous = AgentTurnEnd(id: "ambiguous", worktreePath: "/repo", endedAt: encodedBoundary)
        let fresh = AgentTurnEnd(id: "fresh", worktreePath: "/repo", endedAt: encodedBoundary.addingTimeInterval(0.001))
        #expect(delivery.consume([ambiguous, fresh], now: epoch.addingTimeInterval(1)) == [fresh])
    }

    private func line(_ type: String, turn: String = "t", at date: Date) -> String {
        #"{"timestamp":"\#(stamp(date))","type":"event_msg","payload":{"type":"\#(type)","turn_id":"\#(turn)"}}"#
    }

    private func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private struct Fixture {
        let root: URL
        let file: URL
        let meta: String

        init(source: String = #""cli""#) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            // This date is in the lookback window of epoch above.
            file = root.appendingPathComponent("2026/09/21/rollout-session.jsonl")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            meta = #"{"type":"session_meta","payload":{"id":"session","cwd":"/repo","source":\#(source)}}"# + "\n"
            try meta.write(to: file, atomically: true, encoding: .utf8)
        }
        func append(_ text: String) throws {
            let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: Data(text.utf8))
        }
        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }
}
