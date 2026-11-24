import Darwin
import Foundation
import TeebeCore

/// OS process identity and selected cmux environment fields, never logged or saved.
struct NativeTerminalProcess {
    let info: proc_bsdinfo
    let name: String
    let arguments: [String]
    let workspace: UUID?
    let surface: UUID?

    static func read(_ pid: Int32) -> Self? {
        guard let info = bsdInfo(pid), info.pbi_uid == getuid(),
              let arguments = arguments(pid) else { return nil }
        let registered = withUnsafeBytes(of: info.pbi_name) { String(bytes: $0.prefix { $0 != 0 }, encoding: .utf8) } ?? ""
        let command = withUnsafeBytes(of: info.pbi_comm) { String(bytes: $0.prefix { $0 != 0 }, encoding: .utf8) } ?? ""
        let name = registered.isEmpty ? command : registered
        return Self(info: info, name: name, arguments: arguments.words,
                    workspace: arguments.workspace, surface: arguments.surface)
    }

    static func bsdInfo(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_status != SZOMB else { return nil }
        return info
    }

    /// A foreground CLI, not an app server, print run or shared session broker.
    static func isInteractive(provider: AgentTerminalSession.Provider, name: String, arguments: [String]) -> Bool {
        guard name == provider.rawValue, !arguments.isEmpty else { return false }
        let excluded: Set<String> = ["app-server", "exec", "e", "review", "mcp", "mcp-server", "--headless", "--print",
                                     "--output-format", "--input-format", "--version", "--help", "-h"]
        return !arguments.dropFirst().contains {
            excluded.contains($0.components(separatedBy: "=")[0]) || (provider == .claude && $0.hasPrefix("-p"))
        }
    }

    struct Host {
        let info: proc_bsdinfo
        let cli: String
    }

    /// Only a real cmux ancestor is supported. A terminal inside an editor, a
    /// detached multiplexer or Terminal.app cannot borrow cmux's stale tty map.
    static func cmuxHost(of process: proc_bsdinfo, deadline: TerminalRouteDeadline,
                         readInfo: (Int32) -> proc_bsdinfo? = bsdInfo,
                         readLoginShim: (Int32) -> LoginShim? = loginShim,
                         executablePath: (Int32) -> String? = executable) -> Host? {
        var pid = Int32(process.pbi_ppid)
        var seen = Set<Int32>()
        for _ in 0..<32 where deadline.remaining > 0 {
            guard seen.insert(pid).inserted, let path = executablePath(pid) else { return nil }
            guard let info = readInfo(pid), info.pbi_uid == getuid() else {
                // The one foreign ancestor allowed: the kernel refuses its full record.
                guard path == "/usr/bin/login", let shim = readLoginShim(pid), shim.realUser == getuid() else { return nil }
                pid = Int32(shim.parent)
                continue
            }
            let url = URL(fileURLWithPath: path)
            if ["tmux", "screen"].contains(url.lastPathComponent) { return nil }
            let bundleURL = url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            if bundleURL.pathExtension == "app" {
                guard let bundle = Bundle(url: bundleURL), bundle.bundleIdentifier == "com.cmuxterm.app",
                      bundle.executableURL?.resolvingSymlinksInPath() == url.resolvingSymlinksInPath() else { return nil }
                let cli = bundleURL.appendingPathComponent("Contents/Resources/bin/cmux").path
                guard FileManager.default.isExecutableFile(atPath: cli) else { return nil }
                return Host(info: info, cli: cli)
            }
            pid = Int32(info.pbi_ppid)
        }
        return nil
    }

    /// Terminals start the shell through setuid `/usr/bin/login`, which runs as root
    /// on behalf of the user. Only its parent and real user can be read.
    struct LoginShim {
        let parent: UInt32
        let realUser: UInt32
    }

    static func loginShim(_ pid: Int32) -> LoginShim? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard pid > 0, proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size,
              info.pbsi_pid == UInt32(pid), info.pbsi_status != SZOMB else { return nil }
        return LoginShim(parent: info.pbsi_ppid, realUser: info.pbsi_ruid)
    }

    private static func executable(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    private struct Arguments {
        var words: [String]
        var workspace: UUID?
        var surface: UUID?
    }

    private static func arguments(_ pid: Int32) -> Arguments? {
        // KERN_PROCARGS2 returns argc, executable path, argv, then environment.
        // Parse NUL boundaries, not ps's ambiguous whitespace representation.
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var length = 262_144
        var bytes = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &bytes, &length, nil, 0) == 0, length > 4 else { return nil }
        let count = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard count > 0, count <= 4_096 else { return nil }
        var index = 4
        while index < length && bytes[index] != 0 { index += 1 }
        while index < length && bytes[index] == 0 { index += 1 }
        var words: [String] = []
        for _ in 0..<count {
            guard let word = nextString(bytes, index: &index, length: length) else { return nil }
            words.append(word)
        }
        var result = Arguments(words: words)
        while index < length {
            guard let item = nextString(bytes, index: &index, length: length) else { return nil }
            if item.hasPrefix("CMUX_WORKSPACE_ID=") { result.workspace = UUID(uuidString: String(item.dropFirst(18))) }
            if item.hasPrefix("CMUX_SURFACE_ID=") { result.surface = UUID(uuidString: String(item.dropFirst(16))) }
        }
        return result
    }

    private static func nextString(_ bytes: [UInt8], index: inout Int, length: Int) -> String? {
        let start = index
        while index < length && bytes[index] != 0 { index += 1 }
        guard index < length, let value = String(bytes: bytes[start..<index], encoding: .utf8) else { return nil }
        index += 1
        return value
    }
}
