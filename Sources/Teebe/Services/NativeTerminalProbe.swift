import Darwin
import Foundation
import TeebeCore

struct NativeTerminalProbe: AgentTerminalProbe {
    var registry = ClaudeTerminalRegistry()
    var readProcess: (Int32) -> NativeTerminalProcess? = NativeTerminalProcess.read
    var run: (String, [String], TerminalRouteDeadline) -> Data? = { TerminalCommand.read($0, $1, deadline: $2) }
    var findHost: (proc_bsdinfo, TerminalRouteDeadline) -> NativeTerminalProcess.Host? = {
        NativeTerminalProcess.cmuxHost(of: $0, deadline: $1)
    }
    var ttyMatches: (proc_bsdinfo, String) -> Bool = controllingTTY

    func capture(_ session: AgentTerminalSession, deadline: TerminalRouteDeadline) -> TerminalRouteAnchor? {
        guard session.isValid, deadline.remaining > 0,
              let file = fileIdentity(session.transcriptPath), matchesFile(session),
              let process = owner(session, deadline: deadline),
              process.info.pbi_pgid > 0, process.info.e_tdev != UInt32.max,
              process.info.pbi_pgid == process.info.e_tpgid,
              let io = run("/usr/sbin/lsof", ioArguments(process.info.pbi_pid, provider: session.provider), deadline),
              let ioText = String(data: io, encoding: .utf8), let tty = Self.terminalIO(ioText),
              ttyMatches(process.info, tty),
              session.provider == .claude || (Self.ownsTranscript(ioText, device: file.device, inode: file.inode)
                && independentSession(ioText, requested: session)),
              let workspace = process.workspace, let surface = process.surface,
              let host = findHost(process.info, deadline),
              fileIdentity(session.transcriptPath) == file, deadline.remaining > 0 else { return nil }
        let identity = TerminalProcessIdentity(pid: Int32(process.info.pbi_pid), uid: process.info.pbi_uid,
                                               startedSeconds: process.info.pbi_start_tvsec,
                                               startedMicroseconds: process.info.pbi_start_tvusec, tty: tty)
        return TerminalRouteAnchor(session: session, process: identity, device: file.device, inode: file.inode,
                                   hostPID: Int32(host.info.pbi_pid), hostStartedSeconds: host.info.pbi_start_tvsec,
                                   hostStartedMicroseconds: host.info.pbi_start_tvusec,
                                   cmuxCLI: host.cli, workspace: workspace, surface: surface)
    }

    private func owner(_ session: AgentTerminalSession, deadline: TerminalRouteDeadline) -> NativeTerminalProcess? {
        switch session.provider {
        case .claude:
            guard let path = session.claudeProjectsPath,
                  let match = registry.find(sessionID: session.id, projectsRoot: URL(fileURLWithPath: path), deadline: deadline),
                  let process = checkedProcess(match.registration.pid),
                  match.registration.matchesStart(seconds: process.info.pbi_start_tvsec,
                    microseconds: process.info.pbi_start_tvusec, fileModifiedSeconds: match.modifiedSeconds,
                    fileModifiedNanoseconds: match.modifiedNanoseconds) else { return nil }
            // The registry supplies the interactive role. Prompt words such as
            // "review" or "mcp" in argv are not evidence of a headless session.
            return process
        case .codex:
            guard let data = run("/usr/sbin/lsof", ["-nP", "-t", "--", session.transcriptPath], deadline),
                  let text = String(data: data, encoding: .utf8), let pid = Self.uniquePID(text),
                  let process = checkedProcess(pid),
                  NativeTerminalProcess.isInteractive(provider: .codex, name: process.name, arguments: process.arguments)
            else { return nil }
            return process
        }
    }

    private func checkedProcess(_ pid: Int32) -> NativeTerminalProcess? {
        guard let process = readProcess(pid), process.info.pbi_pid == UInt32(pid), process.info.pbi_uid == getuid(),
              process.info.pbi_status != SZOMB, process.info.pbi_start_tvsec > 0,
              process.info.pbi_start_tvusec < 1_000_000 else { return nil }
        return process
    }

    private func ioArguments(_ pid: UInt32, provider: AgentTerminalSession.Provider) -> [String] {
        let prefix = ["-nP", "-a", "-p", String(pid)]
        // Claude's registry replaces transcript ownership. Inspect only stdio,
        // without asking lsof for metadata about any open registry key files.
        return prefix + (provider == .claude ? ["-d", "0,1", "-Ffn"] : ["-FfanDi"])
    }

    func destination(for anchor: TerminalRouteAnchor, deadline: TerminalRouteDeadline) -> CmuxTerminalTarget? {
        guard let socket = controlSocket(anchor.hostPID, deadline: deadline) else { return nil }
        return CmuxTerminalClient(cli: anchor.cmuxCLI, socket: socket).destination(for: anchor, deadline: deadline)
    }

