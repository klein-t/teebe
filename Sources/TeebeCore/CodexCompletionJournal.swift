import Foundation

/// Reads appended rollout bytes at the existing polling cadence. Unlike the
/// status tail, this preserves every turn ending between checks, even when later
/// output pushes an earlier completion out of the status scanner's tail window.
final class CodexCompletionJournal: @unchecked Sendable {
    private let lock = NSLock()
    private var beganAt: Date?
    private var cursors: [URL: Cursor] = [:]
    private var endings: [String: Ending] = [:]

    func read(files: [URL], paths: [String], now: Date,
              summary: (URL) -> CodexThreadSummary?) -> [AgentTurnEnd] {
        lock.lock(); defer { lock.unlock() }
        let baseline = beganAt == nil
        if baseline { beganAt = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 * 1_000) / 1_000) }
        let boundary = beganAt ?? now
        for url in files {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = (attributes[.size] as? NSNumber)?.uint64Value,
                  let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value else { continue }
            var cursor = cursors[url] ?? Cursor(seed: summary(url), inode: inode)
            if baseline {
                cursor.startAtEnd(of: url, size: size)
            } else {
                if cursor.inode != inode || size < cursor.offset { cursor = Cursor(seed: nil, inode: inode) }
                for ending in cursor.read(url, size: size) where ending.date >= boundary {
                    endings[ending.id] = ending
                }
            }
            cursors[url] = cursor
        }
        let present = Set(files)
        cursors = cursors.filter { present.contains($0.key) }
        endings = endings.filter { now.timeIntervalSince($0.value.date) < 86_400 }
        return endings.values.compactMap { ending in
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

        init(seed: CodexThreadSummary?, inode: UInt64) {
            self.inode = inode
            sessionID = seed?.id ?? ""
            isUser = seed?.role == .user
            cwd = seed?.cwd
            targets = (seed?.targets ?? []).map { ($0, seed?.lastActivity ?? .distantPast) }
        }

        /// Keep an unfinished line at startup so an append that finishes it is
        /// still parseable. Finished historical records are never read here.
        mutating func startAtEnd(of url: URL, size: UInt64) {
            offset = size
            guard size > 0, let handle = try? FileHandle(forReadingFrom: url) else { return }
            defer { try? handle.close() }
            guard (try? handle.seek(toOffset: size - 1)) != nil,
                  let last = try? handle.read(upToCount: 1), last.first != 10 else { return }
            let count = min(size, 8 * 1_024 * 1_024)
            guard (try? handle.seek(toOffset: size - count)) != nil,
                  let data = try? handle.read(upToCount: Int(count)) else { return }
            if let newline = data.lastIndex(of: 10) {
                partial = Data(data.suffix(from: newline + 1))
            } else if count == size {
                partial = data
            } else {
                droppingLine = true
            }
        }

        mutating func read(_ url: URL, size: UInt64) -> [Ending] {
            guard size > offset, let handle = try? FileHandle(forReadingFrom: url) else { return [] }
            defer { try? handle.close() }
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
