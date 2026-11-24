import Darwin
import Foundation
import Testing
import TeebeCore
@testable import Teebe

@Suite("Native terminal routing boundaries")
struct NativeTerminalRouteTests {
    @Test("only a single transcript owner is accepted")
    func uniqueOwner() {
        #expect(NativeTerminalProbe.uniquePID("42\n") == 42)
        #expect(NativeTerminalProbe.uniquePID("42\n42\n") == 42)
        #expect(NativeTerminalProbe.uniquePID("") == nil)
        #expect(NativeTerminalProbe.uniquePID("42\n43\n") == nil)
        #expect(NativeTerminalProbe.uniquePID("42\nunknown\n") == nil)
    }

    @Test("both interactive descriptors must name the same tty")
    func io() {
        #expect(NativeTerminalProbe.terminalIO("p42\nf0\nn/dev/ttys003\nf1\nn/dev/ttys003\nf2\nn/log") == "ttys003")
        #expect(NativeTerminalProbe.terminalIO("f0\nn/dev/null\nf1\nn/dev/ttys003") == nil)
        #expect(NativeTerminalProbe.terminalIO("f0\nn/dev/ttys002\nf1\nn/dev/ttys003") == nil)
        #expect(NativeTerminalProbe.terminalIO("f0\nn/dev/ttys003") == nil)
    }

    @Test("a Unicode line break inside a file name cannot forge a field")
    func rawLineBreaksInNames() {
        // lsof prints U+2028 raw: the forged "n/dev/ttys003" stays part of fd 1's name.
        #expect(NativeTerminalProbe.terminalIO("f0\nn/dev/ttys003\nf1\nn/tmp/x\u{2028}n/dev/ttys003") == nil)
        #expect(NativeTerminalProbe.uniqueSocket("n/tmp/x\u{2028}n/tmp/cmux.sock\n") == "/tmp/x\u{2028}n/tmp/cmux.sock")
        #expect(NativeTerminalProbe.uniquePID("42\u{2028}42\n") == nil)
    }

    @Test("shared brokers, headless agents and unsupported processes cannot supply a terminal")
    func processRoles() {
        #expect(NativeTerminalProcess.isInteractive(provider: .codex, name: "codex", arguments: ["codex", "resume", "session"]))
        #expect(NativeTerminalProcess.isInteractive(provider: .codex, name: "codex", arguments: ["codex", "-p", "work"]))
        #expect(NativeTerminalProcess.isInteractive(provider: .claude, name: "claude", arguments: ["claude", "--resume", "session"]))
        for arguments in [["codex", "app-server"], ["codex", "exec", "hello"], ["codex", "e", "hello"], ["codex", "review"],
                          ["claude", "--print=hello"], ["claude", "-p", "hello"], ["claude", "-phello"]] {
            let provider: AgentTerminalSession.Provider = arguments[0] == "codex" ? .codex : .claude
            #expect(!NativeTerminalProcess.isInteractive(provider: provider, name: arguments[0], arguments: arguments))
        }
        for name in ["iTerm2", "Electron", "node", "Terminal", "zsh"] {
            #expect(!NativeTerminalProcess.isInteractive(provider: .codex, name: name, arguments: [name]))
        }
    }

    @Test("a read-only transcript or replaced inode cannot identify the chat")
    func writableTranscript() {
        let file = "p42\nf5\naw\nD0x10\ni20\nn/logs/session.jsonl\n"
        #expect(NativeTerminalProbe.ownsTranscript(file, device: 16, inode: 20))
        #expect(!NativeTerminalProbe.ownsTranscript(file.replacingOccurrences(of: "aw", with: "ar"), device: 16, inode: 20))
        #expect(!NativeTerminalProbe.ownsTranscript(file, device: 16, inode: 21))
        #expect(!NativeTerminalProbe.ownsTranscript(file, device: 17, inode: 20))
    }

