import Darwin
import Foundation
import TeebeCore

/// No shell, inherited agent credentials or unbounded pipe reads. Call off-main.
enum TerminalCommand {
    static func read(_ executable: String, _ arguments: [String], deadline: TerminalRouteDeadline,
                     limit: Int = 1_048_576) -> Data? {
        guard deadline.remaining > 0 else { return nil }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                               "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }
        try? pipe.fileHandleForWriting.close()
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            try? pipe.fileHandleForReading.close()
        }
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) != -1 else { return nil }
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while deadline.remaining > 0 {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                guard output.count + count <= limit else { return nil }
                output.append(contentsOf: buffer.prefix(count))
            } else if count == 0 {
                guard done.wait(timeout: .now() + deadline.remaining) == .success else { return nil }
                return process.terminationStatus == 0 ? output : nil
            } else if errno != EAGAIN && errno != EINTR {
                return nil
            } else {
                var pollFD = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                _ = poll(&pollFD, 1, Int32(min(20, deadline.remaining * 1_000)))
            }
        }
        return nil
    }
}
