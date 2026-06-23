import Testing
import Foundation
@testable import TreebranchCore

/// Thread-safe collector for watcher callbacks.
final class BatchCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _batches: [[String]] = []
    func add(_ batch: [String]) { lock.lock(); _batches.append(batch); lock.unlock() }
    var batches: [[String]] { lock.lock(); defer { lock.unlock() }; return _batches }
    var allPaths: Set<String> { Set(batches.flatMap { $0 }) }
}

@Suite("FileSystemWatcher")
struct FileSystemWatcherTests {
    @Test("bursts within the debounce window coalesce into one batch")
    func coalesces() async throws {
        let watcher = FSEventsWatcher()
        let collector = BatchCollector()
        watcher.debounceInterval = 0.05
        watcher.handler = { collector.add($0) }

        watcher.ingest(["/a", "/b"])
        watcher.ingest(["/b", "/c"])
        watcher.ingest(["/c", "/d"])

        try await Task.sleep(nanoseconds: 250_000_000)

        #expect(collector.batches.count == 1)
        #expect(Set(collector.batches[0]) == ["/a", "/b", "/c", "/d"])
    }

    @Test("separated bursts produce separate batches")
    func separateBatches() async throws {
        let watcher = FSEventsWatcher()
        let collector = BatchCollector()
        watcher.debounceInterval = 0.05
        watcher.handler = { collector.add($0) }

        watcher.ingest(["/a"])
        try await Task.sleep(nanoseconds: 150_000_000)
        watcher.ingest(["/b"])
        try await Task.sleep(nanoseconds: 150_000_000)

        #expect(collector.batches.count == 2)
    }

    @Test("real FSEvents delivers a write within timeout")
    func realDelivery() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("tb-fsevents-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let watcher = FSEventsWatcher()
        let collector = BatchCollector()
        watcher.start(paths: [dir.path], debounce: 0.1) { collector.add($0) }
        defer { watcher.stop() }
        #expect(watcher.isWatching == true)

        // Give the stream a moment to arm, then write.
        try await Task.sleep(nanoseconds: 200_000_000)
        try "hello".write(to: dir.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)

        // Poll up to ~4s for delivery.
        var delivered = false
        for _ in 0..<40 {
            if !collector.batches.isEmpty { delivered = true; break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(delivered == true)
    }

    @Test("FakeFileSystemWatcher records lifecycle and fires events")
    func fake() {
        let watcher = FakeFileSystemWatcher()
        let collector = BatchCollector()
        watcher.start(paths: ["/root"], debounce: 0.2) { collector.add($0) }
        #expect(watcher.isWatching == true)
        #expect(watcher.watchedPaths == ["/root"])

        watcher.fire(["/root/a.txt"])
        #expect(collector.batches == [["/root/a.txt"]])

        watcher.stop()
        #expect(watcher.isWatching == false)
        #expect(watcher.stopCount == 1)
    }
}
