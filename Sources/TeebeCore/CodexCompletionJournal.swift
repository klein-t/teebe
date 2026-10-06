import Foundation

/// Reads appended rollout bytes at the existing polling cadence. Unlike the
/// status tail, this preserves every turn ending between checks, even when later
/// output pushes an earlier completion out of the status scanner's tail window.
final class CodexCompletionJournal: @unchecked Sendable {
    /// Rollouts written longer ago than this at launch are not read then: any
    /// targets they hold are already past the attribution window. They are read
    /// from where they ended only once they grow.
    static let seedWindow = WorktreeAttribution.targetWindow

    private let lock = NSLock()
    private let open: (URL) -> FileHandle?
    private var beganAt: Date?
    private var reading = false
    private var cursors: [URL: Cursor] = [:]
    private var endings: [String: Ending] = [:]

    init(open: @escaping (URL) -> FileHandle? = { try? FileHandle(forReadingFrom: $0) }) {
        self.open = open
    }

    /// File I/O runs outside the lock; a read that overlaps one in progress
    /// returns the endings known so far instead of reading the files again.
    func read(files: [URL], paths: [String], now: Date,
              summary: (URL) -> CodexThreadSummary?) -> [AgentTurnEnd] {
        lock.lock()
        guard !reading else { defer { lock.unlock() }; return attributed(paths: paths) }
        reading = true
        let baseline = beganAt == nil
        if baseline { beganAt = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 * 1_000) / 1_000) }
        let boundary = beganAt ?? now
        var previous = cursors
        lock.unlock()

        var next: [URL: Cursor] = [:]
        var found: [Ending] = []
        for url in files {
            // One stat per rollout on every poll: `attributesOfItem` also reads
            // extended attributes, which made this the most expensive step.
            var info = stat()
            guard stat(url.path, &info) == 0 else { continue }
            let size = UInt64(info.st_size)
            let inode = UInt64(info.st_ino)
            var cursor: Cursor
            if baseline {
                let mtime = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                    + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
                cursor = now.timeIntervalSince(mtime) < Self.seedWindow
                    ? Cursor(seed: summary(url), inode: inode) : Cursor(inode: inode)
                cursor.startAtEnd(size: size)
            } else {
                cursor = previous.removeValue(forKey: url) ?? Cursor(seed: summary(url), inode: inode)
                if cursor.inode != inode || size < cursor.offset { cursor = Cursor(seed: nil, inode: inode) }
                if size > cursor.offset, !cursor.seeded { cursor.adopt(summary(url)) }
                found += cursor.read(url, size: size, open: open).filter { $0.date >= boundary }
            }
            next[url] = cursor
        }

        lock.lock(); defer { lock.unlock() }
        reading = false
        cursors = next
        for ending in found { endings[ending.id] = ending }
        endings = endings.filter { now.timeIntervalSince($0.value.date) < 86_400 }
        return attributed(paths: paths)
    }

    private func attributed(paths: [String]) -> [AgentTurnEnd] {
        endings.values.compactMap { ending in
            guard let owner = WorktreeAttribution.owner(targets: ending.targets, cwd: ending.cwd, among: paths) else { return nil }
            return AgentTurnEnd(id: ending.id, worktreePath: owner, endedAt: ending.date, completed: ending.completed)
        }
    }

    private struct Ending {
        var id: String
        var date: Date
        var completed: Bool
        var cwd: String?
        var targets: [String]
    }

    private struct Cursor {
        var inode: UInt64
        var offset: UInt64 = 0
        var partial = Data()
        var droppingLine = false
        var sessionID: String
        var isUser: Bool
        var cwd: String?
        var turnID: String?
        var targets: [(String, Date)] = []
        /// False for a rollout left unread at launch: identity is taken once it grows.
        var seeded = true
        /// Set at launch: `offset` may sit inside an unfinished line.
        var findLineStart = false

        init(seed: CodexThreadSummary?, inode: UInt64) {
            self.inode = inode
            sessionID = seed?.id ?? ""
            isUser = seed?.role == .user
            cwd = seed?.cwd
            targets = (seed?.targets ?? []).map { ($0, seed?.lastActivity ?? .distantPast) }
        }

        init(inode: UInt64) {
            self.init(seed: nil, inode: inode)
            seeded = false
        }

        /// Its targets are left out: they predate the appended records, which
        /// bring their own.
        mutating func adopt(_ seed: CodexThreadSummary?) {
            seeded = true
            sessionID = seed?.id ?? ""
            isUser = seed?.role == .user
            cwd = seed?.cwd
        }

        /// Start at the end without reading: finished historical records are
        /// never read, and an unfinished line is found once the file grows.
        mutating func startAtEnd(size: UInt64) {
            offset = size
            findLineStart = size > 0
        }

        /// Step back to the start of the line `offset` sits inside, so an append
        /// that finishes it is still parseable.
        private mutating func rewindToLineStart(_ handle: FileHandle) {
            guard (try? handle.seek(toOffset: offset - 1)) != nil,
                  let last = try? handle.read(upToCount: 1), last.first != 10 else { return }
            let count = min(offset, 8 * 1_024 * 1_024)
            guard (try? handle.seek(toOffset: offset - count)) != nil,
                  let data = try? handle.read(upToCount: Int(count)) else { return }
            if let newline = data.lastIndex(of: 10) {
                offset -= UInt64(data.distance(from: newline, to: data.endIndex) - 1)
            } else if count == offset {
                offset = 0
            } else {
                droppingLine = true
            }
        }

        mutating func read(_ url: URL, size: UInt64, open: (URL) -> FileHandle?) -> [Ending] {
            guard size > offset, let handle = open(url) else { return [] }
            defer { try? handle.close() }
            if findLineStart {
                findLineStart = false
                rewindToLineStart(handle)
            }
            guard (try? handle.seek(toOffset: offset)) != nil else { return [] }
            var result: [Ending] = []
            while offset < size {
                let count = Int(min(64 * 1_024, size - offset))
                guard let data = try? handle.read(upToCount: count), !data.isEmpty else { break }
                offset += UInt64(data.count)
                for fragment in data.split(separator: 10, omittingEmptySubsequences: false).enumerated() {
                    if fragment.offset > 0 {
                        if !droppingLine, let ending = consumeLine() { result.append(ending) }
                        partial.removeAll(keepingCapacity: true)
                        droppingLine = false
                    }
                    if partial.count + fragment.element.count > 8 * 1_024 * 1_024 {
                        partial.removeAll(keepingCapacity: true)
                        droppingLine = true
                    } else if !droppingLine { partial.append(contentsOf: fragment.element) }
                }
            }
            return result
        }

        private mutating func consumeLine() -> Ending? {
            guard let object = (try? JSONSerialization.jsonObject(with: partial)) as? [String: Any],
                  let payload = object["payload"] as? [String: Any] else { return nil }
            if object["type"] as? String == "session_meta" {
                sessionID = payload["id"] as? String ?? payload["session_id"] as? String ?? sessionID
                isUser = CodexRolloutScanner.role(of: payload["source"]) == .user
                cwd = payload["cwd"] as? String
                return nil
            }
            guard isUser, let line = String(data: partial, encoding: .utf8),
                  let record = CodexRolloutRecord.parse(line: line) else { return nil }
            targets = targets.filter { record.timestamp.timeIntervalSince($0.1) <= WorktreeAttribution.targetWindow }
            targets.insert(contentsOf: record.targets.map { ($0, record.timestamp) }, at: 0)
            targets = Array(targets.prefix(WorktreeAttribution.targetLimit))
            switch record.kind {
            case .turnStarted:
                turnID = payload["turn_id"] as? String
                targets.removeAll()
            case let .turnContext(path, _):
                if let path { cwd = path }
                if let id = payload["turn_id"] as? String { turnID = id }
            case .turnCompleted, .turnAborted:
                let id = payload["turn_id"] as? String ?? turnID ?? String(record.timestamp.timeIntervalSince1970)
                guard !sessionID.isEmpty else { return nil }
                return Ending(id: "codex:" + sessionID + ":" + id, date: record.timestamp,
                              completed: record.kind == .turnCompleted, cwd: cwd, targets: targets.map(\.0))
            default: break
            }
            return nil
        }
    }
}
