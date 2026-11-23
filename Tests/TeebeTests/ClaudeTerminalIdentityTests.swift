import Darwin
import Foundation
import Testing
@testable import TeebeCore
@testable import Teebe

@Suite("Claude and Codex identity sources")
struct ClaudeTerminalIdentityTests {
    @Test("Claude resolves without an open transcript and does not scan other process descriptors")
    func claudeRegistry() throws {
        let fixture = try TerminalIdentityFixture()
        defer { fixture.remove() }
        var probe = try fixture.probe()
        var calls: [[String]] = []
        probe.run = { path, arguments, _ in
            #expect(path == "/usr/sbin/lsof")
            calls.append(arguments)
            return Data(fixture.stdio.utf8)
        }
        let anchor = probe.capture(fixture.session(.claude), deadline: TerminalRouteDeadline())
        #expect(anchor?.process.pid == 42)
        #expect(anchor?.surface == fixture.surface)
        #expect(calls == [["-nP", "-a", "-p", "42", "-d", "0,1", "-Ffn"]])
    }

    @Test("dead, reused, foreign, background and tty-less processes fall back", arguments: 0..<7)
    func invalidProcess(kind: Int) throws {
        let fixture = try TerminalIdentityFixture()
        defer { fixture.remove() }
        var probe = try fixture.probe()
        var process = fixture.process(.claude)
        var info = process.info
        switch kind {
        case 1: info.pbi_start_tvsec += 2
        case 2: info.pbi_uid += 1
        case 3: info.pbi_status = UInt32(SZOMB)
        case 4: info.e_tdev = UInt32.max
        case 5: info.e_tpgid += 1
        default: break
        }
        process = NativeTerminalProcess(info: info, name: process.name, arguments: process.arguments,
                                         workspace: process.workspace, surface: process.surface)
        probe.readProcess = { _ in kind == 0 ? nil : process }
        if kind == 6 { probe.run = { _, _, _ in Data("p42\nf0\nn/dev/null\nf1\nn/dev/null\n".utf8) } }
        #expect(probe.capture(fixture.session(.claude), deadline: TerminalRouteDeadline()) == nil)
    }

    @Test("registry changes are read again during revalidation")
    func revalidation() throws {
        let fixture = try TerminalIdentityFixture()
        defer { fixture.remove() }
        var file = try fixture.registryFile()
        var probe = try fixture.probe()
        probe.registry.read = { _, _ in file }
        let anchor = try #require(probe.capture(fixture.session(.claude), deadline: TerminalRouteDeadline()))
        file = try fixture.registryFile(session: "another-session")
        let target = CmuxTerminalTarget(window: UUID(), workspace: fixture.workspace, pane: UUID(),
                                        surface: fixture.surface, tty: "ttys003")
        #expect(!AgentTerminalResolver.revalidate(AgentTerminalRoute(anchor: anchor, target: target),
                                                 probe: probe, deadline: TerminalRouteDeadline()))
    }

    @Test("missing root provenance or a log outside that projects root never reads a registry")
    func isolation() throws {
        let fixture = try TerminalIdentityFixture()
        defer { fixture.remove() }
        var probe = try fixture.probe()
        probe.registry.names = { _, _ in Issue.record("Unexpected registry access"); return nil }
        var session = fixture.session(.claude)
        session.claudeProjectsPath = nil
        #expect(probe.capture(session, deadline: TerminalRouteDeadline()) == nil)
        session.claudeProjectsPath = "/private/tmp/unrelated/projects"
        #expect(probe.capture(session, deadline: TerminalRouteDeadline()) == nil)
    }

    @Test("Codex still needs one live writable transcript owner and never reads the Claude registry", arguments: 0..<3)
    func codexOwnership(kind: Int) throws {
        let fixture = try TerminalIdentityFixture()
        defer { fixture.remove() }
        var probe = try fixture.probe()
        probe.readProcess = { _ in fixture.process(.codex) }
        probe.registry.names = { _, _ in Issue.record("Codex consulted Claude's registry"); return nil }
        var owners = 0
        let io = try fixture.codexIO(writable: kind != 2)
        probe.run = { _, arguments, _ in
            if arguments.contains("-t") { owners += 1; return Data((kind == 1 ? "" : "42\n").utf8) }
            return Data(io.utf8)
        }
        #expect((probe.capture(fixture.session(.codex), deadline: TerminalRouteDeadline()) != nil) == (kind == 0))
        #expect(owners == 1)
    }
}

