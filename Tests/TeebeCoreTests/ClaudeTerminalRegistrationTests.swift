import Foundation
import Testing
@testable import TeebeCore

@Suite("Claude registry process identity")
struct ClaudeTerminalRegistrationTests {
    func record(_ changes: [String: Any] = [:]) throws -> ClaudeTerminalRegistration {
        var object: [String: Any] = ["pid": 42, "sessionId": "session", "kind": "interactive", "entrypoint": "cli",
                                      "procStart": "Mon Nov 23 10:54:18 2026", "pidDomain": "darwin"]
        object.merge(changes) { _, new in new }
        return try JSONDecoder().decode(ClaudeTerminalRegistration.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @Test("only an interactive Darwin CLI with the exact PID and session matches")
    func fields() throws {
        #expect(try record().matches(sessionID: "session", filePID: 42))
        for change: [String: Any] in [["pid": 43], ["pid": 0], ["sessionId": "other"], ["kind": "headless"],
                                     ["entrypoint": "sdk"], ["pidDomain": "linux"], ["procStart": ""]] {
            #expect(try !record(change).matches(sessionID: "session", filePID: 42))
        }
        for key in ["pid", "sessionId", "kind", "entrypoint", "pidDomain", "procStart"] {
            #expect(throws: (any Error).self) { try record([key: NSNull()]) }
        }
        #expect(throws: (any Error).self) { try record(["pid": true]) }
    }

    @Test("kernel epoch agrees exactly with the padded local procStart, independently of DST")
    func localTime() throws {
        let date = try #require(ISO8601DateFormatter().date(from: "2026-11-03T10:54:18Z"))
        let seconds = UInt64(date.timeIntervalSince1970)
        let zone = try #require(TimeZone(identifier: "Europe/Rome"))
        let entry = try record(["procStart": "Tue Nov  3 11:54:18 2026"])
        #expect(entry.matchesStart(seconds: seconds, microseconds: 987_654, fileModifiedSeconds: Int64(seconds + 1),
                                   fileModifiedNanoseconds: 0, timeZone: zone))
        #expect(!entry.matchesStart(seconds: seconds + 1, microseconds: 0, fileModifiedSeconds: Int64(seconds + 5),
                                    fileModifiedNanoseconds: 0, timeZone: zone))
        #expect(!entry.matchesStart(seconds: seconds, microseconds: 0, fileModifiedSeconds: Int64(seconds + 5),
                                    fileModifiedNanoseconds: 0, timeZone: .gmt))
    }

    @Test("same-second PID reuse is rejected when the registry predates the new process")
    func reusedPID() throws {
        let date = try #require(ISO8601DateFormatter().date(from: "2026-11-23T10:54:18Z"))
        let seconds = UInt64(date.timeIntervalSince1970)
        let entry = try record()
        #expect(entry.matchesStart(seconds: seconds, microseconds: 100_000, fileModifiedSeconds: Int64(seconds),
                                   fileModifiedNanoseconds: 400_000_000, timeZone: .gmt))
        #expect(!entry.matchesStart(seconds: seconds, microseconds: 500_000, fileModifiedSeconds: Int64(seconds),
                                    fileModifiedNanoseconds: 400_000_000, timeZone: .gmt))
        #expect(!entry.matchesStart(seconds: seconds + 2, microseconds: 0, fileModifiedSeconds: Int64(seconds + 5),
                                    fileModifiedNanoseconds: 0, timeZone: .gmt))
    }

    @Test("a repeated DST wall-clock time cannot validate a later process")
    func repeatedHour() throws {
        let zone = try #require(TimeZone(identifier: "America/New_York"))
        let first = UInt64(try #require(ISO8601DateFormatter().date(from: "2026-11-01T05:30:00Z")).timeIntervalSince1970)
        let entry = try record(["procStart": "Sun Nov  1 01:30:00 2026"])
        #expect(entry.matchesStart(seconds: first, microseconds: 0, fileModifiedSeconds: Int64(first + 10),
                                   fileModifiedNanoseconds: 0, timeZone: zone))
        #expect(!entry.matchesStart(seconds: first + 3_600, microseconds: 0, fileModifiedSeconds: Int64(first + 10),
                                    fileModifiedNanoseconds: 0, timeZone: zone))
    }

    @Test("app and diagnostics share the projects directory override")
    func rootOverride() {
        #expect(AgentSessionScanner.configuredProjectsRoot(environment: [:]) == AgentSessionScanner.defaultProjectsRoot)
        let projects = AgentSessionScanner.configuredProjectsRoot(environment: ["TEEBE_CLAUDE_PROJECTS_DIR": "/private/tmp/demo/projects"])
        #expect(projects.path == "/private/tmp/demo/projects")
        #expect(AgentSessionScanner(projectsRoot: projects).sessionsRoot.path == "/private/tmp/demo/sessions")
    }
}
