import Darwin
import Foundation
import TeebeCore

/// Click-only, bounded reads of PID JSON files. Directory enumeration reads
/// names only. Key files are discarded before any open or metadata operation.
struct ClaudeTerminalRegistry {
    static let maximumFiles = 256
    static let maximumEntries = 1_024
    static let maximumBytes = 16_384

    struct File {
        var data: Data
        var owner: UInt32
        var regular: Bool
        var size: Int64
        var modifiedSeconds: Int64
        var modifiedNanoseconds: Int64
    }

    struct Match {
        var registration: ClaudeTerminalRegistration
        var modifiedSeconds: Int64
        var modifiedNanoseconds: Int64
    }

    var names: (URL, TerminalRouteDeadline) -> [String]? = directoryNames
    var read: (URL, TerminalRouteDeadline) -> File? = readFile

    static func sessionsRoot(projectsRoot: URL) -> URL {
        projectsRoot.deletingLastPathComponent().appendingPathComponent("sessions", isDirectory: true)
    }

    func find(sessionID: String, projectsRoot: URL, deadline: TerminalRouteDeadline) -> Match? {
        let root = Self.sessionsRoot(projectsRoot: projectsRoot)
        guard deadline.remaining > 0, let names = names(root, deadline), names.count <= Self.maximumEntries else { return nil }
        let files = names.filter { $0.hasSuffix(".json") }
        guard files.count <= Self.maximumFiles else { return nil }
        var match: Match?
        for name in files {
            guard deadline.remaining > 0, let pid = Self.filePID(name),
                  let file = read(root.appendingPathComponent(name), deadline),
                  file.owner == getuid(), file.regular, file.size > 0, file.size <= Self.maximumBytes,
                  file.data.count == file.size,
                  let identity = try? JSONDecoder().decode(SessionID.self, from: file.data) else { return nil }
            if identity.sessionId != sessionID { continue }
            guard match == nil, let record = try? JSONDecoder().decode(ClaudeTerminalRegistration.self, from: file.data),
                  record.matches(sessionID: sessionID, filePID: pid) else { return nil }
            match = Match(registration: record, modifiedSeconds: file.modifiedSeconds,
                          modifiedNanoseconds: file.modifiedNanoseconds)
        }
        return deadline.remaining > 0 ? match : nil
    }

    private struct SessionID: Decodable { let sessionId: String }

    private static func filePID(_ name: String) -> Int32? {
        guard name.hasSuffix(".json"), let pid = Int32(name.dropLast(5)), pid > 0,
              name == "\(pid).json" else { return nil }
        return pid
    }

    private static func directoryNames(_ root: URL, deadline: TerminalRouteDeadline) -> [String]? {
        let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        guard let directory = fdopendir(descriptor) else { close(descriptor); return nil }
        defer { closedir(directory) }
        var result: [String] = []
        while deadline.remaining > 0 {
            errno = 0
            guard let entry = readdir(directory) else { return errno == 0 ? result : nil }
            let name = withUnsafeBytes(of: entry.pointee.d_name) {
                String(bytes: $0.prefix { $0 != 0 }, encoding: .utf8)
            }
            guard let name else { return nil }
            if name == "." || name == ".." { continue }
            result.append(name)
            guard result.count <= maximumEntries else { return nil }
        }
        return nil
    }

    private static func readFile(_ url: URL, deadline: TerminalRouteDeadline) -> File? {
        guard deadline.remaining > 0 else { return nil }
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_uid == getuid(),
              before.st_size > 0, before.st_size <= maximumBytes else { return nil }
        var bytes = [UInt8](repeating: 0, count: Int(before.st_size) + 1)
        let count = Darwin.read(descriptor, &bytes, bytes.count)
        var after = stat()
        guard count == before.st_size, fstat(descriptor, &after) == 0,
              before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec, deadline.remaining > 0 else { return nil }
        return File(data: Data(bytes.prefix(count)), owner: before.st_uid, regular: true, size: before.st_size,
                    modifiedSeconds: Int64(before.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(before.st_mtimespec.tv_nsec))
    }
}
