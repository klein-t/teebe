import Darwin
import Foundation
import Testing
import TeebeCore
@testable import Teebe

@Suite("Bounded Claude terminal registry")
struct ClaudeTerminalRegistryTests {
    let projects = URL(fileURLWithPath: "/private/tmp/demo/projects")

    func file(pid: Int32 = 42, session: String = "one") throws -> ClaudeTerminalRegistry.File {
        let data = try JSONSerialization.data(withJSONObject: [
            "pid": pid, "sessionId": session, "kind": "interactive", "entrypoint": "cli", "pidDomain": "darwin",
            "procStart": "Mon Nov 23 10:54:18 2026", "cwd": "/same/project"
        ])
        return ClaudeTerminalRegistry.File(data: data, owner: getuid(), regular: true, size: Int64(data.count),
                                           modifiedSeconds: 2_000_000_000, modifiedNanoseconds: 0)
    }

    @Test("only the configured sibling registry is read; key names never reach the file reader")
    func locationAndKeys() throws {
        let entry = try file()
        var reads: [String] = []
        let registry = ClaudeTerminalRegistry(names: { root, _ in
            #expect(root.path == "/private/tmp/demo/sessions")
            return ["42.json", "42." + String(repeating: "0", count: 64) + ".key"]
        }, read: { url, _ in reads.append(url.lastPathComponent); return entry })
        #expect(registry.find(sessionID: "one", projectsRoot: projects, deadline: TerminalRouteDeadline())?.registration.pid == 42)
        #expect(reads == ["42.json"])
    }

    @Test("session ID selects its own process when several sessions share a working directory")
    func sessionIdentity() throws {
        let entries = ["42.json": try file(), "43.json": try file(pid: 43, session: "two")]
        let registry = ClaudeTerminalRegistry(names: { _, _ in Array(entries.keys) }, read: { url, _ in entries[url.lastPathComponent] })
        #expect(registry.find(sessionID: "one", projectsRoot: projects, deadline: TerminalRouteDeadline())?.registration.pid == 42)
        #expect(registry.find(sessionID: "two", projectsRoot: projects, deadline: TerminalRouteDeadline())?.registration.pid == 43)
        #expect(registry.find(sessionID: "missing", projectsRoot: projects, deadline: TerminalRouteDeadline()) == nil)
    }

    @Test("duplicate session IDs fail even when the PIDs differ")
    func duplicate() throws {
        let entries = ["42.json": try file(), "43.json": try file(pid: 43)]
        let registry = ClaudeTerminalRegistry(names: { _, _ in Array(entries.keys) }, read: { url, _ in entries[url.lastPathComponent] })
        #expect(registry.find(sessionID: "one", projectsRoot: projects, deadline: TerminalRouteDeadline()) == nil)
    }

    @Test("unsafe metadata, malformed data and filename PID mismatch fail closed", arguments: 0..<9)
    func rejection(kind: Int) throws {
        var entry = try file()
        switch kind {
        case 0: entry.owner += 1
        case 1: entry.regular = false
        case 2: entry.size = Int64(ClaudeTerminalRegistry.maximumBytes + 1)
        case 3: entry.size = 0
        case 4: entry.size += 1
        case 5: entry.data = Data("{".utf8); entry.size = 1
        case 6: entry = try file(pid: 43)
        default: break
        }
        let registry = ClaudeTerminalRegistry(names: { _, _ in [kind == 7 ? "0042.json" : "42.json"] },
                                              read: { _, _ in kind == 8 ? nil : entry })
        #expect(registry.find(sessionID: "one", projectsRoot: projects, deadline: TerminalRouteDeadline()) == nil)
    }

    @Test("a malformed extra JSON file prevents proving uniqueness")
    func unreadableCandidate() throws {
        let entry = try file()
        let registry = ClaudeTerminalRegistry(names: { _, _ in ["42.json", "43.json"] },
                                              read: { url, _ in url.lastPathComponent == "42.json" ? entry : nil })
        #expect(registry.find(sessionID: "one", projectsRoot: projects, deadline: TerminalRouteDeadline()) == nil)
    }

    @Test("missing directories, count limits and expired deadlines do not read any files")
    func bounds() {
        for names in [nil, [], (1...257).map { "\($0).json" }, Array(repeating: "ignored", count: 1_025)] as [[String]?] {
            let registry = ClaudeTerminalRegistry(names: { _, _ in names }, read: { _, _ in
                Issue.record("Unexpected file read")
                return nil
            })
            #expect(registry.find(sessionID: "one", projectsRoot: projects, deadline: TerminalRouteDeadline()) == nil)
        }
        let registry = ClaudeTerminalRegistry(names: { _, _ in Issue.record("Unexpected directory read"); return nil })
        #expect(registry.find(sessionID: "one", projectsRoot: projects, deadline: TerminalRouteDeadline(seconds: 0)) == nil)
    }

    @Test("real reads reject symlinks, directories and oversized registry files", arguments: 0..<4)
    func realFileTypes(kind: Int) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let projects = root.appendingPathComponent("projects")
        let sessions = ClaudeTerminalRegistry.sessionsRoot(projectsRoot: projects)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let url = sessions.appendingPathComponent("42.json")
        let entry = try file()
        switch kind {
        case 0: try entry.data.write(to: url)
        case 1:
            let target = root.appendingPathComponent("fixture.json")
            try entry.data.write(to: target)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        case 2: try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        default: try Data(repeating: 32, count: ClaudeTerminalRegistry.maximumBytes + 1).write(to: url)
        }
        let result = ClaudeTerminalRegistry().find(sessionID: "one", projectsRoot: projects, deadline: TerminalRouteDeadline())
        #expect((result != nil) == (kind == 0))
    }
}
