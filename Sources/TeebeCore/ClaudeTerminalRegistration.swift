import Foundation

/// Only the registry fields needed to bind an interactive CLI to its process.
/// Unknown fields, including cwd and messaging credentials, are never retained.
public struct ClaudeTerminalRegistration: Decodable, Equatable, Sendable {
    public let pid: Int32
    public let sessionId: String
    public let kind: String
    public let entrypoint: String
    public let procStart: String
    public let pidDomain: String

    public func matches(sessionID: String, filePID: Int32) -> Bool {
        pid > 0 && pid == filePID && sessionId == sessionID && kind == "interactive"
            && entrypoint == "cli" && pidDomain == "darwin" && !procStart.isEmpty
    }

    /// Format the kernel epoch rather than parsing an ambiguous local date.
    /// No tolerance: only whitespace padding of the day-of-month is ignored.
    /// A stale registry written before this process started also fails, even
    /// when PID reuse happens within procStart's one-second resolution.
    public func matchesStart(seconds: UInt64, microseconds: UInt64,
                             fileModifiedSeconds: Int64, fileModifiedNanoseconds: Int64,
                             timeZone: TimeZone = .current) -> Bool {
        guard seconds > 0, seconds <= UInt64(Int64.max), microseconds < 1_000_000,
              fileModifiedSeconds >= 0, (0..<1_000_000_000).contains(fileModifiedNanoseconds),
              seconds < UInt64(fileModifiedSeconds)
                || (seconds == UInt64(fileModifiedSeconds) && microseconds * 1_000 <= UInt64(fileModifiedNanoseconds))
        else { return false }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        let expected = formatter.string(from: Date(timeIntervalSince1970: Double(seconds)))
        return procStart.split(whereSeparator: \.isWhitespace).joined(separator: " ") == expected
    }
}