    func controlSocket(_ pid: Int32, deadline: TerminalRouteDeadline) -> String? {
        guard let data = run("/usr/sbin/lsof", ["-nP", "-a", "-p", String(pid), "-U", "-Fn"], deadline),
              let text = String(data: data, encoding: .utf8), let path = Self.uniqueSocket(text) else { return nil }
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid() else { return nil }
        return path
    }

    static func uniquePID(_ text: String) -> Int32? {
        let lines = text.split(whereSeparator: \.isNewline)
        let pids = lines.compactMap { Int32($0) }
        guard pids.count == lines.count, Set(pids).count == 1, let pid = pids.first, pid > 0 else { return nil }
        return pid
    }

    static func terminalIO(_ text: String) -> String? {
        var descriptor: String?
        var input: String?
        var output: String?
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("f") { descriptor = String(line.dropFirst()) }
            if line.hasPrefix("n") {
                if descriptor == "0" { input = String(line.dropFirst()) }
                if descriptor == "1" { output = String(line.dropFirst()) }
            }
        }
        guard let input, input == output else { return nil }
        return TerminalProcessIdentity.normalizedTTY(input)
    }

    static func uniqueSocket(_ text: String) -> String? {
        let paths = Set(text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            guard line.hasPrefix("n/") else { return nil }
            let path = String(line.dropFirst()).components(separatedBy: " type=")[0]
            let name = URL(fileURLWithPath: path).lastPathComponent
            guard name.range(of: "^cmux([-._][a-zA-Z0-9_-]+)?\\.sock$", options: .regularExpression) != nil else { return nil }
            return path
        })
        return paths.count == 1 ? paths.first : nil
    }

    /// Reading another session's log is not ownership. Require a writable fd
    /// for the same file identity that was statted before the process query.
    static func ownsTranscript(_ text: String, device: UInt64, inode: UInt64) -> Bool {
        let files = text.components(separatedBy: "\nf").dropFirst()
        return files.contains { file in
            let fields = file.split(whereSeparator: \.isNewline)
            let access = fields.first { $0.hasPrefix("a") }.map { String($0.dropFirst()) }
            let fileDevice = fields.first { $0.hasPrefix("D0x") }.flatMap { UInt64($0.dropFirst(3), radix: 16) }
            let fileInode = fields.first { $0.hasPrefix("i") }.flatMap { UInt64($0.dropFirst()) }
            return (access == "w" || access == "u") && fileDevice == device && fileInode == inode
        }
    }

    private struct FileIdentity: Equatable { var device: UInt64; var inode: UInt64 }

    private func fileIdentity(_ path: String) -> FileIdentity? {
        var info = stat()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else { return nil }
        return FileIdentity(device: UInt64(UInt32(bitPattern: info.st_dev)), inode: info.st_ino)
    }

    private static func controllingTTY(_ process: proc_bsdinfo, _ tty: String) -> Bool {
        var info = stat()
        return stat("/dev/" + tty, &info) == 0 && UInt32(bitPattern: info.st_rdev) == process.e_tdev
    }

    private func matchesFile(_ session: AgentTerminalSession) -> Bool {
        if session.provider == .claude {
            guard let root = session.claudeProjectsPath, root.hasPrefix("/"), !root.contains("\0"), root.utf8.count <= 4_096 else { return false }
            let url = URL(fileURLWithPath: session.transcriptPath)
            return url.pathExtension == "jsonl" && url.deletingPathExtension().lastPathComponent == session.id
                && url.deletingLastPathComponent().deletingLastPathComponent().path == URL(fileURLWithPath: root).path
        }
        guard let meta = metadata(session.transcriptPath), meta["id"] as? String == session.id,
              meta["source"] as? String == "cli" else { return false }
        return true
    }

    private func independentSession(_ text: String, requested: AgentTerminalSession) -> Bool {
        let paths = Set(text.split(whereSeparator: \.isNewline)
            .filter { $0.hasPrefix("n/") && $0.hasSuffix(".jsonl") }.map { String($0.dropFirst()) })
        guard paths.count <= 64, paths.contains(requested.transcriptPath) else { return false }
        var sessions = Set<String>()
        for path in paths {
            let url = URL(fileURLWithPath: path)
            if requested.provider == .codex, url.lastPathComponent.hasPrefix("rollout-") {
                guard let meta = metadata(path), let id = meta["id"] as? String else { return false }
                if (meta["source"] as? [String: Any])?["subagent"] != nil { continue }
                sessions.insert(id)
            }
        }
        return sessions == [requested.id]
    }

    private func metadata(_ path: String) -> [String: Any]? {
        // Check the opened descriptor too: a path replaced with a pipe must not block a click.
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        var bytes = [UInt8](repeating: 0, count: 65_536)
        let count = Darwin.read(descriptor, &bytes, bytes.count)
        guard count > 0, let end = bytes.prefix(count).firstIndex(of: 10),
              let object = try? JSONSerialization.jsonObject(with: Data(bytes[..<end])) as? [String: Any],
              object["type"] as? String == "session_meta" else { return nil }
        return object["payload"] as? [String: Any]
    }
}