private struct TerminalIdentityFixture {
    let root: URL
    let claudeLog: URL
    let codexLog: URL
    let workspace = UUID()
    let surface = UUID()
    let start: UInt64 = 1_700_000_000
    let stdio = "p42\nf0\nn/dev/ttys003\nf1\nn/dev/ttys003\n"
    var projects: URL { root.appendingPathComponent("projects") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent("projects/slug")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        claudeLog = directory.appendingPathComponent("one.jsonl")
        codexLog = directory.appendingPathComponent("rollout-one.jsonl")
        try Data("{}\n".utf8).write(to: claudeLog)
        try Data((#"{"type":"session_meta","payload":{"id":"one","source":"cli"}}"# + "\n").utf8).write(to: codexLog)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func session(_ provider: AgentTerminalSession.Provider) -> AgentTerminalSession {
        AgentTerminalSession(provider: provider, id: "one", transcriptPath: (provider == .claude ? claudeLog : codexLog).path,
                             claudeProjectsPath: provider == .claude ? projects.path : nil)
    }

    func process(_ provider: AgentTerminalSession.Provider) -> NativeTerminalProcess {
        var info = proc_bsdinfo()
        info.pbi_pid = 42; info.pbi_ppid = 90; info.pbi_uid = getuid(); info.pbi_status = UInt32(SRUN)
        info.pbi_start_tvsec = start; info.pbi_start_tvusec = 100_000
        info.pbi_pgid = 42; info.e_tpgid = 42; info.e_tdev = 1
        return NativeTerminalProcess(info: info, name: provider.rawValue,
                                     arguments: provider == .claude ? ["claude", "review"] : ["codex"],
                                     workspace: workspace, surface: surface)
    }

    func registryFile(session: String = "one") throws -> ClaudeTerminalRegistry.File {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        let data = try JSONSerialization.data(withJSONObject: ["pid": 42, "sessionId": session, "kind": "interactive",
            "entrypoint": "cli", "pidDomain": "darwin", "procStart": formatter.string(from: Date(timeIntervalSince1970: Double(start)))])
        return ClaudeTerminalRegistry.File(data: data, owner: getuid(), regular: true, size: Int64(data.count),
                                           modifiedSeconds: Int64(start + 1), modifiedNanoseconds: 0)
    }

    func probe() throws -> NativeTerminalProbe {
        var probe = NativeTerminalProbe()
        let file = try registryFile()
        probe.registry = ClaudeTerminalRegistry(names: { _, _ in ["42.json"] }, read: { _, _ in file })
        probe.readProcess = { _ in process(.claude) }
        probe.run = { _, _, _ in Data(stdio.utf8) }
        probe.ttyMatches = { _, _ in true }
        probe.findHost = { _, _ in
            var info = process(.claude).info
            info.pbi_pid = 90
            info.pbi_start_tvsec -= 100
            return NativeTerminalProcess.Host(info: info, cli: "/Applications/cmux.app/Contents/Resources/bin/cmux")
        }
        return probe
    }

    func codexIO(writable: Bool) throws -> String {
        let path = session(.codex).transcriptPath
        var file = stat()
        try #require(stat(path, &file) == 0)
        return stdio + "f7\na\(writable ? "w" : "r")\nD0x\(String(UInt32(bitPattern: file.st_dev), radix: 16))\n"
            + "i\(file.st_ino)\nn\(path)\n"
    }
}