    @Test("an interactive agent under an unsupported terminal or detached multiplexer has no host", arguments: [
        "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal",
        "/Applications/iTerm.app/Contents/MacOS/iTerm2",
        "/Applications/Code.app/Contents/MacOS/Electron",
        "/opt/homebrew/bin/tmux", "/usr/bin/screen"
    ])
    func unsupportedHost(path: String) {
        var agent = proc_bsdinfo()
        agent.pbi_ppid = 100
        var parent = proc_bsdinfo()
        parent.pbi_pid = 100
        parent.pbi_uid = getuid()
        parent.pbi_ppid = 1
        #expect(NativeTerminalProcess.cmuxHost(of: agent, deadline: TerminalRouteDeadline(),
            readInfo: { $0 == 100 ? parent : nil }, executablePath: { _ in path }) == nil)
    }

    @Test("the search for the host passes the root-owned login shim and no other foreign process", arguments: [
        ("/usr/bin/login", true), ("/usr/bin/sudo", false)
    ])
    func loginShim(path: String, passes: Bool) {
        var agent = proc_bsdinfo()
        agent.pbi_ppid = 100
        var visited: [Int32] = []
        let host = NativeTerminalProcess.cmuxHost(of: agent, deadline: TerminalRouteDeadline(), readInfo: { pid in
            visited.append(pid)
            return nil
        }, readLoginShim: { pid in
            pid == 100 ? NativeTerminalProcess.LoginShim(parent: 200, realUser: getuid()) : nil
        }, executablePath: { _ in path })
        #expect(host == nil)
        #expect(visited.contains(200) == passes)
    }

    @Test("a login shim acting for another user ends the search")
    func foreignLoginShim() {
        var agent = proc_bsdinfo()
        agent.pbi_ppid = 100
        var visited: [Int32] = []
        _ = NativeTerminalProcess.cmuxHost(of: agent, deadline: TerminalRouteDeadline(), readInfo: { pid in
            visited.append(pid)
            return nil
        }, readLoginShim: { _ in NativeTerminalProcess.LoginShim(parent: 200, realUser: getuid() &+ 1) },
           executablePath: { _ in "/usr/bin/login" })
        #expect(!visited.contains(200))
    }

    @Test("the host must own one control socket; unrelated sockets are ignored")
    func sockets() {
        let socket = "/Users/person/.local/state/cmux/cmux.sock"
        #expect(NativeTerminalProbe.uniqueSocket("n" + socket + "\nn/tmp/unrelated.sock\n") == socket)
        #expect(NativeTerminalProbe.uniqueSocket("n/tmp/cmux.sock\nn/tmp/cmux-debug.sock\n") == nil)
        #expect(NativeTerminalProbe.uniqueSocket("n/tmp/unrelated.sock\n") == nil)
    }

    @Test("cmux focus uses explicit window, workspace, pane and surface, never a new terminal")
    func focusArguments() {
        let target = CmuxTerminalTarget(window: UUID(), workspace: UUID(), pane: UUID(), surface: UUID(), tty: "ttys003")
        var calls: [[String]] = []
        let cli = "/Applications/cmux.app/Contents/Resources/bin/cmux"
        let client = CmuxTerminalClient(cli: cli, socket: "/tmp/cmux.sock", run: { path, arguments, _ in
            #expect(path == cli)
            calls.append(arguments)
            return Data()
        })
        #expect(client.focus(target, deadline: TerminalRouteDeadline()))
        #expect(calls.map { $0[2] } == ["focus-window", "select-workspace", "focus-pane", "focus-panel"])
        #expect(calls.allSatisfy { $0.contains(target.window.uuidString) && $0.prefix(2) == ["--socket", "/tmp/cmux.sock"] })
        #expect(calls.last?.contains(target.surface.uuidString) == true)
        #expect(calls[2].contains(target.pane.uuidString))
    }

    @Test("cmux missing or not answering stops the attempt")
    func noCmux() {
        let target = CmuxTerminalTarget(window: UUID(), workspace: UUID(), pane: UUID(), surface: UUID(), tty: "ttys003")
        var calls = 0
        let client = CmuxTerminalClient(cli: "/missing/cmux", socket: "/tmp/cmux.sock", run: { _, _, _ in calls += 1; return nil })
        #expect(!client.focus(target, deadline: TerminalRouteDeadline()))
        #expect(calls == 1)
        #expect(TerminalCommand.read("/nonexistent/teebe-command", [], deadline: TerminalRouteDeadline(seconds: 0.1)) == nil)
    }

    @Test("command time and output are bounded, including a child that never closes stdout")
    func boundedCommands() {
        let start = ProcessInfo.processInfo.systemUptime
        #expect(TerminalCommand.read("/bin/sleep", ["5"], deadline: TerminalRouteDeadline(seconds: 0.1)) == nil)
        #expect(ProcessInfo.processInfo.systemUptime - start < 1)
        #expect(TerminalCommand.read("/usr/bin/yes", [], deadline: TerminalRouteDeadline(seconds: 0.2), limit: 64) == nil)
        #expect(TerminalCommand.read("/usr/bin/printf", ["%s", "a;$(no)"], deadline: TerminalRouteDeadline()) == Data("a;$(no)".utf8))
    }

    @Test("a stuck native read cannot keep the menu click waiting")
    func boundedClick() async {
        let gate = RoutingTestGate()
        defer { gate.release.signal() }
        let result = await AgentTerminalJump.bounded(deadline: TerminalRouteDeadline(seconds: 0.05)) {
            _ = gate.release.wait(timeout: .now() + 5)
            gate.markFinished()
            return nil
        }
        #expect(result == nil)
        #expect(!gate.isFinished)
    }
}

private final class RoutingTestGate: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var finished = false
    var isFinished: Bool { lock.withLock { finished } }
    func markFinished() { lock.withLock { finished = true } }
}
